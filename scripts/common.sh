#!/usr/bin/env bash
# codex-dispatch 脚本共用的常量和函数，由其他脚本 source。

# 已实测过的 Codex 版本；升级后先按 SKILL.md 重新验证，再把新版本加进来
SUPPORTED_CODEX_VERSIONS=("codex-cli 0.166.0")
# 用户决定跟随 Codex 默认配置，这里是验收时断言的期望值
EXPECTED_SANDBOX="danger-full-access"
EXPECTED_APPROVAL="never"
EXPECTED_PERMISSION_PROFILE='{"type":"disabled"}'
# 每轮复核是否被替换的工具链
TOOLS=(codex git jq python3 shasum bash)

SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

codex_home() { printf '%s\n' "${CODEX_HOME:-$HOME/.codex}"; }

real_dir() { (cd "$1" 2>/dev/null && pwd -P); }

sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

snaplib() { PYTHONDONTWRITEBYTECODE=1 python3 -I "$SCRIPTS_DIR/snaplib.py" "$@"; }

# 只读调用 git：关闭 fsmonitor、仓库配置的 filter 和 optional locks。
# 否则 status/diff 会执行仓库配置的程序，或刷新 index。
safe_git() {
  local repo=$1; shift
  local args=(-c core.fsmonitor=false -c core.quotePath=true -c core.untrackedCache=false)
  local name
  while IFS= read -r name; do
    [ -n "$name" ] && args+=(-c "filter.$name.clean=" -c "filter.$name.smudge=" -c "filter.$name.process=")
  done < <(GIT_OPTIONAL_LOCKS=0 git -C "$repo" config --name-only --get-regexp '^filter\..*\.(clean|smudge|process)$' 2>/dev/null \
             | sed -E 's/^filter\.(.*)\.(clean|smudge|process)$/\1/' | sort -u)
  GIT_OPTIONAL_LOCKS=0 git "${args[@]}" -C "$repo" "$@"
}

# 运行目录的互斥锁，防止同一运行目录被并发操作；退出时释放
acquire_lock() {
  mkdir "$1/.lock" 2>/dev/null || { echo "运行目录正被占用（$1/.lock 已存在）；确认没有其他进程在用后再手动删除" >&2; exit 5; }
  trap 'rmdir "'"$1"'/.lock" 2>/dev/null' EXIT
}

# run.sh 和 check-run.sh 共用：校验运行目录本身、manifest 和基线都与会话记录一致，然后加锁。
# 运行目录必须以物理绝对路径传入；不一致时退出 3，不在被替换的目录里写任何东西。
verify_run() {
  local run=$1 want=$2 m="$1/manifest.json"
  if [ -L "$run" ] || [ "$(real_dir "$run")" != "$run" ]; then
    echo "运行目录必须是不含符号链接的物理绝对路径：$run" >&2; exit 3
  fi
  [ ! -L "$m" ] && [ "$(sha_of "$m")" = "$want" ] || { echo "manifest.json 哈希与会话记录不一致" >&2; exit 3; }
  [ "$(jq -r .run_dir "$m")" = "$run" ] && [ "$(snaplib identity "$run")" = "$(jq -r .run_identity "$m")" ] \
    || { echo "运行目录与建立基线时不是同一个目录（路径或 inode 不同）" >&2; exit 3; }
  [ ! -L "$run/baseline" ] && [ "$(snaplib digests "$run/baseline")" = "$(jq -cS .baseline_sha256 "$m")" ] \
    || { echo "基线文件与 manifest 记录不一致" >&2; exit 3; }
  acquire_lock "$run"
}

# 工具链是否与建立基线时一致；不一致时输出差异并返回 1
tools_unchanged() {
  local m=$1 now
  now=$(snaplib tools "${TOOLS[@]}") || return 1
  [ "$(jq -cS . <<<"$now")" = "$(jq -cS .tools "$m")" ] && return 0
  diff <(jq -r '.tools[] | "\(.name) \(.real) \(.sha256)"' "$m") <(jq -r '.[] | "\(.name) \(.real) \(.sha256)"' <<<"$now") >&2
  return 1
}
