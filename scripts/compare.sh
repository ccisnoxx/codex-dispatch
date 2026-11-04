#!/usr/bin/env bash
# 对比两份快照：compare.sh <基线目录> <当前目录>
# 有任一 FAIL 时退出码为 1。工作树改动（status、worktree.patch、新文件）只展示，由 Claude 判断是否在范围内。
set -uo pipefail
export LC_ALL=C
base=$1 cur=$2
fail=0
bad() { echo "FAIL: $*"; fail=1; }
ok() { echo "ok:   $*"; }

for f in head.txt index.patch index-entries.txt refs.txt stash.txt remotes.txt config.txt \
         worktrees.txt submodules.txt count-objects.txt watched.txt; do
  if cmp -s "$base/$f" "$cur/$f"; then ok "$f 未变"; else bad "$f 有变化"; diff "$base/$f" "$cur/$f" | head -20; fi
done

# index 文件字节变化而条目不变，通常是普通 git status 刷新了 stat 缓存，只警告
admin_diff=$(diff <(grep -v '/index$' "$base/gitadmin.txt") <(grep -v '/index$' "$cur/gitadmin.txt"))
if [ -z "$admin_diff" ]; then ok "Git 管理目录未变"; else bad "Git 管理目录有变化"; echo "$admin_diff" | head -30; fi
if ! cmp -s <(grep '/index$' "$base/gitadmin.txt") <(grep '/index$' "$cur/gitadmin.txt"); then
  if cmp -s "$base/index-entries.txt" "$cur/index-entries.txt"; then
    echo "WARN: index 文件字节变化但条目一致，可能是 git status 刷新了 stat 缓存"
  fi
fi

missing=$(comm -23 "$base/untracked.txt" "$cur/untracked.txt")
if [ -z "$missing" ]; then ok "派单前的未跟踪文件均未改动"; else bad "派单前的未跟踪文件被修改或删除："; echo "$missing"; fi

ign=$(diff "$base/ignored.txt" "$cur/ignored.txt")
[ -z "$ign" ] || { echo "INFO: 被忽略文件清单有变化（内容不在审计范围内）："; echo "$ign" | head -20; }
echo "--- 工作树 status 差异（判断是否在范围内）"
diff "$base/status.txt" "$cur/status.txt"
exit $fail
