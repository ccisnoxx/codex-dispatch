#!/usr/bin/env python3
"""启动、续跑 Codex，保存完整日志并输出简短结果。"""

import argparse
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


SCHEMA = Path(__file__).resolve().parent / "schemas" / "result.schema.json"
RUNS = Path.home() / ".cache" / "codex-dispatch"


class DispatchError(Exception):
    pass


def load_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def save_json(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def git(repo, *args):
    proc = subprocess.run(
        ["git", "-c", "core.fsmonitor=false", "-C", str(repo), *args],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, encoding="utf-8", errors="replace",
        env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"},
    )
    if proc.returncode:
        raise DispatchError(f"Git 检查失败：{proc.stderr.strip()}")
    return proc.stdout


def snapshot(repo):
    return {
        "head": git(repo, "rev-parse", "--verify", "HEAD").strip(),
        "branch": git(repo, "symbolic-ref", "--quiet", "HEAD").strip()
        if git(repo, "rev-parse", "--abbrev-ref", "HEAD").strip() != "HEAD" else "(detached)",
        "status": git(repo, "status", "--porcelain=v1", "--untracked-files=all"),
        "diff": git(repo, "diff", "--binary", "--no-ext-diff", "--no-textconv"),
        "staged_diff": git(repo, "diff", "--cached", "--binary", "--no-ext-diff", "--no-textconv"),
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
    thread = expected_thread
    final = ""
    completed = False
    errors = []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            errors.append(f"事件第 {number} 行不是合法 JSON")
            continue
        if not isinstance(event, dict):
            errors.append(f"事件第 {number} 行不是对象")
            continue
        kind = event.get("type")
        if kind == "thread.started":
            found = event.get("thread_id")
            if not isinstance(found, str) or not found or (thread and found != thread):
                errors.append("事件中的线程 ID 缺失或与续跑线程不同")
            else:
                thread = found
        elif kind == "item.completed":
            item = event.get("item")
            if isinstance(item, dict) and item.get("type") == "agent_message":
                final = item.get("text", "")
        elif kind == "turn.completed":
            completed = True
        elif kind in ("turn.failed", "error"):
            errors.append("Codex 报告运行错误，详情见 events.jsonl")
    if not thread:
        errors.append("没有取得线程 ID")
    if not completed:
        errors.append("没有收到 turn.completed")
    if not isinstance(final, str) or not final.strip():
        errors.append("没有最终结果消息")
        final = ""
    return thread, final, errors


def prompt(task, mode):
    return f"""执行模式：{mode}。阅读项目 AGENTS.md 等规则，自主调查并完成以下任务。
readonly 不得修改目标仓库；write 仅可修改任务允许的范围。
不得 commit、push、发布、修改仓库外文件或做无关重构；Codex 自身会话和缓存除外。
需要扩大范围或改变目标时停止相关动作并报告。低风险局部实现判断可自行完成。
最终按结果 schema 用简体中文简要报告；tests 写实际命令、状态及关键证据，未运行写 not_run。
acceptance 逐项报告 met/unmet/unverified；调查任务用它表达问题是否已回答。
这些状态是你的报告，不代表 Claude 已验收。完整命令日志无需复制进摘要。

{task}"""


def output(run, state):
    round_dir = run / str(state["round"])
    result_path = round_dir / "result.json"
    return {
        "run_dir": str(run), "thread_id": state["thread_id"],
        "round": state["round"], "mode": state["mode"], "status": state["status"],
        "exit_code": state.get("exit_code"), "errors": state.get("errors", []),
        "result": load_json(result_path) if result_path.exists() else None,
    }


def execute(run, state, task, mode):
    repo = Path(state["repo"])
    before = snapshot(repo)
    if any(before[key] != state[key] for key in ("head", "branch")):
        raise DispatchError("HEAD 或分支已改变，请重新启动任务")
    if mode == "write" and not state["write_started"] and before["status"]:
        raise DispatchError("首次写入要求工作树干净；请先处理已有改动或使用独立 worktree")

    number = state["round"] + 1
    round_dir = run / str(number)
    round_dir.mkdir()
    (round_dir / "task.md").write_text(task, encoding="utf-8")
    save_json(round_dir / "before.json", before)
    state.update(round=number, mode=mode, status="running", exit_code=None, errors=[])
    state["write_started"] = state["write_started"] or mode == "write"
    save_json(run / "state.json", state)

    cmd = ["codex", "exec"]
    if state["thread_id"]:
        cmd += ["resume", state["thread_id"]]
    cmd += ["--json", "--output-schema", str(SCHEMA), "-"]
    errors = []
    rc = None
    try:
        with (round_dir / "events.jsonl").open("w", encoding="utf-8") as events, \
                (round_dir / "stderr.log").open("w", encoding="utf-8") as stderr:
            process = subprocess.Popen(cmd, cwd=repo, stdin=subprocess.PIPE, stdout=events,
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
    (round_dir / "exit_code.txt").write_text(f"{rc}\n", encoding="utf-8")
    thread, final, event_errors = read_events(round_dir / "events.jsonl", state["thread_id"])
    state["thread_id"] = thread
    errors.extend(event_errors)
    (round_dir / "report.txt").write_text(final, encoding="utf-8")
    try:
        result = json.loads(final)
        validate(result, load_json(SCHEMA))
        save_json(round_dir / "result.json", result)
    except (json.JSONDecodeError, DispatchError) as exc:
        errors.append(f"结果无效：{exc}")
    if rc != 0:
        errors.append(f"Codex 退出码：{rc}")
    try:
        after = snapshot(repo)
        save_json(round_dir / "after.json", after)
        if any(after[key] != before[key] for key in ("head", "branch")):
            errors.append("运行期间 HEAD 或分支改变，需要人工检查")
        if mode == "readonly" and after != before:
            errors.append("readonly 运行前后 Git 状态或 diff 有变化，需要人工检查")
    except DispatchError as exc:
        errors.append(str(exc))
    state.update(status="failed" if errors else "completed", exit_code=rc, errors=errors)
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
    result = commands.add_parser("result", help="读取最近一轮简短结果，不启动 Codex")
    result.add_argument("run_dir")
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
                print(json.dumps(output(run, state), ensure_ascii=False, indent=2))
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
