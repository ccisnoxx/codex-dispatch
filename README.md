# codex-dispatch

让 Claude Code 主会话指挥本机 Codex 完成开发任务的 Skill。

Claude 负责全局决策、任务设计、上下文整理、风险判断和独立验收；Codex 在明确边界内自主调查、提出局部方案、编码、运行命令和测试，并返回可核查的执行证据。

## 工作方式

1. **Claude 准备派单。** 确认目标、工作区、允许修改的范围和验收条件，建立 Git 与监视文件的基线。
2. **Codex 自主执行。** 通过 `codex exec` 执行任务；需要后续轮次时，续跑同一个 Codex 线程。
3. **脚本收集证据。** 保留任务、事件、报告、退出码、文件哈希和仓库状态快照，检查 Git 元数据、监视文件与实际权限是否符合预期。
4. **Claude 独立验收。** 阅读实际改动、核对范围并复跑关键检查。需要返工时，明确指出缺失的条件及其证据。

完整任务模板、运行步骤和验收要求见 [SKILL.md](SKILL.md)。

## 环境要求

| 依赖 | 要求 |
| --- | --- |
| Claude Code | 能加载本地 Skill，并运行 Bash 命令与后台任务 |
| Codex CLI | 当前脚本仅接受 `codex-cli 0.166.0`，需先完成自己的登录与配置 |
| Shell | macOS、Linux 或 WSL 上的 Bash；WSL 尚未实测 |
| Git | 2.31 及以上；目标仓库至少有一条提交 |
| Python | 3.11 及以上，用于通过 `tomllib` 解析 TOML |
| 其他命令 | `jq`、`shasum` 和常用 Unix 命令 |

脚本不安装依赖，也不传入沙箱、审批或网络配置参数。当前 `scripts/common.sh` 中的验收期望值为：

```bash
EXPECTED_SANDBOX="danger-full-access"
EXPECTED_APPROVAL="never"
```

这些值只供检查器比对，并不会设置或授予对应权限。使用前应核对自己的 Codex 配置和实际会话记录；其他权限组合尚未验证。升级 Codex 前，需要重新核对 CLI 参数、事件和 session 结构，运行回归测试，再更新 `SUPPORTED_CODEX_VERSIONS`。

## 安装到 Claude Code

如果 `~/.claude/skills/codex-dispatch` 尚不存在，可以直接克隆：

```bash
mkdir -p ~/.claude/skills
git clone https://github.com/ccisnoxx/codex-dispatch.git ~/.claude/skills/codex-dispatch
```

打开新的 Claude Code 会话，确认它能识别 `codex-dispatch`，然后给出任务，例如：

> 使用 codex-dispatch，让 Codex 先只读调查这个问题。由你整理上下文、限定范围和独立验收，确认方案后再安排实施。

也可以直接使用 `/codex-dispatch` 并补充任务内容。Claude 应按 `SKILL.md` 完成工作区检查、建立基线和任务设计后再调用脚本。

`SKILL.md` 中关于 `/codex:*` 插件禁用和警告抑制的描述来自原使用环境，不会通过安装本仓库自动修改你的 Claude 或 Codex 设置。使用本 Skill 的脚本不依赖该插件。

## 脚本与证据

| 文件 | 用途 |
| --- | --- |
| `scripts/new-run.sh` | 检查依赖和 Codex 版本，建立运行目录、manifest 与基线 |
| `scripts/run.sh` | 校验 manifest、任务文件哈希和线程 ID 及基线后执行任务；后续轮次续跑原线程 |
| `scripts/check-run.sh` | 检查退出码、事件、线程 ID、实际权限、Git 状态与监视文件 |
| `scripts/snapshot.sh` | 采集仓库及监视路径快照 |
| `scripts/compare.sh` | 对比快照，报告变化 |
| `scripts/common.sh` | 支持版本、权限期望值及公共函数 |
| `tests/regression.sh` | 使用假 Codex 的隔离回归测试 |

运行目录位于 `~/.cache/codex-dispatch/run.*`，保存每轮的任务、JSONL 事件、报告、退出码和快照。Claude 还需要把关键哈希保留在主会话中，作为独立核对的锚点。

## 验证脚本

在仓库根目录执行：

```bash
bash tests/regression.sh
```

测试使用假 `codex` 和隔离的临时 HOME、Codex 配置及 Git 仓库，不调用真实模型。它覆盖 Git 元数据变化、监视文件变化、权限不符、证据篡改、输出路径被符号链接重定向、版本检查和同线程续跑等场景。临时检查输出会保留，路径在测试末尾打印。

这份回归测试验证脚本的检查能力；真实任务是否满足需求，仍需 Claude 根据实际实现和测试证据验收。

## 权限与审计边界

此流程通过任务约定、状态对比和独立验收管理委派，**不提供操作系统或沙箱级访问控制**。`danger-full-access` 配置下，Codex 可能拥有当前系统用户的广泛访问权限，任务文本本身无法阻止越界操作。

- 默认任务模板禁止 Codex 提交、推送、发布、部署、外部写入和修改 Git 元数据。
- 被忽略文件的内容不在默认审计范围内，关键文件需要显式登记为额外监视路径。
- 机械检查通过，不能证明未登记文件、凭证读取或外部系统没有受到影响。
- 运行目录和 Codex session 可能包含源代码、路径、命令输出及凭证片段；公开分享前必须检查并脱敏。
- 建议在隔离环境或不含敏感凭证的工作环境中使用。

## 许可证

本项目采用 [MIT License](LICENSE)。
