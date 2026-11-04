#!/usr/bin/env bash
# 执行第 N 轮：run.sh <运行目录> <N> <MANIFEST_SHA> <TASK_SHA> [THREAD_ID]
# N=1 新建线程；N>1 续跑同一线程，必须传入会话里记录的 THREAD_ID。不传沙箱参数，跟随 Codex 配置。
# 退出码与 Codex 一致；本脚本拒绝执行时为 2（参数/版本/轮次/产物已存在）、3（运行目录、manifest、基线、任务或线程
# 与会话记录不符，或报告无法安全写入）、4（运行前检查发现仓库状态或工具链已变）、5（运行目录被占用）。
set -euo pipefail
umask 077
export LC_ALL=C
here=$(cd "${0%/*}" && pwd -P)
. "$here/common.sh"

[ $# -ge 4 ] || { echo "用法：run.sh <运行目录> <N> <MANIFEST_SHA> <TASK_SHA> [THREAD_ID]" >&2; exit 2; }
run=$1 n=$2 want_manifest=$3 want_task=$4 want_thread=${5:-}
[[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "轮次必须是正整数：$n" >&2; exit 2; }
verify_run "$run" "$want_manifest"
m="$run/manifest.json" s="$run/state.json" task="$run/task-$n.md"
snaplib regular "$task" >&2 || exit 2
[ -s "$task" ] || { echo "任务文件为空：$task" >&2; exit 2; }
[ "$(sha_of "$task")" = "$want_task" ] || { echo "task-$n.md 哈希与会话记录不一致，拒绝执行" >&2; exit 3; }

repo=$(jq -r .repo "$m")
ver=$(codex --version 2>/dev/null) || true
[ "${ver%%$'\n'*}" = "$(jq -r .codex_version "$m")" ] || { echo "Codex 版本与建立基线时不同" >&2; exit 2; }
tools_unchanged "$m" || { echo "工具链与建立基线时不同（路径或文件哈希变化），拒绝执行" >&2; exit 4; }
last=$(jq -r .last_round "$s")
[ "$last" = $((n - 1)) ] || { echo "上一轮是 $last，本轮应为 $((last + 1))，收到 $n" >&2; exit 2; }
# 本轮所有输出路径都必须事先不存在（含符号链接），防止写入被重定向到运行目录之外
for f in "events-$n.jsonl" "report-$n.md" "exit-$n.txt" "stderr-$n.log" "pre-$n"; do
  [ ! -e "$run/$f" ] && [ ! -L "$run/$f" ] || { echo "已存在 $f，拒绝执行" >&2; exit 2; }
done
tid=$(jq -r '.thread_id // empty' "$s")
if [ "$n" = 1 ]; then
  [ -z "$tid" ] || { echo "state.json 已有线程 ID" >&2; exit 2; }
else
  [ -n "$want_thread" ] || { echo "第 $n 轮必须传入会话里记录的线程 ID" >&2; exit 2; }
  [ "$tid" = "$want_thread" ] || { echo "state.json 中的线程 ID 与会话记录不一致，拒绝执行" >&2; exit 3; }
fi

# 每轮前确认仓库、分支、HEAD 和 Git 元数据仍与基线一致；工作树改动允许保留
[ "$(real_dir "$(git -C "$repo" rev-parse --show-toplevel)")" = "$repo" ] || { echo "仓库路径不一致" >&2; exit 4; }
[ "$(safe_git "$repo" symbolic-ref -q --short HEAD || echo '(detached)')" = "$(jq -r .branch "$m")" ] || { echo "当前分支与基线不同" >&2; exit 4; }
[ "$(safe_git "$repo" rev-parse HEAD)" = "$(jq -r .head "$m")" ] || { echo "HEAD 与基线不同" >&2; exit 4; }
mkdir "$run/pre-$n"
"$here/snapshot.sh" "$repo" "$run/pre-$n" "$m"
if ! snaplib compare "$run/baseline" "$run/pre-$n" > "$run/pre-$n/compare.txt"; then
  echo "第 $n 轮前的检查未通过，拒绝执行；详情见 $run/pre-$n/compare.txt" >&2
  exit 4
fi

# 不使用 codex exec -o：报告由本脚本从 JSONL 提取，以独占、不跟随符号链接的方式创建
set -o noclobber   # 重定向遇到已存在的文件或符号链接时失败，而不是覆盖
set +e
if [ "$n" = 1 ]; then
  codex exec -C "$repo" --json - < "$task" > "$run/events-$n.jsonl" 2> "$run/stderr-$n.log"
else
  # resume 子命令自身不定义 -C，用子 shell 进入仓库
  (cd "$repo" && codex exec resume "$tid" --json - < "$task" > "$run/events-$n.jsonl" 2> "$run/stderr-$n.log")
fi
rc=$?
set -e
echo "$rc" > "$run/exit-$n.txt"

if [ "$n" = 1 ]; then
  tid=$(jq -r 'select(.type=="thread.started") | .thread_id' "$run/events-$n.jsonl" 2>/dev/null) || tid=""
  tid=${tid%%$'\n'*}
fi
snaplib state-update "$s" "$tid" "$n"
report_rc=0
snaplib write-report "$run/events-$n.jsonl" "$run/report-$n.md" || report_rc=$?
echo "ROUND=$n EXIT=$rc THREAD_ID=${tid:-(未取得)}"
[ "$report_rc" = 0 ] || exit "$report_rc"
exit "$rc"
