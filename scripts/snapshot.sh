#!/usr/bin/env bash
# 采集仓库状态快照：snapshot.sh <仓库> <输出目录> <manifest.json>
# 输出目录必须由调用方新建且为空，本脚本不跟随符号链接创建目录。任何一项无法可靠采集时失败退出。
set -euo pipefail
umask 077
export LC_ALL=C
here=$(cd "$(dirname "$0")" && pwd -P)
. "$here/common.sh"

repo=$1 out=$2 manifest=$3
if [ -L "$out" ] || [ ! -d "$out" ] || [ -n "$(ls -A "$out")" ]; then
  echo "快照目录必须是新建的空目录且不是符号链接：$out" >&2; exit 2
fi
g() { safe_git "$repo" "$@"; }

{ g rev-parse HEAD; g symbolic-ref -q HEAD || echo "(detached)"; } > "$out/head.txt"
g status --porcelain=v1 --untracked-files=all > "$out/status.txt"
g diff --binary --no-ext-diff --no-textconv > "$out/worktree.patch"
g diff --cached --binary --no-ext-diff --no-textconv > "$out/index.patch"
g ls-files -s -v > "$out/index-entries.txt"   # 含 assume-unchanged、skip-worktree 标记
g for-each-ref --format='%(objectname) %(refname)' > "$out/refs.txt"
g stash list --format='%H %gd %s' > "$out/stash.txt"
# remote 只记录名称、类型、主机名和 URL 哈希；config 只记录键名和值的哈希，避免凭证进入快照和 diff 输出
g remote -v | snaplib remotes > "$out/remotes.txt"
g config --local --list -z | snaplib config > "$out/config.txt"
g worktree list --porcelain > "$out/worktrees.txt"
if ! g submodule status --recursive > "$out/submodules.txt" 2>&1; then
  echo "无法采集 submodule 状态，拒绝建立或比对快照：" >&2; cat "$out/submodules.txt" >&2; exit 1
fi
g count-objects -v > "$out/count-objects.txt"

# Git 管理目录（含 reflog、hooks、info/exclude、FETCH_HEAD 及目录权限）逐项记录，跟随指向目录的符号链接；
# 对象库体积大且只增不改，用 count-objects 代替
admin_dirs=()
while IFS= read -r d; do admin_dirs+=("$d"); done < <(
  { real_dir "$(g rev-parse --absolute-git-dir)"; real_dir "$(g rev-parse --path-format=absolute --git-common-dir)"; } | sort -u)
snaplib gitadmin "$(jq -r .index_path "$manifest")" "${admin_dirs[@]}" > "$out/gitadmin.txt"

# 派单前已有的未跟踪（未忽略）文件；嵌套仓库等目录条目递归记录内容
g ls-files -o --exclude-standard -z | snaplib untracked "$repo" | sort > "$out/untracked.txt"

# 被忽略的文件只列路径（目录折叠为一行），不做内容哈希；关键文件应作为额外监视路径传给 new-run.sh
g ls-files -o -i --exclude-standard --directory > "$out/ignored.txt"

# 仓库外的配置文件和用户指定的监视路径
snaplib watched "$manifest" "$repo" "$(codex_home)/config.toml" > "$out/watched.txt"
