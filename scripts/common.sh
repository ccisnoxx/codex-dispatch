#!/usr/bin/env bash
# codex-dispatch 脚本共用的常量和函数，由其他脚本 source。

# 已实测过的 Codex 版本；升级后先按 SKILL.md 重新验证，再把新版本加进来
SUPPORTED_CODEX_VERSIONS=("codex-cli 0.166.0")
# 用户决定跟随 Codex 默认配置，这里是验收时断言的期望值
EXPECTED_SANDBOX="danger-full-access"
EXPECTED_APPROVAL="never"

codex_home() { printf '%s\n' "${CODEX_HOME:-$HOME/.codex}"; }

real_dir() { (cd "$1" 2>/dev/null && pwd -P); }

file_mode() {
  case "$(uname -s)" in
    Darwin) stat -f '%Lp' "$1" ;;
    Linux) stat -c '%a' -- "$1" ;;
    *) echo "不支持的平台：$(uname -s)" >&2; return 1 ;;
  esac
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

# 输出单个路径的类型、权限、大小和内容哈希
hash_one() {
  local p=$1 label=${2:-$1}
  if [ -L "$p" ]; then
    printf 'L %s -> %s\n' "$label" "$(readlink "$p")"
  elif [ -f "$p" ]; then
    printf 'F %s %s %s %s\n' "$(file_mode "$p")" "$(wc -c < "$p" | tr -d ' ')" \
      "$(shasum -a 256 "$p" | cut -d' ' -f1)" "$label"
  elif [ -d "$p" ]; then
    printf 'D %s %s\n' "$(file_mode "$p")" "$label"
  else
    printf 'M %s\n' "$label"
  fi
}

# Codex 每次在新目录运行都会写入 [projects."<目录>"] trust_level，
# 所以 Codex 配置按 TOML 解析后做规范化哈希，只排除本仓库这一项；不复制配置内容。注释改动不计入。
codex_config_line() {
  local f=$1 repo=$2 digest
  [ -e "$f" ] || { printf 'M %s\n' "$f"; return 0; }
  digest=$(python3 -I - "$f" "$repo" <<'PY'
import hashlib, json, sys, tomllib
path, repo = sys.argv[1], sys.argv[2]
with open(path, "rb") as fh:
    data = tomllib.load(fh)
projects = data.get("projects")
if isinstance(projects, dict):
    for key in (repo, repo.removeprefix("/private")):
        projects.pop(key, None)
    if not projects:
        del data["projects"]
print(hashlib.sha256(json.dumps(data, sort_keys=True, default=str).encode()).hexdigest())
PY
  ) || return 1
  printf 'C %s %s %s（已排除本仓库的 projects 条目）\n' "$(file_mode "$f")" "$digest" "$f"
}

# 路径为目录时递归列出其中所有条目；不存在时也输出一行，便于发现新建
hash_tree() {
  local p=$1 q
  hash_one "$p"
  if [ -d "$p" ] && [ ! -L "$p" ]; then
    find "$p" -mindepth 1 -print0 | sort -z | while IFS= read -r -d '' q; do hash_one "$q"; done
  fi
}
