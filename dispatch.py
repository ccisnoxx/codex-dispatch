#!/usr/bin/env python3
"""启动、续跑 Codex，保存完整日志并输出简短结果。"""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


SCHEMA = Path(__file__).resolve().parent / "schemas" / "result.schema.json"
RUNS = Path.home() / ".cache" / "codex-dispatch"
# 默认输出的长度上限；完整内容始终保存在 result.json
SUMMARY_LIMIT = 600
TEXT_LIMIT = 200
LIST_LIMIT = 20


class DispatchError(Exception):
    pass


def load_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def save_json(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def git(repo, *args, raw=False):
    proc = subprocess.run(
        ["git", "-c", "core.fsmonitor=false", "-C", str(repo), *args],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"},
    )
    if proc.returncode:
        raise DispatchError(f"Git 检查失败：{proc.stderr.decode('utf-8', 'replace').strip()}")
    return proc.stdout if raw else proc.stdout.decode("utf-8", "replace")


def untracked_digest(repo):
    """未跟踪（未忽略）文件的路径和内容哈希，用于发现新建文件被改动。"""
    digest = hashlib.sha256()
    root = os.fsencode(str(repo))
    for name in git(repo, "ls-files", "-o", "--exclude-standard", "-z", raw=True).split(b"\0"):
        if not name:
            continue
        path = os.path.join(root, name)
        digest.update(name + b"\0")
        if os.path.islink(path):
            digest.update(b"link:" + os.readlink(path))
        elif os.path.isfile(path):
            with open(path, "rb") as stream:
                for chunk in iter(lambda: stream.read(1 << 20), b""):
                    digest.update(chunk)
        else:
            digest.update(b"other")
        digest.update(b"\0")
    return digest.hexdigest()


def snapshot(repo):
    detached = git(repo, "rev-parse", "--abbrev-ref", "HEAD").strip() == "HEAD"
    return {
        "head": git(repo, "rev-parse", "--verify", "HEAD").strip(),
        "branch": "(detached)" if detached else git(repo, "symbolic-ref", "--quiet", "HEAD").strip(),
        "status": git(repo, "status", "--porcelain=v1", "--untracked-files=all"),
        "diff_sha256": hashlib.sha256(
            git(repo, "diff", "--binary", "--no-ext-diff", "--no-textconv", raw=True)).hexdigest(),
        "staged_diff_sha256": hashlib.sha256(
            git(repo, "diff", "--cached", "--binary", "--no-ext-diff", "--no-textconv", raw=True)).hexdigest(),
        "untracked_sha256": untracked_digest(repo),
    }


def validate(value, schema, location="result"):
    """只验证本项目结果 schema 使用的类型、字段和枚举。"""
    types = {"object": dict, "array": list, "string": str}
    if not isinstance(value, types[schema["type"]]):
        raise DispatchError(f"{location} 类型应为 {schema['type']}")
    if "enum" in schema and value not in schema["enum"]:
        raise DispatchError(f"{location} 的值不在允许的枚举内")
    if schema["type"] == "object":
        if set(value) != set(schema["required"]):
            raise DispatchError(f"{location} 字段与结果 schema 不一致")
        for key, item in value.items():
            validate(item, schema["properties"][key], f"{location}.{key}")
    elif schema["type"] == "array":
        for index, item in enumerate(value):
            validate(item, schema["items"], f"{location}[{index}]")


def read_events(path, expected_thread):
    """要求恰好一条 thread.started、恰好一条位于末尾的终止事件，最终消息取终止事件之前最后一条。"""
    events, errors = [], []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            errors.append(f"事件第 {number} 行不是合法 JSON")
            continue
        if not isinstance(event, dict):
            errors.append(f"事件第 {number} 行不是对象")
            continue
        events.append(event)
    kinds = [event.get("type") for event in events]

    thread = expected_thread
    starts = [event for event in events if event.get("type") == "thread.started"]
    if len(starts) != 1:
        errors.append(f"thread.started 应恰好一条，实际 {len(starts)} 条")
    else:
        found = starts[0].get("thread_id")
        if not isinstance(found, str) or not found or (expected_thread and found != expected_thread):
            errors.append("事件中的线程 ID 缺失或与续跑线程不同")
        elif not expected_thread:
            thread = found

    terminals = [index for index, kind in enumerate(kinds) if kind in ("turn.completed", "turn.failed")]
    if len(terminals) != 1:
        errors.append(f"终止事件应恰好一条，实际 {len(terminals)} 条")
    elif terminals[0] != len(events) - 1:
        errors.append("终止事件之后仍有事件")
    elif kinds[-1] == "turn.failed":
        errors.append("Codex 报告本轮失败，详情见 events.jsonl")
    if "error" in kinds:
        errors.append("事件中有顶层 error，详情见 events.jsonl")

    final = ""
    for event in events[:terminals[0] if terminals else len(events)]:
        item = event.get("item")
        if event.get("type") == "item.completed" and isinstance(item, dict) \
                and item.get("type") == "agent_message":
            final = item.get("text", "")
    if not thread:
        errors.append("没有取得线程 ID")
    if not isinstance(final, str) or not final.strip():
        errors.append("没有最终结果消息")
        final = ""
    return thread, final, errors


def prompt(task, mode):
    return f"""执行模式：{mode}。阅读项目 AGENTS.md 等规则，自主调查并完成以下任务。
readonly 不得修改目标仓库；write 仅可修改任务允许的范围。
不得 commit、push、发布、修改仓库外文件或做无关重构；Codex 自身会话和缓存除外。
需要扩大范围或改变目标时停止相关动作并报告。低风险局部实现判断可自行完成。
最终按结果 schema 用简体中文简要报告：summary 三五句以内，每条 evidence 一两句。
tests 写实际命令、状态及关键结果，未运行写 not_run；不要复制完整命令日志。
acceptance 的 id 使用任务中的验收编号（如 AC-1），没有编号时按顺序编为 AC-1、AC-2……；
逐项报告 met/unmet/unverified，调查任务用它表达问题是否已回答。
这些状态是你的报告，不代表 Claude 已验收。

{task}"""


def compact(result):
    """默认输出的投影：限制文本长度和列表项数，返回 (投影, 是否截断)。"""
    clipped = False

    def text(value, limit=TEXT_LIMIT):
        nonlocal clipped
        if len(value) <= limit:
            return value
        clipped = True
        return value[:limit] + "…"

    def items(values, convert):
        nonlocal clipped
        if len(values) > LIST_LIMIT:
            clipped = True
        return [convert(value) for value in values[:LIST_LIMIT]]

    projected = {
        "status": result["status"],
        "summary": text(result["summary"], SUMMARY_LIMIT),
        "changed_files": items(result["changed_files"], text),
        "tests": items(result["tests"], lambda test: {
            "command": text(test["command"]), "status": test["status"], "evidence": text(test["evidence"])}),
        "acceptance": items(result["acceptance"], lambda criterion: {
            "id": text(criterion["id"]), "status": criterion["status"], "evidence": text(criterion["evidence"])}),
        "unverified": items(result["unverified"], text),
        "risks": items(result["risks"], text),
    }
    return projected, clipped


def output(run, state, full=False):
    result_path = run / str(state["round"]) / "result.json"
    value = {
        "run_dir": str(run), "thread_id": state["thread_id"],
        "round": state["round"], "mode": state["mode"], "execution_status": state["status"],
        "exit_code": state.get("exit_code"), "errors": state.get("errors", []),
        "result_file": str(result_path) if result_path.exists() else None,
    }
    result = load_json(result_path) if result_path.exists() else None
    if result is not None and not full:
        result, value["truncated"] = compact(result)
    value["result"] = result
    return value


def run_codex(state, round_dir, task, mode, schema, errors):
    cmd = ["codex", "exec"]
    if state["thread_id"]:
        cmd += ["resume", state["thread_id"]]
    cmd += ["--json", "--output-schema", str(SCHEMA), "-"]
    rc = None
    try:
        with (round_dir / "events.jsonl").open("w", encoding="utf-8") as events, \
                (round_dir / "stderr.log").open("w", encoding="utf-8") as stderr:
            process = subprocess.Popen(cmd, cwd=state["repo"], stdin=subprocess.PIPE, stdout=events,
                                       stderr=stderr, text=True, encoding="utf-8")
            try:
                process.communicate(prompt(task, mode))
            except KeyboardInterrupt:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                errors.append("运行被中断；已有工作树改动未回滚")
            rc = process.returncode
    except OSError as exc:
        errors.append(f"无法执行 Codex：{exc}")
    state["exit_code"] = rc
    (round_dir / "exit_code.txt").write_text(f"{rc}\n", encoding="utf-8")
    thread, final, event_errors = read_events(round_dir / "events.jsonl", state["thread_id"])
    state["thread_id"] = thread
    errors.extend(event_errors)
    (round_dir / "report.txt").write_text(final, encoding="utf-8")
    try:
        result = json.loads(final)
        validate(result, schema)
        save_json(round_dir / "result.json", result)
    except (json.JSONDecodeError, DispatchError) as exc:
        errors.append(f"结果无效：{exc}")
    if rc != 0:
        errors.append(f"Codex 退出码：{rc}")


def execute(run, state, task, mode):
    repo = Path(state["repo"])
    schema = load_json(SCHEMA)
    before = snapshot(repo)
    if any(before[key] != state[key] for key in ("head", "branch")):
        raise DispatchError("HEAD 或分支已改变，请重新启动任务")
    if state["write_started"]:
        # 写入开始后，每轮都必须从上一轮结束时的工作树继续，避免混入外部改动
        previous = run / str(state["round"]) / "after.json"
        if not previous.exists():
            raise DispatchError("上一轮没有结束快照，无法确认工作树连续；请检查后重新启动任务")
        if load_json(previous) != before:
            raise DispatchError("工作树与上一轮结束时不同，可能混入了外部改动；请检查 git status 后重新启动任务")
    elif mode == "write" and before["status"]:
        raise DispatchError("首次写入要求工作树干净；请先处理已有改动或使用独立 worktree")

    number = state["round"] + 1
    round_dir = run / str(number)
    round_dir.mkdir()
    (round_dir / "task.md").write_text(task, encoding="utf-8")
    save_json(round_dir / "before.json", before)
    state.update(round=number, mode=mode, status="running", exit_code=None, errors=[])
    state["write_started"] = state["write_started"] or mode == "write"
    save_json(run / "state.json", state)

    errors = []
    try:
        run_codex(state, round_dir, task, mode, schema, errors)
    except Exception as exc:  # 本轮已标记 running，意外错误也要落盘为 failed，避免永久卡住
        errors.append(f"调度器内部错误：{type(exc).__name__}: {exc}")
    try:
        after = snapshot(repo)
        save_json(round_dir / "after.json", after)
        if any(after[key] != before[key] for key in ("head", "branch")):
            errors.append("运行期间 HEAD 或分支改变，需要人工检查")
        if mode == "readonly" and after != before:
            errors.append("readonly 运行前后 Git 状态、diff 或未跟踪文件有变化，需要人工检查")
    except (DispatchError, OSError) as exc:
        errors.append(f"无法采集结束快照：{exc}")
    state.update(status="failed" if errors else "completed", errors=errors)
    save_json(round_dir / "outcome.json", state)
    save_json(run / "state.json", state)
    print(json.dumps(output(run, state), ensure_ascii=False, indent=2))
    return 1 if errors else 0


def read_task(path):
    task = Path(path).read_text(encoding="utf-8")
    if not task.strip():
        raise DispatchError("任务或反馈文件不能为空")
    return task


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    start = commands.add_parser("start", help="启动新任务")
    start.add_argument("repo")
    start.add_argument("task")
    start.add_argument("--mode", choices=("readonly", "write"), required=True)
    resume = commands.add_parser("resume", help="使用明确线程续跑")
    resume.add_argument("run_dir")
    resume.add_argument("feedback")
    resume.add_argument("--mode", choices=("readonly", "write"))
    result = commands.add_parser("result", help="读取最近一轮结果，不启动 Codex")
    result.add_argument("run_dir")
    result.add_argument("--full", action="store_true", help="输出完整结果，不截断")
    args = parser.parse_args()
    try:
        if args.command == "start":
            task = read_task(args.task)
            repo = Path(git(Path(args.repo).resolve(), "rev-parse", "--show-toplevel").strip()).resolve()
            initial = snapshot(repo)
            if args.mode == "write" and initial["status"]:
                raise DispatchError("首次写入要求工作树干净；请先处理已有改动或使用独立 worktree")
            RUNS.mkdir(parents=True, exist_ok=True)
            run = Path(tempfile.mkdtemp(prefix="run.", dir=RUNS)).resolve()
            state = {"repo": str(repo), "thread_id": None, "round": 0,
                     "mode": args.mode, "status": "ready", "write_started": False,
                     "head": initial["head"], "branch": initial["branch"]}
            save_json(run / "state.json", state)
        else:
            run = Path(args.run_dir).resolve()
            state = load_json(run / "state.json")
            if args.command == "result":
                print(json.dumps(output(run, state, args.full), ensure_ascii=False, indent=2))
                return 0
            task = read_task(args.feedback)

        # 只防止同一运行目录被同时续跑，不提供仓库锁或审计保证。
        with (run / ".lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise DispatchError("该任务正在运行，请等待结束") from None
            if args.command == "resume":
                state = load_json(run / "state.json")
                if state["status"] == "running":
                    raise DispatchError("上一轮未正常结束；先检查进程与已有改动，再建立新任务")
                if not state["thread_id"]:
                    raise DispatchError("未取得线程 ID，无法续跑；请诊断后重新启动")
            return execute(run, state, task, args.mode or state["mode"])
    except (DispatchError, OSError, ValueError, KeyError) as exc:
        print(f"错误：{exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
