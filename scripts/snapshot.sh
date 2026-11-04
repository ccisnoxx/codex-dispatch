#!/usr/bin/env bash
# 采集仓库状态快照：snapshot.sh <仓库> <输出目录> <manifest.json>
# 派单前写入 baseline/，每轮前后写入 pre-N/、after-N/，由 compare.sh 逐项对比。
set -euo pipefail
umask 077
export LC_ALL=C
here=$(cd "$(dirname "$0")" && pwd -P)
. "$here/common.sh"

repo=$1 out=$2 manifest=$3
mkdir -p "$out"
g() { safe_git "$repo" "$@"; }

{ g rev-parse HEAD; g symbolic-ref -q HEAD || echo "(detached)"; } > "$out/head.txt"
g status --porcelain=v1 --untracked-files=all > "$out/status.txt"
g diff --binary --no-ext-diff --no-textconv > "$out/worktree.patch"
g diff --cached --binary --no-ext-diff --no-textconv > "$out/index.patch"
g ls-files -s -v > "$out/index-entries.txt"   # 含 assume-unchanged、skip-worktree 标记
g for-each-ref --format='%(objectname) %(refname)' > "$out/refs.txt"
g stash list --format='%H %gd %s' > "$out/stash.txt"
g remote -v > "$out/remotes.txt"
g config --local --list > "$out/config.txt"
g worktree list --porcelain > "$out/worktrees.txt"
g submodule status --recursive > "$out/submodules.txt" 2>&1 || echo "(submodule status failed)" >> "$out/submodules.txt"
g count-objects -v > "$out/count-objects.txt"

# Git 管理目录（含 reflog、hooks、info/exclude、FETCH_HEAD 等）逐文件记录；对象库体积大且只增不改，用 count-objects 代替
{ real_dir "$(g rev-parse --absolute-git-dir)"; real_dir "$(g rev-parse --path-format=absolute --git-common-dir)"; } \
  | sort -u | while IFS= read -r d; do
  (cd "$d" && find . -type d -name objects -prune -o \( -type f -o -type l \) -print0 | sort -z \
     | while IFS= read -r -d '' q; do hash_one "$q" "$d/${q#./}"; done)
done > "$out/gitadmin.txt"

# 派单前已有的未跟踪（未忽略）文件：status 只给路径，这里补上内容哈希
g ls-files -o --exclude-standard -z | while IFS= read -r -d '' p; do
  hash_one "$repo/$p" "$p"
done | sort > "$out/untracked.txt"

# 被忽略的文件只列路径（目录折叠为一行），不做内容哈希；关键文件应作为额外监视路径传给 new-run.sh
g ls-files -o -i --exclude-standard --directory > "$out/ignored.txt"

# 仓库外的配置文件和用户指定的监视路径
codex_cfg="$(codex_home)/config.toml"
jq -r '.watched[]' "$manifest" | while IFS= read -r p; do
  if [ "$p" = "$codex_cfg" ]; then codex_config_line "$p" "$repo" || hash_tree "$p"; else hash_tree "$p"; fi
done > "$out/watched.txt"
