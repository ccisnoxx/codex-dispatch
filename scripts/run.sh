#!/usr/bin/env bash
# 执行第 N 轮：run.sh <运行目录> <N> <MANIFEST_SHA> <TASK_SHA> [THREAD_ID]
# N=1 新建线程；N>1 续跑同一线程，必须传入会话里记录的 THREAD_ID。不传沙箱参数，跟随 Codex 配置。
# 退出码与 Codex 一致；本脚本拒绝执行时为 2（参数/版本/轮次/产物已存在）、3（与会话记录的哈希或线程不符）、
# 4（运行前检查发现仓库状态已变）、5（运行目录被占用）。
set -euo pipefail
umask 077
export LC_ALL=C
here=$(cd "$(dirname "$0")" && pwd -P)
. "$here/common.sh"

[ $# -ge 4 ] || { echo "用法：run.sh <运行目录> <N> <MANIFEST_SHA> <TASK_SHA> [THREAD_ID]" >&2; exit 2; }
run=$1 n=$2 want_manifest=$3 want_task=$4 want_thread=${5:-}
[[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "轮次必须是正整数：$n" >&2; exit 2; }
acquire_lock "$run"
m="$run/manifest.json" s="$run/state.json" task="$run/task-$n.md"
[ "$(sha_of "$m")" = "$want_manifest" ] || { echo "manifest.json 哈希与会话记录不一致，拒绝执行" >&2; exit 3; }
[ -s "$task" ] && [ ! -L "$task" ] || { echo "任务文件不存在、为空或是符号链接：$task" >&2; exit 2; }
[ "$(sha_of "$task")" = "$want_task" ] || { echo "task-$n.md 哈希与会话记录不一致，拒绝执行" >&2; exit 3; }

repo=$(jq -r .repo "$m")
[ "$(codex --version 2>/dev/null | head -1)" = "$(jq -r .codex_version "$m")" ] || { echo "Codex 版本与建立基线时不同" >&2; exit 2; }
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
if ! "$here/compare.sh" "$run/baseline" "$run/pre-$n" "$m" > "$run/pre-$n/compare.txt"; then
  grep '^FAIL' "$run/pre-$n/compare.txt" >&2
  echo "第 $n 轮前的检查未通过，拒绝执行；详情见 $run/pre-$n/compare.txt" >&2
  exit 4
fi

set -o noclobber   # 重定向遇到已存在的文件或符号链接时失败，而不是覆盖
common=(--json -o "$run/report-$n.md" -)
set +e
if [ "$n" = 1 ]; then
  codex exec -C "$repo" "${common[@]}" < "$task" > "$run/events-$n.jsonl" 2> "$run/stderr-$n.log"
else
  # resume 子命令自身不定义 -C，用子 shell 进入仓库
  (cd "$repo" && codex exec resume "$tid" "${common[@]}" < "$task" > "$run/events-$n.jsonl" 2> "$run/stderr-$n.log")
fi
rc=$?
set -e
echo "$rc" > "$run/exit-$n.txt"

if [ "$n" = 1 ]; then
  tid=$(jq -r 'select(.type=="thread.started") | .thread_id' "$run/events-$n.jsonl" 2>/dev/null | head -1 || true)
fi
tmp=$(mktemp "$run/.state.XXXXXX")
jq --arg t "$tid" --argjson n "$n" '(if $t != "" then .thread_id = $t else . end) | .last_round = $n' "$s" >| "$tmp" && mv -f "$tmp" "$s"
echo "ROUND=$n EXIT=$rc THREAD_ID=${tid:-(未取得)}"
exit "$rc"
