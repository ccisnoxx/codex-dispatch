"""隔离的调度契约测试，不调用真实模型。"""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
FAKE_CODEX = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
assert args[0] == "exec"
assert "--json" in args and "--output-schema" in args
assert "--sandbox" not in args and "-s" not in args and "-c" not in args
assert args[-1] == "-"
json.loads(Path(args[args.index("--output-schema") + 1]).read_text())
task = sys.stdin.read()
assert "执行模式：" in task
home = Path.home()
with (home / "calls.jsonl").open("a") as stream:
    stream.write(json.dumps({"args": args, "cwd": str(Path.cwd()), "task": task}) + "\n")
behavior = os.environ.get("FAKE_BEHAVIOR", "ok")
tid = args[2] if args[1] == "resume" else "01234567-1234-1234-1234-0123456789ab"
if behavior == "wrong_thread":
    tid = "other-thread"
if behavior != "no_thread":
    print(json.dumps({"type": "thread.started", "thread_id": tid}))
print(json.dumps({"type": "turn.started"}))
if behavior == "edit":
    with Path("a.txt").open("a") as stream:
        stream.write("changed\n")
result = {
    "status": "blocked" if behavior == "blocked" else "completed",
    "summary": "已调查或实现",
    "changed_files": ["a.txt"] if behavior == "edit" else [],
    "tests": [{"command": "example", "status": "not_run", "evidence": "未执行"}],
    "acceptance": [{"criterion": "目标", "status": "unverified", "evidence": "待验收"}],
    "unverified": ["真实业务测试"], "risks": []
}
if behavior == "bad_schema":
    result["tests"][0]["status"] = "maybe"
text = "not JSON" if behavior == "bad_result" else json.dumps(result, ensure_ascii=False)
print(json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text": text}}))
if behavior == "bad_event":
    print("not an event")
if behavior != "no_terminal":
    print(json.dumps({"type": "turn.failed" if behavior == "turn_failed" else "turn.completed"}))
print("详细诊断日志", file=sys.stderr)
sys.exit(7 if behavior == "nonzero" else 0)
'''


class DispatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="thin-dispatch-test.")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.home = self.base / "home"
        self.home.mkdir()
        self.bin = self.base / "bin"
        self.bin.mkdir()
        fake = self.bin / "codex"
        fake.write_text(FAKE_CODEX, encoding="utf-8")
        fake.chmod(0o755)
        self.env = {**os.environ, "HOME": str(self.home),
                    "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                    "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
                    "PYTHONDONTWRITEBYTECODE": "1"}
        for key in list(self.env):
            if key.startswith("GIT_") and key not in ("GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM"):
                del self.env[key]
        self.repo = self.base / "repo"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "task")
        self.git("config", "user.name", "XX")
        self.git("config", "user.email", "test@example.invalid")
        (self.repo / "a.txt").write_text("original\n", encoding="utf-8")
        self.git("add", "a.txt")
        self.git("commit", "-qm", "fixture")
        self.task = self.base / "task.md"
        self.task.write_text("<task>调查或修改 a.txt</task>", encoding="utf-8")

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], env=self.env,
                              check=True, capture_output=True, text=True)

    def invoke(self, *args, behavior="ok", code=0):
        proc = subprocess.run([sys.executable, str(ROOT / "dispatch.py"), *map(str, args)],
                              env={**self.env, "FAKE_BEHAVIOR": behavior},
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, code, proc.stdout + proc.stderr)
        return json.loads(proc.stdout) if proc.stdout else proc.stderr

    def start(self, mode="readonly", **kwargs):
        return self.invoke("start", self.repo, self.task, "--mode", mode, **kwargs)

    def calls(self):
        return [json.loads(line) for line in (self.home / "calls.jsonl").read_text().splitlines()]

    def test_start_collects_logs_and_compact_result(self):
        result = self.start()
        self.assertEqual(result["status"], "completed")
        self.assertEqual(result["exit_code"], 0)
        run = Path(result["run_dir"])
        self.assertEqual(self.calls()[0]["cwd"], str(self.repo.resolve()))
        for filename in ("task.md", "events.jsonl", "stderr.log", "report.txt", "result.json",
                         "exit_code.txt", "before.json", "after.json", "outcome.json"):
            self.assertTrue((run / "1" / filename).is_file(), filename)
        self.assertNotIn("详细诊断日志", json.dumps(result, ensure_ascii=False))
        self.assertIn("详细诊断日志", (run / "1" / "stderr.log").read_text())
        self.assertEqual(self.invoke("result", run), result)
        self.assertEqual(len(self.calls()), 1)

    def test_resume_exact_thread_keeps_task_changes(self):
        first = self.start(mode="write", behavior="edit")
        second = self.invoke("resume", first["run_dir"], self.task, behavior="edit")
        self.assertEqual(second["round"], 2)
        self.assertEqual(second["thread_id"], first["thread_id"])
        self.assertEqual(self.calls()[1]["args"][1:3], ["resume", first["thread_id"]])
        self.assertEqual((self.repo / "a.txt").read_text(), "original\nchanged\nchanged\n")

    def test_dirty_write_rejected_without_starting_codex(self):
        for filename in ("a.txt", "untracked.txt"):
            with self.subTest(filename=filename):
                target = self.repo / filename
                target.write_text("existing changes\n")
                error = self.start(mode="write", code=2)
                self.assertIn("工作树干净", error)
                self.assertFalse((self.home / "calls.jsonl").exists())
                if filename == "a.txt":
                    target.write_text("original\n")

    def test_dirty_readonly_preserves_existing_changes(self):
        (self.repo / "a.txt").write_text("user changes\n")
        self.assertEqual(self.start()["status"], "completed")
        self.assertEqual((self.repo / "a.txt").read_text(), "user changes\n")

    def test_readonly_detects_changes_without_rollback(self):
        result = self.start(behavior="edit", code=1)
        self.assertIn("readonly", " ".join(result["errors"]))
        self.assertIn("changed", (self.repo / "a.txt").read_text())

    def test_mode_transitions(self):
        first = self.start()
        second = self.invoke("resume", first["run_dir"], self.task, "--mode", "write", behavior="edit")
        third = self.invoke("resume", first["run_dir"], self.task, "--mode", "readonly")
        self.assertEqual(second["mode"], "write")
        self.assertEqual(third["mode"], "readonly")
        self.assertEqual(third["status"], "completed")

    def test_first_write_after_dirty_investigation_is_rejected(self):
        (self.repo / "a.txt").write_text("user changes\n")
        first = self.start()
        error = self.invoke("resume", first["run_dir"], self.task, "--mode", "write", code=2)
        self.assertIn("工作树干净", error)
        self.assertEqual(len(self.calls()), 1)

    def test_execution_failures_remain_visible(self):
        for behavior in ("nonzero", "turn_failed", "bad_event", "bad_result", "bad_schema",
                         "no_terminal", "no_thread"):
            with self.subTest(behavior=behavior):
                result = self.start(behavior=behavior, code=1)
                self.assertEqual(result["status"], "failed")
                self.assertTrue(result["errors"])
                self.assertEqual(self.invoke("result", result["run_dir"]), result)
                if behavior == "nonzero":
                    self.assertEqual(result["exit_code"], 7)
                if behavior in ("bad_result", "bad_schema"):
                    self.assertIsNone(result["result"])

    def test_blocked_report_is_not_dispatch_failure_or_acceptance(self):
        result = self.start(behavior="blocked")
        self.assertEqual(result["status"], "completed")
        self.assertEqual(result["result"]["status"], "blocked")
        self.assertEqual(result["result"]["acceptance"][0]["status"], "unverified")

    def test_resume_rejects_wrong_thread(self):
        first = self.start()
        result = self.invoke("resume", first["run_dir"], self.task, behavior="wrong_thread", code=1)
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["thread_id"], first["thread_id"])

    def test_resume_rejects_changed_head(self):
        first = self.start()
        self.git("commit", "--allow-empty", "-qm", "external change")
        error = self.invoke("resume", first["run_dir"], self.task, code=2)
        self.assertIn("HEAD 或分支已改变", error)
        self.assertEqual(len(self.calls()), 1)

    def test_missing_executable_records_failure(self):
        (self.bin / "codex").unlink()
        # PATH 仅保留 Git 所在目录，避免意外调用真实 Codex。
        import shutil
        git_path = shutil.which("git")
        (self.bin / "git").symlink_to(git_path)
        self.env["PATH"] = str(self.bin)
        result = self.start(code=1)
        self.assertEqual(result["status"], "failed")
        self.assertIn("无法执行 Codex", " ".join(result["errors"]))

    def test_empty_task_rejected(self):
        self.task.write_text("  \n")
        self.assertIn("不能为空", self.start(code=2))


if __name__ == "__main__":
    unittest.main()
