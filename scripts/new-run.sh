#!/usr/bin/env bash
# 创建运行目录并保存基线：new-run.sh <仓库> [额外监视路径 ...]
# 须在工作树检查、工作区选择和分支处理之后调用。输出的哈希必须留在 Claude 会话里，后续脚本以 manifest 哈希为参数校验。
set -euo pipefail
umask 077
export LC_ALL=C
here=$(cd "$(dirname "$0")" && pwd -P)
. "$here/common.sh"

for t in codex git jq shasum python3; do
  command -v "$t" >/dev/null || { echo "缺少依赖：$t" >&2; exit 2; }
done
ver=$(codex --version 2>/dev/null | head -1)
supported=0
for v in "${SUPPORTED_CODEX_VERSIONS[@]}"; do [ "$ver" = "$v" ] && supported=1; done
[ $supported = 1 ] || { echo "Codex 版本未经验证：'$ver'。先按 SKILL.md 重新验证，再更新 common.sh。" >&2; exit 2; }

root=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || { echo "不是 Git 仓库：$1" >&2; exit 2; }
root=$(real_dir "$root")
shift
g() { safe_git "$root" "$@"; }
head=$(g rev-parse --verify -q HEAD) || { echo "仓库还没有任何提交，无法建立基线：$root" >&2; exit 2; }
git_dir=$(real_dir "$(g rev-parse --absolute-git-dir)")
common_dir=$(real_dir "$(g rev-parse --path-format=absolute --git-common-dir)")
index_file=$(g rev-parse --path-format=absolute --git-path index)
index_path="$(real_dir "$(dirname "$index_file")")/$(basename "$index_file")"

# 监视路径：Codex 配置、仓库外的 Git 配置文件（含 include）、全局 ignore/attributes、外部 hooksPath、用户指定路径
abs() { case "$1" in "~"/*) printf '%s\n' "$HOME/${1:2}" ;; /*) printf '%s\n' "$1" ;; *) printf '%s\n' "$root/$1" ;; esac; }
xdg=${XDG_CONFIG_HOME:-$HOME/.config}
watched=$(
  {
    echo "$(codex_home)/config.toml"
    echo "$root/.codex/config.toml"
    g config --list --show-origin --name-only 2>/dev/null | cut -f1 | sed -n 's/^file://p' | while IFS= read -r p; do abs "$p"; done
    for k in core.excludesFile core.attributesFile core.hooksPath; do
      v=$(g config --get "$k" 2>/dev/null) && abs "$v"
    done
    echo "$xdg/git/ignore"; echo "$xdg/git/attributes"
    for p in "$@"; do abs "$p"; done
  } | while IFS= read -r p; do
    case "$p" in "$git_dir"/*|"$common_dir"/*) ;; *) printf '%s\n' "$p" ;; esac   # Git 管理目录由快照单独覆盖
  done | sort -u
)

mkdir -p "$HOME/.cache/codex-dispatch"
run=$(mktemp -d "$HOME/.cache/codex-dispatch/run.XXXXXX")

jq -n --arg repo "$root" --arg git_dir "$git_dir" --arg common_dir "$common_dir" \
      --arg branch "$(g symbolic-ref -q --short HEAD || echo '(detached)')" --arg head "$head" \
      --arg codex_version "$ver" --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg sandbox "$EXPECTED_SANDBOX" --arg approval "$EXPECTED_APPROVAL" \
      --arg watched "$watched" --arg index_path "$index_path" --argjson profile "$EXPECTED_PERMISSION_PROFILE" \
      '{repo: $repo, git_dir: $git_dir, common_dir: $common_dir, index_path: $index_path, branch: $branch, head: $head,
        codex_version: $codex_version, created_at: $created,
        expected: {cwd: $repo, sandbox: $sandbox, approval: $approval, permission_profile: $profile},
        watched: ($watched | split("\n") | map(select(length > 0)))}' > "$run/manifest.json"
jq -n '{thread_id: null, last_round: 0}' > "$run/state.json"

mkdir "$run/baseline"
"$here/snapshot.sh" "$root" "$run/baseline" "$run/manifest.json"

echo "RUN_DIR=$run"
cat "$run/manifest.json"
echo "--- baseline status"
cat "$run/baseline/status.txt"
echo "--- 被忽略的文件（内容不在审计范围内；关键文件请作为额外监视路径重新建运行目录）"
cat "$run/baseline/ignored.txt"
echo "--- sha256（保留在会话中；MANIFEST_SHA 是 run.sh 和 check-run.sh 的第三个参数）"
echo "MANIFEST_SHA=$(shasum -a 256 "$run/manifest.json" | cut -d' ' -f1)"
(cd "$run" && shasum -a 256 baseline/*)
echo "--- 脚本 sha256（每次运行 run.sh 和 check-run.sh 前，用同一条命令复核）"
shasum -a 256 "$here"/*.sh
