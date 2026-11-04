#!/usr/bin/env bash
# 执行第 N 轮：run.sh <运行目录> <N> <MANIFEST_SHA>
# N=1 新建线程；N>1 续跑同一线程。不传沙箱参数，跟随 Codex 配置。退出码与 Codex 一致；本脚本拒绝执行时为 2～4。
set -euo pipefail
umask 077
export LC_ALL=C
here=$(cd "$(dirname "$0")" && pwd -P)
. "$here/common.sh"

run=$1 n=$2 want=$3
[[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "轮次必须是正整数：$n" >&2; exit 2; }
m="$run/manifest.json" s="$run/state.json"
[ "$(shasum -a 256 "$m" | cut -d' ' -f1)" = "$want" ] || { echo "manifest.json 哈希与会话记录不一致，拒绝执行" >&2; exit 3; }

repo=$(jq -r .repo "$m")
[ "$(codex --version 2>/dev/null | head -1)" = "$(jq -r .codex_version "$m")" ] || { echo "Codex 版本与建立基线时不同" >&2; exit 2; }
last=$(jq -r .last_round "$s")
[ "$last" = $((n - 1)) ] || { echo "上一轮是 $last，本轮应为 $((last + 1))，收到 $n" >&2; exit 2; }
for f in "events-$n.jsonl" "report-$n.md" "exit-$n.txt"; do
  [ ! -e "$run/$f" ] || { echo "已存在 $f，拒绝覆盖" >&2; exit 2; }
done
task="$run/task-$n.md"
[ -s "$task" ] || { echo "任务文件不存在或为空：$task" >&2; exit 2; }
tid=$(jq -r '.thread_id // empty' "$s")
if [ "$n" = 1 ]; then [ -z "$tid" ] || { echo "state.json 已有线程 ID" >&2; exit 2; }
else [ -n "$tid" ] || { echo "state.json 没有线程 ID，无法续跑" >&2; exit 2; }; fi

# 每轮前确认仓库、分支、HEAD 和 Git 元数据仍与基线一致；工作树改动允许保留
[ "$(real_dir "$(git -C "$repo" rev-parse --show-toplevel)")" = "$repo" ] || { echo "仓库路径不一致" >&2; exit 4; }
[ "$(safe_git "$repo" symbolic-ref -q --short HEAD || echo '(detached)')" = "$(jq -r .branch "$m")" ] || { echo "当前分支与基线不同" >&2; exit 4; }
[ "$(safe_git "$repo" rev-parse HEAD)" = "$(jq -r .head "$m")" ] || { echo "HEAD 与基线不同" >&2; exit 4; }
"$here/snapshot.sh" "$repo" "$run/pre-$n" "$m"
if ! "$here/compare.sh" "$run/baseline" "$run/pre-$n" > "$run/pre-$n/compare.txt"; then
  grep '^FAIL' "$run/pre-$n/compare.txt" >&2
  echo "第 $n 轮前的检查未通过，拒绝执行；详情见 $run/pre-$n/compare.txt" >&2
  exit 4
fi

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
jq --arg t "$tid" --argjson n "$n" '(if $t != "" then .thread_id = $t else . end) | .last_round = $n' "$s" > "$s.tmp" && mv "$s.tmp" "$s"
echo "ROUND=$n EXIT=$rc THREAD_ID=${tid:-(未取得)}"
exit "$rc"
