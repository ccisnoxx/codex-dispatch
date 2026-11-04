#!/usr/bin/env bash
# codex-dispatch 脚本的回归测试：tests/regression.sh
# 用假的 codex 模拟事件和 session 记录，在隔离的 HOME/CODEX_HOME 中逐项验证越界检测。不调用真实模型。
set -uo pipefail
S=$(cd "$(dirname "$0")/../scripts" && pwd -P)
T=$(mktemp -d /tmp/codex-dispatch-regression.XXXXXX)
export HOME=$T/home XDG_CONFIG_HOME=$T/home/.config CODEX_HOME=$T/codex GIT_CONFIG_NOSYSTEM=1 PATH=$T/bin:$PATH
mkdir -p "$HOME" "$CODEX_HOME" "$T/bin" "$T/markers"
touch "$CODEX_HOME/config.toml"
git config --global user.name t; git config --global user.email t@example.invalid; git config --global init.defaultBranch main

cat > "$T/bin/codex" <<'EOF'
#!/usr/bin/env bash
# 假 codex：输出 exec/resume 的 JSONL、报告和 session turn_context，并执行 FAKE_ACTION 模拟 Codex 的操作
if [ "$1" = "--version" ]; then echo "${FAKE_VERSION:-codex-cli 0.166.0}"; exit 0; fi
shift
cwd=$PWD tid="" out=""
[ "$1" = "-C" ] && { cwd=$2; shift 2; }
[ "$1" = "resume" ] && { tid=$2; shift 2; }
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac; done
cat > /dev/null
[ -n "$tid" ] || tid="fake-$RANDOM$RANDOM-$$"
sdir="$CODEX_HOME/sessions/2026/11/03"; mkdir -p "$sdir"
printf '{"type":"turn_context","payload":{"cwd":"%s","sandbox_policy":{"type":"%s"},"approval_policy":"%s","permission_profile":{"type":"disabled"}}}\n' \
  "${FAKE_CWD:-$(cd "$cwd" && pwd -P)}" "${FAKE_SANDBOX:-danger-full-access}" "${FAKE_APPROVAL:-never}" >> "$sdir/rollout-x-$tid.jsonl"
# 与真实 Codex 一样，为新目录写入 projects 信任条目
real=$(cd "$cwd" && pwd -P)
grep -qF "[projects.\"$real\"]" "$CODEX_HOME/config.toml" 2>/dev/null || printf '[projects."%s"]\ntrust_level = "trusted"\n' "$real" >> "$CODEX_HOME/config.toml"
(cd "$cwd" && eval "${FAKE_ACTION:-:}")
printf '{"type":"thread.started","thread_id":"%s"}\n{"type":"turn.started"}\n' "$tid"
printf '{"type":"item.completed","item":{"id":"i0","type":"agent_message","text":"done"}}\n{"type":"turn.completed","usage":{}}\n'
[ -n "$out" ] && echo "fake report" > "$out"
exit "${FAKE_RC:-0}"
EOF
chmod +x "$T/bin/codex"

pass=0 failn=0
result() {  # result <名称> <期望> <实际>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf 'ok    %-44s 期望=%s 实际=%s\n' "$1" "$2" "$3"
  else failn=$((failn + 1)); printf 'WRONG %-44s 期望=%s 实际=%s\n' "$1" "$2" "$3"; fi
}

mkrepo() {  # 新建仓库：已跟踪文件、被忽略文件、派单前已有的未跟踪文件、可执行 hook
  local r; r=$(mktemp -d "$T/repo.XXXXXX")
  git -C "$r" init -q
  echo a > "$r/tracked.txt"; echo '*.env' > "$r/.gitignore"
  git -C "$r" add . && git -C "$r" commit -qm base > /dev/null
  echo secret > "$r/local.env"; echo note > "$r/notes.txt"
  printf '#!/bin/sh\nexit 0\n' > "$r/.git/hooks/pre-commit"; chmod 755 "$r/.git/hooks/pre-commit"
  echo "$r"
}
newrun() { "$S/new-run.sh" "$@" > "$T/last-new-run.txt" 2>&1; }
run_dir() { sed -n 's/^RUN_DIR=//p' "$T/last-new-run.txt"; }
msha() { sed -n 's/^MANIFEST_SHA=//p' "$T/last-new-run.txt"; }

# 一轮派单 + 机械检查，返回 check-run 的退出码
scenario() {  # scenario <名称> <期望退出码> <FAKE_ACTION> [额外监视路径...]
  local name=$1 want=$2 action=$3; shift 3
  local r; r=$(mkrepo); newrun "$r" "$@" || { result "$name" "$want" "new-run失败"; return; }
  local run; run=$(run_dir); echo task > "$run/task-1.md"
  FAKE_ACTION=$action "$S/run.sh" "$run" 1 "$(msha)" > /dev/null 2>&1
  "$S/check-run.sh" "$run" 1 "$(msha)" > "$T/check-${name//\//_}.txt" 2>&1
  result "$name" "$want" "$?"
}

echo "=== 机械检查（0=PASS，1=FAIL）"
scenario "无改动"                         0 ':'
scenario "允许范围内改动与新文件"         0 'echo b >> tracked.txt; echo n > new.txt'
scenario "普通 git status 刷新 index"      0 'touch tracked.txt; git status > /dev/null'
scenario "建分支切换再删除（只改 reflog）" 1 'git branch tmp && git switch -q tmp && git switch -q main && git branch -q -D tmp'
scenario "assume-unchanged"               1 'git update-index --assume-unchanged tracked.txt'
scenario "只改 hook 权限"                 1 'chmod 644 .git/hooks/pre-commit'
scenario "改已有被忽略文件（已登记监视）" 1 'echo changed > local.env' local.env
scenario "改已有被忽略文件（未登记，已知盲区）" 0 'echo changed > local.env'
scenario "改全局 Git config"              1 'git config --global core.editor vim'
scenario "写 FETCH_HEAD"                  1 'echo x > .git/FETCH_HEAD'
scenario "info/exclude 隐藏新文件"        1 'echo stealth.txt >> .git/info/exclude; echo p > stealth.txt'
scenario "改派单前已有的未跟踪文件"       1 'echo x >> notes.txt'
scenario "改 Codex 配置（新增配置项）"    1 'printf "\n[mcp_servers.x]\ncommand = \"evil\"\n" >> "$CODEX_HOME/config.toml"'
scenario "Codex 配置只加注释（不计入）"  0 'echo "# note" >> "$CODEX_HOME/config.toml"'
scenario "git add"                        1 'echo b >> tracked.txt; git add tracked.txt'
scenario "git commit"                     1 'echo b >> tracked.txt; git commit -qam x'
FAKE_SANDBOX=workspace-write scenario "session sandbox 不符"   1 ':'
FAKE_APPROVAL=on-request     scenario "session approval 不符"  1 ':'
FAKE_CWD=/nonexistent        scenario "session cwd 不符"       1 ':'

echo "=== 快照不执行仓库配置的程序"
r=$(mkrepo)
for k in fsmonitor textconv clean; do printf '#!/bin/sh\necho %s >> %s/%s\ncat "$@" 2>/dev/null\n' "$k" "$T/markers" "$k" > "$T/bin/x-$k"; chmod +x "$T/bin/x-$k"; done
printf '*.txt diff=evil filter=evil\n' > "$r/.gitattributes"; git -C "$r" add .gitattributes; git -C "$r" commit -qm attrs > /dev/null
git -C "$r" config core.fsmonitor "$T/bin/x-fsmonitor"; git -C "$r" config diff.evil.textconv "$T/bin/x-textconv"; git -C "$r" config filter.evil.clean "$T/bin/x-clean"
rm -f "$T/markers"/*
newrun "$r"; run=$(run_dir); echo task > "$run/task-1.md"
FAKE_ACTION='echo b >> tracked.txt' "$S/run.sh" "$run" 1 "$(msha)" > /dev/null 2>&1
"$S/check-run.sh" "$run" 1 "$(msha)" > /dev/null 2>&1
result "快照与检查期间被执行的程序" "无" "$(ls "$T/markers" | tr '\n' ' ' | sed 's/ $//' | grep . || echo 无)"

echo "=== 证据与参数校验"
r=$(mkrepo); newrun "$r"; run=$(run_dir); m=$(msha); echo task > "$run/task-1.md"
"$S/run.sh" "$run" 1 "$m" > /dev/null 2>&1
jq '.branch = "evil"' "$run/manifest.json" > "$run/m.tmp" && mv "$run/m.tmp" "$run/manifest.json"
"$S/check-run.sh" "$run" 1 "$m" > /dev/null 2>&1; result "manifest 被篡改后 check-run" 3 $?

r=$(mkrepo); newrun "$r"; run=$(run_dir); m=$(msha); echo task > "$run/task-1.md"
"$S/run.sh" "$run" 1 0000 > /dev/null 2>&1; result "run.sh 传入错误的 manifest 哈希" 3 $?
"$S/run.sh" "$run" abc "$m" > /dev/null 2>&1; result "run.sh 轮次非法" 2 $?
"$S/run.sh" "$run" 2 "$m" > /dev/null 2>&1; result "run.sh 跳过第 1 轮" 2 $?
FAKE_RC=7 "$S/run.sh" "$run" 1 "$m" > /dev/null 2>&1; result "run.sh 传播 Codex 退出码" 7 $?
"$S/run.sh" "$run" 1 "$m" > /dev/null 2>&1; result "run.sh 重复执行同一轮" 2 $?
echo task2 > "$run/task-2.md"
"$S/run.sh" "$run" 2 "$m" > /dev/null 2>&1; result "第 2 轮续跑" 0 $?
"$S/check-run.sh" "$run" 2 "$m" > "$T/check-round2.txt" 2>&1; result "第 2 轮机械检查" 0 $?

r=$(mkrepo); newrun "$r"; run=$(run_dir); m=$(msha); echo task > "$run/task-1.md"
"$S/run.sh" "$run" 1 "$m" > /dev/null 2>&1
echo c >> "$r/tracked.txt"; git -C "$r" commit -qam between > /dev/null; echo task2 > "$run/task-2.md"
"$S/run.sh" "$run" 2 "$m" > /dev/null 2>&1; result "两轮之间有新提交，拒绝续跑" 4 $?

r=$(mkrepo); newrun "$r"; run=$(run_dir); m=$(msha); echo task > "$run/task-1.md"
"$S/run.sh" "$run" 1 "$m" > /dev/null 2>&1
echo x > "$r/.git/FETCH_HEAD"; echo task2 > "$run/task-2.md"
"$S/run.sh" "$run" 2 "$m" > /dev/null 2>&1; result "两轮之间 Git 管理目录变化，拒绝续跑" 4 $?

FAKE_VERSION="codex-cli 9.9.9" "$S/new-run.sh" "$(mkrepo)" > /dev/null 2>&1; result "new-run 拒绝未验证的 Codex 版本" 2 $?
mkdir -p "$T/empty"; git -C "$T/empty" init -q; "$S/new-run.sh" "$T/empty" > /dev/null 2>&1; result "new-run 拒绝空仓库" 2 $?
mkdir -p "$T/nogit"; "$S/new-run.sh" "$T/nogit" > /dev/null 2>&1; result "new-run 拒绝非 Git 目录" 2 $?

echo "=== 合计：通过 ${pass}，不符 ${failn}"
echo "临时目录：${T}（检查输出保留在其中，确认后可删除）"
[ "$failn" = 0 ]
