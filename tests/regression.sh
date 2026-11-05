#!/usr/bin/env bash
# codex-dispatch 脚本的回归测试：tests/regression.sh
# 用假的 codex 模拟事件和 session 记录，在隔离的 HOME/CODEX_HOME 中逐项验证越界检测。不调用真实模型。
set -uo pipefail
S=$(cd "$(dirname "$0")/../scripts" && pwd -P)
T=$(mktemp -d /tmp/codex-dispatch-regression.XXXXXX)
T=$(cd "$T" && pwd -P)
export HOME=$T/home XDG_CONFIG_HOME=$T/home/.config CODEX_HOME=$T/codex GIT_CONFIG_NOSYSTEM=1 PATH=$T/bin:$PATH
mkdir -p "$HOME" "$CODEX_HOME" "$T/bin" "$T/markers" "$T/outside"
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
[ -n "$tid" ] || tid=$(python3 -c 'import uuid; print(uuid.uuid4())')
sdir="$CODEX_HOME/sessions/2026/11/03"; mkdir -p "$sdir"
[ -e "$sdir/rollout-x-$tid.jsonl" ] || printf '{"type":"session_meta","payload":{"id":"%s"}}\n' "${FAKE_META_ID:-$tid}" > "$sdir/rollout-x-$tid.jsonl"
printf '{"type":"turn_context","payload":{"cwd":"%s","sandbox_policy":{"type":"%s"},"approval_policy":"%s","permission_profile":%s}}\n' \
  "${FAKE_CWD:-$(cd "$cwd" && pwd -P)}" "${FAKE_SANDBOX:-danger-full-access}" "${FAKE_APPROVAL:-never}" \
  "${FAKE_PROFILE:-{\"type\":\"disabled\"}}" >> "$sdir/rollout-x-$tid.jsonl"
# 与真实 Codex 一样，为新目录写入 projects 信任条目
real=$(cd "$cwd" && pwd -P)
grep -qF "[projects.\"$real\"]" "$CODEX_HOME/config.toml" 2>/dev/null || printf '\n[projects."%s"]\ntrust_level = "trusted"\n' "$real" >> "$CODEX_HOME/config.toml"
(cd "$cwd" && eval "${FAKE_ACTION:-:}")
started='{"type":"thread.started","thread_id":"'"$tid"'"}'
msg='{"type":"item.completed","item":{"id":"i0","type":"agent_message","text":"done"}}'
done_ev='{"type":"turn.completed","usage":{}}'
case "${FAKE_EVENTS:-}" in
  no-thread)      printf '%s\n' '{"type":"turn.started"}' "$msg" "$done_ev" ;;
  two-threads)    printf '%s\n' "$started" "$started" '{"type":"turn.started"}' "$msg" "$done_ev" ;;
  after-terminal) printf '%s\n' "$started" '{"type":"turn.started"}' "$msg" "$done_ev" \
                    '{"type":"item.completed","item":{"id":"i1","type":"agent_message","text":"late"}}' ;;
  two-terminal)   printf '%s\n' "$started" '{"type":"turn.started"}' "$msg" "$done_ev" "$done_ev" ;;
  *)              printf '%s\n' "$started" '{"type":"turn.started"}' "$msg" "$done_ev" ;;
esac
exit "${FAKE_RC:-0}"
EOF
chmod +x "$T/bin/codex"

pass=0 failn=0
result() {  # result <名称> <期望> <实际>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf 'ok    %-46s 期望=%s 实际=%s\n' "$1" "$2" "$3"
  else failn=$((failn + 1)); printf 'WRONG %-46s 期望=%s 实际=%s\n' "$1" "$2" "$3"; fi
}
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

mkrepo() {  # 新建仓库：已跟踪文件、被忽略文件、派单前已有的未跟踪文件、可执行 hook
  local r; r=$(mktemp -d "$T/repo.XXXXXX")
  git -C "$r" init -q
  echo a > "$r/tracked.txt"; echo '*.env' > "$r/.gitignore"
  git -C "$r" add . && git -C "$r" commit -qm base > /dev/null
  echo secret > "$r/local.env"; echo note > "$r/notes.txt"
  printf '#!/bin/sh\nexit 0\n' > "$r/.git/hooks/pre-commit"; chmod 755 "$r/.git/hooks/pre-commit"
  echo "$r"
}
# new-run 后设置 RUN、M（manifest 哈希）
newrun() { "$S/new-run.sh" "$@" > "$T/nr.txt" 2>&1 || return 1; RUN=$(sed -n 's/^RUN_DIR=//p' "$T/nr.txt"); M=$(sed -n 's/^MANIFEST_SHA=//p' "$T/nr.txt"); }
# 执行一轮：round <N> [线程ID]；设置 RC、TID
round() {
  local n=$1; [ -e "$RUN/task-$n.md" ] || echo "task $n" > "$RUN/task-$n.md"
  PATH="${PRE:-}$PATH" "$S/run.sh" "$RUN" "$n" "$M" "$(sha "$RUN/task-$n.md")" "${MODE:-write}" ${2:+"$2"} > "$T/run.txt" 2>&1; RC=$?
  TID=$(sed -n 's/^ROUND=.* THREAD_ID=//p' "$T/run.txt")
}
check() { PATH="${PRE:-}$PATH" "$S/check-run.sh" "$RUN" "$1" "$M" "$2" "${CMODE:-${MODE:-write}}" > "$T/check-${3//\//_}.txt" 2>&1; }

scenario() {  # scenario <名称> <期望退出码> <FAKE_ACTION> [额外监视路径...]
  local name=$1 want=$2 action=$3; shift 3
  local r; r=$(mkrepo); newrun "$r" "$@" || { result "$name" "$want" "new-run失败"; return; }
  FAKE_ACTION=$action round 1
  check 1 "$TID" "$name"; result "$name" "$want" "$?"
}

echo "=== 机械检查（0=PASS，1=FAIL）"
scenario "无改动"                           0 ':'
scenario "允许范围内改动与新文件"           0 'echo b >> tracked.txt; echo n > new.txt'
scenario "普通 git status 刷新 index"        0 'touch tracked.txt; git status > /dev/null'
scenario "建分支切换再删除（只改 reflog）"   1 'git branch tmp && git switch -q tmp && git switch -q main && git branch -q -D tmp'
scenario "assume-unchanged"                 1 'git update-index --assume-unchanged tracked.txt'
scenario "只改 hook 权限"                   1 'chmod 644 .git/hooks/pre-commit'
scenario "只改 .git/hooks 目录权限"          1 'chmod 700 .git/hooks'
scenario "改 .git/foo/index"                1 'mkdir -p .git/foo; echo x > .git/foo/index'
scenario "改已有被忽略文件（已登记监视）"   1 'echo changed > local.env' local.env
scenario "改已有被忽略文件（未登记，已知盲区）" 0 'echo changed > local.env'
scenario "改全局 Git config"                1 'git config --global core.editor vim'
scenario "写 FETCH_HEAD"                    1 'echo x > .git/FETCH_HEAD'
scenario "info/exclude 隐藏新文件"          1 'echo stealth.txt >> .git/info/exclude; echo p > stealth.txt'
scenario "改派单前已有的未跟踪文件"         1 'echo x >> notes.txt'
scenario "改 Codex 配置（新增配置项）"      1 'printf "\n[mcp_servers.x]\ncommand = \"evil\"\n" >> "$CODEX_HOME/config.toml"'
scenario "Codex 配置只加注释（不计入）"    0 'echo "# note" >> "$CODEX_HOME/config.toml"'
scenario "本仓库 Codex 项目表多出字段"      1 'echo "sandbox_mode = \"x\"" >> "$CODEX_HOME/config.toml"'
scenario "git add"                          1 'echo b >> tracked.txt; git add tracked.txt'
scenario "git commit"                       1 'echo b >> tracked.txt; git commit -qam x'
echo target > "$T/outside/watched-target"; ln -s "$T/outside/watched-target" "$T/outside/watched-link"
scenario "监视路径为符号链接，目标内容被改" 1 "echo changed > '$T/outside/watched-target'" "$T/outside/watched-link"
scenario "不存在的监视路径变成 FIFO"        1 "mkfifo '$T/outside/fifo-path'" "$T/outside/fifo-path"
FAKE_SANDBOX=workspace-write scenario "session sandbox 不符"         1 ':'
FAKE_APPROVAL=on-request     scenario "session approval 不符"        1 ':'
FAKE_CWD=/nonexistent        scenario "session cwd 不符"             1 ':'
FAKE_PROFILE='{"type":"x"}'  scenario "session permission_profile 不符" 1 ':'
FAKE_RC=7                    scenario "Codex 非零退出但事件显示完成" 1 ':'

r=$(mkrepo); real=$(cd "$r" && pwd -P)
printf '\n[projects."%s"]\ntrust_level = "untrusted"\n' "$real" >> "$CODEX_HOME/config.toml"
newrun "$r"
FAKE_ACTION="sed -i.bak 's#trust_level = \"untrusted\"#trust_level = \"trusted\"#' \"\$CODEX_HOME/config.toml\"" round 1
check 1 "$TID" "trust 改变"; result "本仓库 trust_level 从 untrusted 改为 trusted" 1 $?

r=$(mkrepo); printf 'x\n' > "$r/$(printf 'line\nbreak.txt')"; newrun "$r"
FAKE_ACTION='printf "y\n" > "$(printf "line\nbreak.txt")"' round 1
check 1 "$TID" "换行文件名"; result "改派单前已有的含换行文件名" 1 $?

echo "=== 快照不执行仓库配置的程序"
r=$(mkrepo)
for k in fsmonitor textconv clean; do printf '#!/bin/sh\necho %s >> %s/%s\ncat "$@" 2>/dev/null\n' "$k" "$T/markers" "$k" > "$T/bin/x-$k"; chmod +x "$T/bin/x-$k"; done
printf '*.txt diff=evil filter=evil\n' > "$r/.gitattributes"; git -C "$r" add .gitattributes; git -C "$r" commit -qm attrs > /dev/null
git -C "$r" config core.fsmonitor "$T/bin/x-fsmonitor"; git -C "$r" config diff.evil.textconv "$T/bin/x-textconv"; git -C "$r" config filter.evil.clean "$T/bin/x-clean"
rm -f "$T/markers"/*
newrun "$r"; FAKE_ACTION='echo b >> tracked.txt' round 1; check 1 "$TID" "exec-probe"
result "快照与检查期间被执行的程序" "无" "$(ls "$T/markers" | tr '\n' ' ' | sed 's/ $//' | grep . || echo 无)"

echo "=== 输出路径不能被符号链接重定向"
r=$(mkrepo); newrun "$r"; round 1; t1=$TID
ln -s "$T/outside" "$RUN/after-1"
check 1 "$t1" "after-symlink"; result "预置 after-1 符号链接后检查仍正常" 0 $?
result "运行目录外未被写入快照文件" 0 "$(find "$T/outside" -name 'head.txt' | wc -l | tr -d ' ')"
echo keep > "$T/outside/target"; ln -s "$T/outside/target" "$RUN/stderr-2.log"
round 2 "$t1"; result "预置 stderr-2.log 符号链接，拒绝执行" 2 "$RC"
result "符号链接目标未被截断" keep "$(cat "$T/outside/target")"
rm "$RUN/stderr-2.log"; ln -s "$T/outside" "$RUN/pre-2"
round 2 "$t1"; result "预置 pre-2 符号链接，拒绝执行" 2 "$RC"
rm "$RUN/pre-2"; mkdir "$RUN/.lock"
round 2 "$t1"; result "运行目录被占用，拒绝执行" 5 "$RC"
rmdir "$RUN/.lock"

echo "=== 证据与参数校验"
r=$(mkrepo); newrun "$r"; round 1; t1=$TID
jq '.branch = "evil"' "$RUN/manifest.json" > "$T/m.tmp" && cat "$T/m.tmp" > "$RUN/manifest.json"
check 1 "$t1" "manifest-tamper"; result "manifest 被篡改后 check-run" 3 $?

r=$(mkrepo); newrun "$r"; echo task > "$RUN/task-1.md"
"$S/run.sh" "$RUN" 1 0000 "$(sha "$RUN/task-1.md")" write > /dev/null 2>&1; result "run.sh 传入错误的 manifest 哈希" 3 $?
"$S/run.sh" "$RUN" 1 "$M" 0000 write > /dev/null 2>&1; result "run.sh 任务文件哈希不符" 3 $?
"$S/run.sh" "$RUN" abc "$M" x write > /dev/null 2>&1; result "run.sh 轮次非法" 2 $?
"$S/run.sh" "$RUN" 1 "$M" > /dev/null 2>&1; result "run.sh 缺少参数" 2 $?
echo task2 > "$RUN/task-2.md"; round 2 x; result "run.sh 跳过第 1 轮" 2 "$RC"
FAKE_RC=7 round 1; result "run.sh 传播 Codex 退出码" 7 "$RC"; t1=$TID
round 1; result "run.sh 重复执行同一轮" 2 "$RC"
round 2; result "第 2 轮未传线程 ID" 2 "$RC"
round 2 wrong-thread; result "第 2 轮线程 ID 与会话记录不符" 3 "$RC"

r=$(mkrepo); newrun "$r"; round 1; t1=$TID
jq '.thread_id = "evil"' "$RUN/state.json" > "$T/s.tmp" && cat "$T/s.tmp" > "$RUN/state.json"
round 2 "$t1"; result "state.json 线程 ID 被篡改，拒绝续跑" 3 "$RC"

r=$(mkrepo); newrun "$r"; round 1; t1=$TID
round 2 "$t1"; result "第 2 轮续跑" 0 "$RC"
check 2 "$t1" "round2"; result "第 2 轮机械检查" 0 $?

r=$(mkrepo); newrun "$r"; round 1; t1=$TID
echo c >> "$r/tracked.txt"; git -C "$r" commit -qam between > /dev/null
round 2 "$t1"; result "两轮之间有新提交，拒绝续跑" 4 "$RC"

r=$(mkrepo); newrun "$r"; round 1; t1=$TID
echo x > "$r/.git/FETCH_HEAD"
round 2 "$t1"; result "两轮之间 Git 管理目录变化，拒绝续跑" 4 "$RC"

FAKE_VERSION="codex-cli 9.9.9" "$S/new-run.sh" "$(mkrepo)" > /dev/null 2>&1; result "new-run 拒绝未验证的 Codex 版本" 2 $?
mkdir -p "$T/empty"; git -C "$T/empty" init -q; "$S/new-run.sh" "$T/empty" > /dev/null 2>&1; result "new-run 拒绝空仓库" 2 $?
mkdir -p "$T/nogit"; "$S/new-run.sh" "$T/nogit" > /dev/null 2>&1; result "new-run 拒绝非 Git 目录" 2 $?

echo "=== 符号链接、嵌套仓库与 submodule"
mkdir -p "$T/outside/wdir" "$T/outside/tdir"; echo t > "$T/outside/tdir/file"; ln -s "$T/outside/tdir" "$T/outside/wdir/nested"
scenario "监视目录内的目录符号链接，目标内容被改" 1 "echo changed > '$T/outside/tdir/file'" "$T/outside/wdir"
mkdir -p "$T/outside/loopdir"; ln -s "$T/outside/loopdir" "$T/outside/loopdir/self"
scenario "监视目录内有循环符号链接（无改动）" 0 ':' "$T/outside/loopdir"

r=$(mkrepo); mv "$r/.git/hooks" "$T/outside/hooksdir"; ln -s "$T/outside/hooksdir" "$r/.git/hooks"; newrun "$r"
FAKE_ACTION="echo '# x' >> '$T/outside/hooksdir/pre-commit'" round 1
check 1 "$TID" "hooks-symlink"; result ".git/hooks 是符号链接，目标 hook 被改" 1 $?

r=$(mkrepo); git init -q "$r/vendor"; echo v > "$r/vendor/v"; newrun "$r"
FAKE_ACTION='echo w > vendor/v' round 1
check 1 "$TID" "nested-repo"; result "改派单前已有的嵌套仓库内文件" 1 $?

r=$(mkrepo); git -C "$r" update-index --add --cacheinfo "160000,$(git -C "$r" rev-parse HEAD),sub"; git -C "$r" commit -qm gitlink > /dev/null
"$S/new-run.sh" "$r" > /dev/null 2>&1; rc=$?; result "submodule 状态无法采集时 new-run 失败" nonzero "$([ $rc -ne 0 ] && echo nonzero || echo 0)"

echo "=== 运行目录身份与基线锚定"
r=$(mkrepo); newrun "$r"; round 1; t1=$TID
mv "$RUN" "$RUN.moved"; ln -s "$RUN.moved" "$RUN"
round 2 "$t1"; result "运行目录被换成符号链接，run.sh 拒绝" 3 "$RC"
check 1 "$t1" "rundir-link"; result "运行目录被换成符号链接，check-run 拒绝" 3 $?
result "被链接的目录中没有新产物" 0 "$(find "$RUN.moved" -maxdepth 1 -name 'pre-2' | wc -l | tr -d ' ')"

r=$(mkrepo); newrun "$r"; round 1; t1=$TID
cp -Rp "$RUN" "$RUN.copy"; rm -rf "$RUN"; mv "$RUN.copy" "$RUN"
round 2 "$t1"; result "运行目录被换成内容相同的副本，拒绝" 3 "$RC"

r=$(mkrepo); newrun "$r"; round 1; t1=$TID
echo x >> "$RUN/baseline/head.txt"
round 2 "$t1"; result "基线文件被篡改，run.sh 拒绝" 3 "$RC"
check 1 "$t1" "baseline-tamper"; result "基线文件被篡改，check-run 拒绝" 3 $?

echo "=== Codex 配置符号链接身份"
mv "$CODEX_HOME/config.toml" "$T/cfg1.toml"; cp "$T/cfg1.toml" "$T/cfg2.toml"; ln -s "$T/cfg1.toml" "$CODEX_HOME/config.toml"
r=$(mkrepo); newrun "$r"
FAKE_ACTION="cp '$T/cfg1.toml' '$T/cfg2.toml'; ln -sfn '$T/cfg2.toml' \"\$CODEX_HOME/config.toml\"" round 1
check 1 "$TID" "cfg-retarget"; result "Codex 配置链接改指向内容相同的文件" 1 $?
rm "$CODEX_HOME/config.toml"; mv "$T/cfg1.toml" "$CODEX_HOME/config.toml"; rm -f "$T/cfg2.toml"

echo "=== 输入校验与脱敏"
"$S/new-run.sh" "$(mkrepo)" "$T/outside/$(printf 'watch\nfile')" > /dev/null 2>&1; result "监视路径含换行符，拒绝" 2 $?
r=$(mkrepo); git -C "$r" config core.hooksPath /; "$S/new-run.sh" "$r" > /dev/null 2>&1; result "hooksPath 为 /，拒绝扫描" 2 $?
mkdir -p "$T/outside/many"; for i in $(seq 1 20); do echo "$i" > "$T/outside/many/f$i"; done
CODEX_DISPATCH_MAX_ENTRIES=10 "$S/new-run.sh" "$(mkrepo)" "$T/outside/many" > /dev/null 2>&1; rc=$?
result "超出扫描上限时 new-run 失败" nonzero "$([ $rc -ne 0 ] && echo nonzero || echo 0)"
r=$(mkrepo); git -C "$r" remote add scp token123@example.com:private/repo.git; git -C "$r" remote add web https://user:tok456@example.com/x.git
git -C "$r" config demo.multiline "$(printf 'first\nSECRET-TOKEN')"; newrun "$r"
result "快照中不含 remote 凭证" absent "$(grep -qE 'token123|tok456' "$RUN/baseline/remotes.txt" && echo present || echo absent)"
result "快照中不含多行 config 值" absent "$(grep -q 'SECRET-TOKEN' "$RUN/baseline/config.txt" && echo present || echo absent)"
result "remote 记录主机名" "example.com example.com" "$(awk '{print $3}' "$RUN/baseline/remotes.txt" | sort -u | head -1) $(awk '{print $3}' "$RUN/baseline/remotes.txt" | sort -u | tail -1)"

echo "=== 第三轮复审场景"
mkdir -p "$T/shim"
shims='for c in cmp diff comm grep head tail cut sed sort find cat ls mktemp mv dirname; do printf "#!/bin/sh\nexit 0\n" > "$T/shim/$c"; chmod +x "$T/shim/$c"; done'
PRE="$T/shim:" scenario "替换未登记命令并改全局 Git config" 1 "$shims; git config --global core.editor evil"
for c in cmp diff comm grep head tail cut sed sort find cat ls mktemp mv dirname; do rm -f "$T/shim/$c"; done

: > "$T/outside/empty-include.cfg"; git config --global include.path "$T/outside/empty-include.cfg"
scenario "改基线时为空的 include 文件" 1 "printf '[core]\n\teditor = evil\n' > '$T/outside/empty-include.cfg'"
git config --global --unset include.path

mkdir -p "$T/subsrc"; git -C "$T/subsrc" init -q; echo s > "$T/subsrc/f"; git -C "$T/subsrc" add f; git -C "$T/subsrc" commit -qm s > /dev/null
mksub() { local r; r=$(mkrepo); git -C "$r" -c protocol.file.allow=always submodule add -q "$T/subsrc" sub > /dev/null 2>&1; git -C "$r" commit -qm sub > /dev/null; git -C "$r" config submodule.sub.ignore all; echo "$r"; }
r=$(mksub); newrun "$r"; round 1; check 1 "$TID" "sub-clean"; result "有 submodule 且无改动" 0 $?
r=$(mksub); newrun "$r"; FAKE_ACTION='echo x >> sub/f' round 1; check 1 "$TID" "sub-dirty"
result "改 submodule 工作树（ignore=all）" 1 $?

r=$(mkrepo); git init -q "$r/vendor"; echo v > "$r/vendor/v"; newrun "$r"
FAKE_ACTION='echo n > vendor/newfile' round 1; check 1 "$TID" "nested-new"; result "派单前已有的嵌套仓库中新增文件" 1 $?

r=$(mkrepo); mkdir -p "$r/.git/hooks/objects"; echo x > "$r/.git/hooks/objects/x"; newrun "$r"
FAKE_ACTION='echo y > .git/hooks/objects/x' round 1; check 1 "$TID" "hooks-objects"; result "改 .git/hooks/objects 中的文件" 1 $?

r=$(mkrepo); newrun "$r"; round 1; t1=$TID; chmod 777 "$RUN"
round 2 "$t1"; result "运行目录权限被放宽，run.sh 拒绝" 3 "$RC"
check 1 "$t1" "rundir-mode"; result "运行目录权限被放宽，check-run 拒绝" 3 $?

r=$(mkrepo); newrun "$r"; echo keep > "$T/outside/report-target"
FAKE_ACTION="ln -s '$T/outside/report-target' '$RUN/report-1.md'" round 1
result "执行中报告被换成符号链接，run.sh 拒绝" 3 "$RC"
result "报告链接目标未被覆盖" keep "$(cat "$T/outside/report-target")"
check 1 "$TID" "report-link"; result "报告是符号链接，check-run 判 FAIL" 1 $?

r=$(mkrepo); newrun "$r"; round 1; t1=$TID
mv "$RUN/state.json" "$T/outside/state.json"; ln -s "$T/outside/state.json" "$RUN/state.json"
round 2 "$t1"; result "state.json 被换成符号链接，拒绝" 3 "$RC"

echo "=== 实用加固（第四轮）"
r=$(mkrepo); echo dirty >> "$r/tracked.txt"; newrun "$r"
MODE=readonly round 1; MODE=readonly check 1 "$TID" "ro-dirty-clean"; result "只读：已有改动的工作树，无改动" 0 $?
r=$(mkrepo); echo dirty >> "$r/tracked.txt"; newrun "$r"
MODE=readonly FAKE_ACTION='echo again >> tracked.txt' round 1; MODE=readonly check 1 "$TID" "ro-dirty-again"
result "只读：已有改动的文件再次被改（status 不变）" 1 $?
r=$(mkrepo); echo dirty >> "$r/tracked.txt"; newrun "$r"; MODE=write round 1
result "写入：基线已有改动时拒绝" 2 "$RC"
r=$(mkrepo); git -C "$r" update-index --assume-unchanged tracked.txt; newrun "$r"
MODE=readonly FAKE_ACTION='echo x >> tracked.txt' round 1; MODE=readonly check 1 "$TID" "ro-assume"
result "只读：已有 assume-unchanged 的文件被改" 1 $?
r=$(mkrepo); git -C "$r" update-index --skip-worktree tracked.txt; newrun "$r"; MODE=write round 1
result "写入：基线有 skip-worktree 标记时拒绝" 2 "$RC"
r=$(mkrepo); git -C "$r" config core.filemode false; newrun "$r"
MODE=readonly FAKE_ACTION='chmod +x tracked.txt' round 1; MODE=readonly check 1 "$TID" "ro-filemode"
result "只读：core.filemode=false 时改可执行位" 1 $?
r=$(mkrepo); newrun "$r"
MODE=readonly FAKE_ACTION="cp tracked.txt '$T/outside/hl-$RANDOM'; ln -f \"\$(ls -t '$T'/outside/hl-* | head -1)\" tracked.txt" round 1
MODE=readonly check 1 "$TID" "ro-hardlink"; result "只读：已跟踪文件换成内容相同的硬链接" 1 $?
r=$(mkrepo); newrun "$r"; MODE=write FAKE_ACTION='echo w >> tracked.txt' round 1; t1=$TID
MODE=write check 1 "$t1" "w-then-ro-1"; result "写入轮改动已跟踪文件" 0 $?
MODE=readonly round 2 "$t1"; MODE=readonly check 2 "$t1" "w-then-ro-2"; result "写入轮之后的只读轮（无改动）" 0 $?
r=$(mkrepo); newrun "$r"; MODE=readonly round 1
MODE=readonly CMODE=write check 1 "$TID" "mode-mismatch"; result "检查模式与执行模式不同" 1 $?

r=$(mkrepo); printf '*.bin filter=req\n' > "$r/.gitattributes"; git -C "$r" config filter.req.clean cat; git -C "$r" config filter.req.smudge cat
git -C "$r" config filter.req.required true; echo x > "$r/a.bin"; git -C "$r" add .gitattributes a.bin; git -C "$r" commit -qm req > /dev/null
before=$(ls -d "$HOME"/.cache/codex-dispatch/run.* 2>/dev/null | wc -l | tr -d ' ')
"$S/new-run.sh" "$r" > /dev/null 2>&1; result "已跟踪文件使用必需 filter（如 LFS），拒绝" 2 $?
after=$(ls -d "$HOME"/.cache/codex-dispatch/run.* 2>/dev/null | wc -l | tr -d ' ')
result "new-run 失败时不留下半成品运行目录" "$before" "$after"
r=$(mkrepo); git -C "$r" config filter.req.clean cat; git -C "$r" config filter.req.required true
"$S/new-run.sh" "$r" > /dev/null 2>&1; result "配置了必需 filter 但没有文件使用，允许" 0 $?
r=$(mkrepo); git -C "$r" config 'http.https://user:tok999@example.com/.extraheader' X; newrun "$r"
result "config 键名中的凭证被脱敏" absent "$(grep -q tok999 "$RUN/baseline/config.txt" && echo present || echo absent)"

r=$(mkrepo); newrun "$r"; FAKE_EVENTS=no-thread round 1; result "缺少 thread.started，run.sh 返回 6" 6 "$RC"
r=$(mkrepo); newrun "$r"; FAKE_EVENTS=two-threads round 1; result "两个 thread.started，run.sh 返回 6" 6 "$RC"
check 1 "$TID" "two-threads"; result "两个 thread.started，check-run 判 FAIL" 1 $?
r=$(mkrepo); newrun "$r"; FAKE_EVENTS=after-terminal round 1; result "终止事件后还有消息，run.sh 返回 6" 6 "$RC"
result "报告取终止事件之前的消息" done "$(cat "$RUN/report-1.md")"
r=$(mkrepo); newrun "$r"; FAKE_EVENTS=two-terminal round 1; result "两个终止事件，run.sh 返回 6" 6 "$RC"

r=$(mkrepo); newrun "$r"
FAKE_ACTION='mkdir -p "$CODEX_HOME/sessions/0000"; cp "$sdir/rollout-x-$tid.jsonl" "$CODEX_HOME/sessions/0000/aaa-$tid.jsonl"' round 1
check 1 "$TID" "dup-session"; result "同一线程有两个 session 文件" 1 $?
r=$(mkrepo); newrun "$r"; round 1; sf=$(jq -r .session_path "$RUN/state.json"); echo '{bad' >> "$sf"
check 1 "$TID" "bad-session"; result "session 尾部有非法 JSON" 1 $?
r=$(mkrepo); newrun "$r"; round 1; sf=$(jq -r .session_path "$RUN/state.json"); cp "$sf" "$sf.real"; rm "$sf"; ln -s "$sf.real" "$sf"
check 1 "$TID" "link-session"; result "session 文件被换成符号链接" 1 $?
r=$(mkrepo); newrun "$r"; FAKE_META_ID=00000000-0000-0000-0000-000000000000 round 1
check 1 "$TID" "meta-session"; result "session 内部线程 ID 不符" 1 $?

r=$(mkrepo); real=$(cd "$r" && pwd -P); newrun "$r"
lk="$HOME/.cache/codex-dispatch/locks/$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(f"{s.st_dev}-{s.st_ino}")' "$real").lock"
mkdir -p "$lk"; round 1; result "仓库被另一个任务占用，拒绝" 5 "$RC"; rm -rf "$lk"

r=$(mkrepo); real=$(cd "$r" && pwd -P); printf '\n[projects."%s"]\ntrust_level = "trusted"\n' "$real" >> "$CODEX_HOME/config.toml"; newrun "$r"
FAKE_ACTION="python3 -c 'import sys; p=sys.argv[1]; e=\"\\n[projects.\\\"%s\\\"]\\ntrust_level = \\\"trusted\\\"\\n\" % sys.argv[2]; s=open(p).read(); open(p,\"w\").write(s.replace(e,\"\"))' \"\$CODEX_HOME/config.toml\" '$real'" round 1
check 1 "$TID" "trust-removed"; result "基线已信任本仓库，之后条目被删除" 1 $?

echo "=== 工具链替换（放在最后，会改动假 codex）"
r=$(mkrepo); newrun "$r"; round 1; t1=$TID
echo '# modified' >> "$T/bin/codex"
round 2 "$t1"; result "工具链被替换，run.sh 拒绝" 4 "$RC"
check 1 "$t1" "tools"; result "工具链被替换，check-run 判 FAIL" 1 $?

echo "=== 合计：通过 ${pass}，不符 ${failn}"
echo "临时目录：${T}（检查输出保留在其中，确认后可删除）"
[ "$failn" = 0 ]
