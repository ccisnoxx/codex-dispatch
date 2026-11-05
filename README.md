# codex-dispatch

一个薄的 Claude → Codex 调度层：Claude 理解需求、拆任务、决定方向并验收；Codex 消耗自己的上下文完成调查、局部设计、编码、命令执行和测试；调度器启动任务、保存线程并收集结果。

## 安装与依赖

```bash
git clone https://github.com/ccisnoxx/codex-dispatch.git ~/.claude/skills/codex-dispatch
```

需要 Python 3.9+（仅标准库）、Git，以及已登录并配置好的 Codex CLI。面向 macOS/Linux；使用 `fcntl`，不支持原生 Windows。当前接口在本机 Codex CLI 0.166.0 上核对，不硬编码版本白名单。升级后核对 `exec`/`exec resume` 的 `--json`、`--output-schema` 和事件格式。

完整派单方法和七块 XML 模板见 [SKILL.md](SKILL.md)。打开能识别该 Skill 的 Claude Code 会话后，可以要求“让 Codex 调查并修复这个问题，由你设计任务和验收”。

## 使用

任务文件使用 Markdown/XML，不要求额外任务 JSON schema。示例：

```bash
python3 dispatch.py start /path/to/repo /path/to/task.md --mode readonly
python3 dispatch.py start /path/to/repo /path/to/task.md --mode write
python3 dispatch.py resume /path/to/run.dir /path/to/feedback.md
python3 dispatch.py resume /path/to/run.dir /path/to/implementation.md --mode write
python3 dispatch.py result /path/to/run.dir
```

`start` 在 `~/.cache/codex-dispatch/` 建立运行目录，输出其绝对路径及线程 ID。`resume` 从运行目录取明确线程，默认沿用上一轮模式；不会恢复“最近线程”。每轮保存：

```text
run.*/
├── state.json
├── .lock
└── 1/
    ├── task.md
    ├── events.jsonl
    ├── stderr.log
    ├── report.txt
    ├── result.json       # 结果符合 schema 时生成
    ├── exit_code.txt
    ├── before.json
    ├── after.json
    └── outcome.json
```

完整日志留在文件中，默认只输出运行信息和 [结果 schema](schemas/result.schema.json) 规定的简短报告：

```json
{
  "status": "completed",
  "summary": "修复了什么",
  "changed_files": [],
  "tests": [{"command": "pytest tests/test_retry.py", "status": "passed", "evidence": "3 passed"}],
  "acceptance": [{"criterion": "非幂等请求不重试", "status": "met", "evidence": "回归测试通过"}],
  "unverified": [],
  "risks": []
}
```

报告的 `status` 可为 `completed/partial/blocked`；测试为 `passed/failed/not_run`；验收项为 `met/unmet/unverified`。这些均为 Codex 自报。外层执行状态与报告状态分别保存，最终是否通过由 Claude 看任务、diff 和关键测试证据决定。

## 两种模式与基本检查

- `readonly`：任务要求不修改仓库，运行前后比较普通 Git status、tracked/staged diff、HEAD 和分支。可以在脏工作树调查。
- `write`：首次写入要求干净工作树，包括未跟踪文件；已有改动可先放在合适的独立 worktree 中处理。续跑允许保留同一任务改动。Claude 负责选择任务分支，脚本不建分支、不提交、不推送。

两种模式都不覆盖沙箱、审批或网络配置，使用本机默认值。任务提示禁止 commit、push、发布、修改仓库外文件和无关重构，允许自主完成低风险局部判断。

每轮检查进程退出码、线程 ID、完成或错误事件和结构化结果，并记录基本 Git 状态。顶层 `completed` 仅指执行完成，不等于任务通过。退出码为 `0`（执行完成）、`1`（本轮执行或检查失败）、`2`（参数、文件、运行前检查或调度错误）。Codex 原始退出码另存。

同一运行目录的并行调用会被轻量文件锁拒绝；同一工作树的不同任务由调用方保证只有一个写入者。强制终止留下的 `running` 状态不能盲目续跑，需先检查进程与改动。失败不回滚文件。

## 边界

本项目不提供访问隔离或取证保证，不扫描 Git 管理目录、工具链、配置或 Codex session，不建立哈希证据链。普通 Git 检查不覆盖被忽略文件、已有未跟踪文件内容的原地变化、特殊 Git 隐藏标记以及仓库外副作用。需要限制高权限执行时，应使用适合的隔离环境。

运行记录默认保留，分享前检查源代码和敏感信息。确认不再续跑后可删除明确的运行目录；没有自动清理命令，不删除 Codex 全局会话或配置。旧审计实现可从 Git 提交 `d80f8df` 获取；旧运行目录不迁移到新接口。

## 验证

```bash
python3 -B -m unittest discover -s tests -v
```

测试使用临时 HOME、Git 仓库和假 Codex，覆盖启动、明确线程续跑、模式切换、工作树约束、结果收集和失败报告，不调用真实模型。真实 Codex 的接口验证需要单独执行；Linux 与 Windows/WSL 的实际运行情况应以对应环境验证为准。

## 许可证

[MIT](LICENSE)。
