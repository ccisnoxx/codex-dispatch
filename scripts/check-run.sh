#!/usr/bin/env bash
# 第 N 轮的机械检查：check-run.sh <运行目录> <N> <MANIFEST_SHA> <THREAD_ID> <MODE>
# MODE 必须与 run.sh 执行本轮时相同。只覆盖可自动判断的部分。PASS 不代表被忽略文件、未登记的外部文件或
# 外部副作用没有变化；需求是否满足、diff 是否在范围内，仍由 Claude 读代码判断。
set -uo pipefail
umask 077
export LC_ALL=C
here=$(cd "${0%/*}" && pwd -P)
. "$here/common.sh"
[ $# -ge 5 ] || { echo "用法：check-run.sh <运行目录> <N> <MANIFEST_SHA> <THREAD_ID> <readonly|write>" >&2; exit 2; }
run=$1 n=$2 want=$3 want_thread=$4 mode=$5
[[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "轮次必须是正整数：$n" >&2; exit 2; }
case "$mode" in readonly|write) ;; *) echo "模式必须是 readonly 或 write：$mode" >&2; exit 2 ;; esac
verify_run "$run" "$want"
m="$run/manifest.json" s="$run/state.json"
ev="$run/events-$n.jsonl" rep="$run/report-$n.md"
repo=$(jq -r .repo "$m")
acquire_repo_lock "$repo" "$run"
fail=0
bad() { echo "FAIL: $*"; fail=1; }
ok() { echo "ok:   $*"; }

tid=$(jq -r '.thread_id // empty' "$s")
round=$(jq -c --arg n "$n" '.rounds[$n] // {}' "$s")
rc="(无)"; [ -f "$run/exit-$n.txt" ] && [ ! -L "$run/exit-$n.txt" ] && rc=$(<"$run/exit-$n.txt")
echo "repo=$repo thread=$want_thread mode=$mode exit=$rc"

echo "=== 工具链与证据文件"
tools_unchanged "$m" && ok "工具链与基线一致" || bad "工具链与基线不同（路径或文件哈希变化）"
if regular=$(snaplib regular "$ev" "$rep" "$run/exit-$n.txt" "$run/stderr-$n.log"); then
  ok "本轮证据文件都是普通文件"
else
  bad "本轮证据文件异常"; echo "$regular"
fi
[ "$(jq -r '.mode // ""' <<<"$round")" = "$mode" ] && ok "模式与执行时一致（$mode）" || bad "模式与执行时不同：执行时为 $(jq -r '.mode // "（无记录）"' <<<"$round")"
[ "$(jq -r '.status // ""' <<<"$round")" = completed ] && ok "run.sh 记录本轮状态为 completed" || bad "run.sh 记录本轮状态为 $(jq -r '.status // "（无记录）"' <<<"$round")"

echo "=== 进程与事件（严格校验协议）"
[ "$rc" = 0 ] && ok "Codex 退出码为 0" || bad "Codex 退出码为 $rc"
[ "$tid" = "$want_thread" ] && ok "state.json 线程 ID 与会话记录一致" || bad "state.json 线程 ID=$tid，会话记录=$want_thread"
verdict=$(snaplib validate-events "$ev" "$want_thread")
if [ "$(jq -r .ok <<<"$verdict")" = true ]; then
  ok "事件序列符合协议：唯一 thread.started、唯一终止事件 turn.completed 且位于末尾、无顶层 error"
else
  jq -r '.errors[]' <<<"$verdict" | while IFS= read -r e; do echo "FAIL: 事件校验：$e"; done
  fail=1
fi
if [ -f "$rep" ] && [ ! -L "$rep" ] && [ "$(<"$rep")" = "$(jq -r .final_message <<<"$verdict")" ]; then
  ok "报告与事件中的最终消息一致"
else
  bad "报告与事件中的最终消息不一致"
fi
echo "--- 条目级 error（需人工判断，不自动忽略）"
jq -c 'select(.item.type? == "error") | (.item.message // .item | tostring | .[0:300])' "$ev" 2>/dev/null

echo "=== 实际生效的权限（session turn_context，逐条断言）"
sess=$(snaplib session-contexts "$(codex_home)" "$want_thread" "$(jq -r '.session_path // empty' "$s")")
if [ "$(jq -r .ok <<<"$sess")" != true ]; then
  jq -r '.errors[]' <<<"$sess" | while IFS= read -r e; do echo "FAIL: $e"; done
  fail=1
else
  echo "session：$(jq -r .path <<<"$sess")"
  jq -c '.contexts[]' <<<"$sess"
  cnt=$(jq '.contexts | length' <<<"$sess")
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
  done < <(jq -c '.contexts[]' <<<"$sess")
fi

echo "=== 仓库和配置对比（元数据对比基线；只读模式下工作树对比本轮开始前）"
[ "$(safe_git "$repo" symbolic-ref -q --short HEAD || echo '(detached)')" = "$(jq -r .branch "$m")" ] && ok "分支与基线一致" || bad "分支与基线不同"
# 快照目录用随机名新建，Codex 无法预先放置同名符号链接
after=$(snaplib mkdtemp "$run" "after-$n.") || { bad "无法创建快照目录"; exit 1; }
echo "快照目录：$after"
if "$here/snapshot.sh" "$repo" "$after" "$m"; then
  snaplib compare "$run/baseline" "$after" "$mode" "$run/pre-$n" || fail=1
else
  bad "快照失败"
fi

echo "=== sha256（任务文件，与启动前回显的值对比；基线已由 manifest 自动校验）"
(cd "$run" && shasum -a 256 task-*.md)
echo "=== 机械检查：$([ $fail = 0 ] && echo PASS || echo FAIL)"
exit $fail
