#!/usr/bin/env bash
# 第 N 轮的机械检查：check-run.sh <运行目录> <N> <MANIFEST_SHA> <THREAD_ID>
# 只覆盖可自动判断的部分。PASS 不代表被忽略文件、未登记的外部文件或外部副作用没有变化；
# 需求是否满足、diff 是否在范围内，仍由 Claude 读代码判断。
set -uo pipefail
umask 077
export LC_ALL=C
here=$(cd "$(dirname "$0")" && pwd -P)
. "$here/common.sh"
[ $# -ge 4 ] || { echo "用法：check-run.sh <运行目录> <N> <MANIFEST_SHA> <THREAD_ID>" >&2; exit 2; }
run=$1 n=$2 want=$3 want_thread=$4
[[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "轮次必须是正整数：$n" >&2; exit 2; }
acquire_lock "$run"
m="$run/manifest.json" s="$run/state.json"
ev="$run/events-$n.jsonl" rep="$run/report-$n.md"
fail=0
bad() { echo "FAIL: $*"; fail=1; }
ok() { echo "ok:   $*"; }

[ "$(sha_of "$m")" = "$want" ] || { echo "FAIL: manifest.json 哈希与会话记录不一致，停止检查"; exit 3; }
repo=$(jq -r .repo "$m")
tid=$(jq -r '.thread_id // empty' "$s")
rc=$(cat "$run/exit-$n.txt" 2>/dev/null || echo '(无)')
echo "repo=$repo thread=$want_thread exit=$rc"

echo "=== 进程与事件"
[ "$rc" = 0 ] && ok "Codex 退出码为 0" || bad "Codex 退出码为 $rc"
[ "$tid" = "$want_thread" ] && ok "state.json 线程 ID 与会话记录一致" || bad "state.json 线程 ID=$tid，会话记录=$want_thread"
if jq -s empty "$ev" 2>/dev/null; then ok "JSONL 可解析"; else bad "JSONL 无法解析或不存在"; fi
ev_tid=$(jq -r 'select(.type=="thread.started") | .thread_id' "$ev" 2>/dev/null | head -1)
[ "$ev_tid" = "$want_thread" ] && ok "events 线程 ID 与会话记录一致" || bad "events 线程 ID=$ev_tid，会话记录=$want_thread"
term=$(jq -sr '[.[] | select(.type=="turn.completed" or .type=="turn.failed")] | last.type // ""' "$ev" 2>/dev/null)
[ "$term" = "turn.completed" ] && ok "最后终止事件为 turn.completed" || bad "最后终止事件为 '${term:-无}'"
nfail=$(jq -s '[.[] | select(.type=="turn.failed")] | length' "$ev" 2>/dev/null || echo 1)
[ "$nfail" = 0 ] && ok "无 turn.failed" || bad "turn.failed 数量 $nfail"
nerr=$(jq -s '[.[] | select(.type=="error")] | length' "$ev" 2>/dev/null || echo 1)
[ "$nerr" = 0 ] && ok "无顶层 error" || bad "顶层 error 数量 $nerr"
[ -s "$rep" ] && ok "报告非空" || bad "报告为空或不存在"
echo "--- 条目级 error（需人工判断，不自动忽略）"
jq -c 'select(.item.type? == "error") | .item.message // .item' "$ev" 2>/dev/null | cut -c1-300

echo "=== 实际生效的权限（session turn_context，逐条断言）"
sf=$(find "$(codex_home)/sessions" -name "*${want_thread}*.jsonl" 2>/dev/null | head -1)
if [ -z "$sf" ]; then
  bad "找不到线程对应的 session 文件"
else
  ctxs=$(jq -c 'select(.type=="turn_context") | .payload | {cwd, sandbox: .sandbox_policy.type, approval: .approval_policy, permission_profile}' "$sf")
  echo "$ctxs"
  cnt=$(printf '%s\n' "$ctxs" | grep -c . || true)
  [ "$cnt" -ge "$n" ] && ok "turn_context 共 $cnt 条（本轮为第 $n 轮）" || bad "turn_context 只有 $cnt 条，少于轮次 $n"
  exp_cwd=$(jq -r .expected.cwd "$m") exp_sb=$(jq -r .expected.sandbox "$m") exp_ap=$(jq -r .expected.approval "$m")
  exp_pp=$(jq -cS .expected.permission_profile "$m")
  i=0
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    i=$((i + 1))
    cwd=$(jq -r '.cwd // empty' <<<"$c"); sb=$(jq -r '.sandbox // empty' <<<"$c"); ap=$(jq -r '.approval // empty' <<<"$c")
    pp=$(jq -cS '.permission_profile' <<<"$c")
    [ "$(real_dir "$cwd")" = "$exp_cwd" ] || bad "第 $i 条 cwd=$cwd，期望 $exp_cwd"
    [ "$sb" = "$exp_sb" ] || bad "第 $i 条 sandbox=$sb，期望 $exp_sb"
    [ "$ap" = "$exp_ap" ] || bad "第 $i 条 approval=$ap，期望 $exp_ap"
    [ "$pp" = "$exp_pp" ] || bad "第 $i 条 permission_profile=$pp，期望 $exp_pp"
  done <<<"$ctxs"
fi

echo "=== 仓库和配置对比（baseline vs 本次快照）"
[ "$(safe_git "$repo" symbolic-ref -q --short HEAD || echo '(detached)')" = "$(jq -r .branch "$m")" ] && ok "分支与基线一致" || bad "分支与基线不同"
# 快照目录用随机名新建，Codex 无法预先放置同名符号链接
after=$(mktemp -d "$run/after-$n.XXXXXX") || { bad "无法创建快照目录"; exit 1; }
echo "快照目录：$after"
"$here/snapshot.sh" "$repo" "$after" "$m" || bad "快照失败"
"$here/compare.sh" "$run/baseline" "$after" "$m" || fail=1

echo "=== sha256（与 new-run 输出及派单前记录对比）"
(cd "$run" && shasum -a 256 baseline/* task-*.md)
echo "=== 机械检查：$([ $fail = 0 ] && echo PASS || echo FAIL)"
exit $fail
