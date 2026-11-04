#!/usr/bin/env bash
# codex-dispatch 脚本共用的常量和函数，由其他脚本 source。

# 已实测过的 Codex 版本；升级后先按 SKILL.md 重新验证，再把新版本加进来
SUPPORTED_CODEX_VERSIONS=("codex-cli 0.166.0")
# 用户决定跟随 Codex 默认配置，这里是验收时断言的期望值
EXPECTED_SANDBOX="danger-full-access"
EXPECTED_APPROVAL="never"
EXPECTED_PERMISSION_PROFILE='{"type":"disabled"}'

codex_home() { printf '%s\n' "${CODEX_HOME:-$HOME/.codex}"; }

real_dir() { (cd "$1" 2>/dev/null && pwd -P); }

sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

file_mode() {
  case "$(uname -s)" in
    Darwin) stat -f '%Lp' "$1" ;;
    Linux) stat -c '%a' -- "$1" ;;
    *) echo "不支持的平台：$(uname -s)" >&2; return 1 ;;
  esac
}

# 跟随符号链接取目标的权限
target_mode() {
  case "$(uname -s)" in
    Darwin) stat -L -f '%Lp' "$1" ;;
    Linux) stat -L -c '%a' -- "$1" ;;
    *) return 1 ;;
  esac
}

# 运行目录的互斥锁，防止同一运行目录被并发操作；退出时释放
acquire_lock() {
  mkdir "$1/.lock" 2>/dev/null || { echo "运行目录正被占用（$1/.lock 已存在）；确认没有其他进程在用后再手动删除" >&2; exit 5; }
  trap 'rmdir "'"$1"'/.lock" 2>/dev/null' EXIT
}

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

# 符号链接目标的类型、权限、大小和内容哈希（只跟随一层）
target_desc() {
  local p=$1
  if [ -f "$p" ]; then printf '[F %s %s %s]' "$(target_mode "$p")" "$(wc -c < "$p" | tr -d ' ')" "$(sha_of "$p")"
  elif [ -d "$p" ]; then printf '[D %s]' "$(target_mode "$p")"
  elif [ ! -e "$p" ]; then printf '[MISSING]'
  else printf '[SPECIAL]'
  fi
}

# 输出单个路径的类型、权限、大小和内容哈希；路径用 %q 转义，保证一项一行
hash_one() {
  local p=$1 label
  label=$(printf '%q' "${2:-$1}")
  if [ -L "$p" ]; then
    printf 'L %s -> %q %s\n' "$label" "$(readlink "$p")" "$(target_desc "$p")"
  elif [ -f "$p" ]; then
    printf 'F %s %s %s %s\n' "$(file_mode "$p")" "$(wc -c < "$p" | tr -d ' ')" "$(sha_of "$p")" "$label"
  elif [ -d "$p" ]; then printf 'D %s %s\n' "$(file_mode "$p")" "$label"
  elif [ -p "$p" ]; then printf 'FIFO %s %s\n' "$(file_mode "$p")" "$label"
  elif [ -S "$p" ]; then printf 'SOCKET %s %s\n' "$(file_mode "$p")" "$label"
  elif [ -b "$p" ]; then printf 'BLOCK %s %s\n' "$(file_mode "$p")" "$label"
  elif [ -c "$p" ]; then printf 'CHAR %s %s\n' "$(file_mode "$p")" "$label"
  elif [ ! -e "$p" ]; then printf 'MISSING %s\n' "$label"
  else printf 'OTHER %s\n' "$label"
  fi
}

# Codex 每次在新目录运行都会写入 [projects."<目录>"] trust_level = "trusted"。
# 所以 Codex 配置按 TOML 解析后做规范化哈希：本仓库条目恰好只有 trust_level = "trusted" 时才排除，
# 其他取值或多出字段仍计入比较。不复制配置内容；注释改动不计入。
codex_config_line() {
  local f=$1 repo=$2 digest
  [ -e "$f" ] || { printf 'MISSING %s\n' "$f"; return 0; }
  digest=$(python3 -I - "$f" "$repo" <<'PY'
import hashlib, json, sys, tomllib
path, repo = sys.argv[1], sys.argv[2]
with open(path, "rb") as fh:
    data = tomllib.load(fh)
projects = data.get("projects")
if isinstance(projects, dict):
    for key in {repo, repo.removeprefix("/private")}:
        if projects.get(key) == {"trust_level": "trusted"}:
            del projects[key]
    if not projects:
        del data["projects"]
print(hashlib.sha256(json.dumps(data, sort_keys=True, default=str).encode()).hexdigest())
PY
  ) || return 1
  printf 'C %s %s %s（本仓库仅含 trust_level = "trusted" 的条目不计入）\n' "$(file_mode "$f")" "$digest" "$f"
}

# 路径为目录时递归列出其中所有条目；指向目录的符号链接跟随一层，避免循环
hash_tree() {
  local p=$1 followed=${2:-0} q
  hash_one "$p"
  if [ -L "$p" ] && [ -d "$p" ] && [ "$followed" = 0 ]; then
    hash_tree "$(real_dir "$p")" 1
  elif [ -d "$p" ] && [ ! -L "$p" ]; then
    find "$p" -mindepth 1 -print0 | sort -z | while IFS= read -r -d '' q; do hash_one "$q"; done
  fi
}
