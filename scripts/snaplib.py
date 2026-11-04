#!/usr/bin/env python3
"""codex-dispatch 的快照、对比与证据辅助。

由 new-run.sh、snapshot.sh、run.sh、check-run.sh 调用，不单独使用。
所有决定 PASS/FAIL 的比对都在这里完成，只依赖 Python 标准库和已登记的 git，
不信任 PATH 中的 cmp、diff、grep 等未登记命令。
路径一律以 JSON 字符串输出，保证含空格或换行的路径也只占一行。
超出扫描上限或无法可靠采集时以非零状态退出（fail closed）。
"""
import difflib
import hashlib
import io
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import tomllib

# 单次调用的扫描上限；测试可用环境变量调小
MAX_ENTRIES = int(os.environ.get("CODEX_DISPATCH_MAX_ENTRIES", 200_000))
MAX_BYTES = int(os.environ.get("CODEX_DISPATCH_MAX_BYTES", 4 * 1024**3))

# 与基线逐行比对、有变化即 FAIL 的快照文件
STRICT_FILES = ["head.txt", "index.patch", "index-entries.txt", "refs.txt", "stash.txt", "remotes.txt",
                "config.txt", "worktrees.txt", "submodules.txt", "submodule-worktrees.txt",
                "count-objects.txt", "watched.txt"]


def q(s):
    return json.dumps(s, ensure_ascii=False)


def fail(msg, code=1):
    sys.stderr.write(msg + "\n")
    sys.exit(code)


def git(repo, *args, check=True):
    """只读调用 git：关闭 fsmonitor、optional locks 和该仓库配置的 filter，避免执行仓库配置的程序。"""
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0")
    names = subprocess.run(["git", "-C", repo, "config", "--name-only", "--get-regexp",
                            r"^filter\..*\.(clean|smudge|process)$"], capture_output=True, env=env).stdout
    opts = ["-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false"]
    for key in set(os.fsdecode(names).split()):
        opts += ["-c", key + "="]
    r = subprocess.run(["git", *opts, "-C", repo, *args], capture_output=True, env=env)
    if check and r.returncode != 0:
        fail(f"git {' '.join(args)} 失败：{r.stderr.decode(errors='replace').strip()}")
    return r


# ---------- 文件系统遍历 ----------

class Walker:
    """递归记录路径；跟随符号链接，按 (st_dev, st_ino) 防止循环，不跨文件系统下降。"""

    def __init__(self, out, prune):
        self.out = out
        self.prune = prune          # prune(child_path) -> 是否跳过该子目录
        self.entries = 0
        self.bytes = 0
        self.visited = set()

    def charge(self):
        self.entries += 1
        if self.entries > MAX_ENTRIES:
            fail(f"超出快照上限（条目 {MAX_ENTRIES}），拒绝继续；请缩小监视范围")

    def add_bytes(self, n):
        self.bytes += n
        if self.bytes > MAX_BYTES:
            fail(f"超出快照上限（字节 {MAX_BYTES}），拒绝继续；请缩小监视范围")

    def emit(self, *fields):
        self.out.write(" ".join(fields) + "\n")

    def file_digest(self, path):
        # O_NONBLOCK 防止目标被换成 FIFO 时阻塞；打开后再确认是普通文件
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                return None
            h = hashlib.sha256()
            while chunk := os.read(fd, 1 << 20):
                h.update(chunk)
                self.add_bytes(len(chunk))
            return h.hexdigest()
        finally:
            os.close(fd)

    def walk(self, path, label, root_dev=None):
        try:
            st = os.lstat(path)
        except FileNotFoundError:
            self.emit("MISSING", q(label))
            return
        self.charge()
        mode = format(stat.S_IMODE(st.st_mode), "o")
        if stat.S_ISLNK(st.st_mode):
            real = os.path.realpath(path)
            self.emit("L", mode, q(label), "->", q(os.readlink(path)), q(real))
            if not os.path.exists(path):
                self.emit("DANGLING", q(label))
                return
            # 跟随目标：以目标为新的起点，允许位于其他文件系统
            self.walk(real, label + " =>", os.stat(real).st_dev)
            return
        if stat.S_ISREG(st.st_mode):
            digest = self.file_digest(path)
            self.emit("F", mode, str(st.st_size), digest or "(changed-type)", q(label))
        elif stat.S_ISDIR(st.st_mode):
            self.emit("D", mode, q(label))
            if root_dev is None:
                root_dev = st.st_dev
            if st.st_dev != root_dev:
                self.emit("XDEV", q(label))
                return
            key = (st.st_dev, st.st_ino)
            if key in self.visited:
                self.emit("LOOP", q(label))
                return
            self.visited.add(key)
            for name in sorted(os.listdir(path)):
                child = os.path.join(path, name)
                if self.prune(child):
                    self.emit("PRUNED", q(label + "/" + name))
                    continue
                self.walk(child, label + "/" + name, root_dev)
        elif stat.S_ISFIFO(st.st_mode):
            self.emit("FIFO", mode, q(label))
        elif stat.S_ISSOCK(st.st_mode):
            self.emit("SOCKET", mode, q(label))
        elif stat.S_ISBLK(st.st_mode) or stat.S_ISCHR(st.st_mode):
            kind = "BLOCK" if stat.S_ISBLK(st.st_mode) else "CHAR"
            self.emit(kind, mode, str(st.st_rdev), q(label))
        else:
            self.emit("OTHER", mode, q(label))


def is_real_dir(path):
    return os.path.isdir(path) and not os.path.islink(path)


def is_git_dir(path):
    return os.path.isfile(os.path.join(path, "HEAD")) and os.path.isdir(os.path.join(path, "refs"))


def object_db_pruner(admin_dirs):
    """只跳过真正的对象库：Git 目录（含 modules/ 下子仓库的 Git 目录）直属的 objects，以及 lfs/objects。"""
    roots = [os.path.realpath(d) for d in admin_dirs]

    def prune(child):
        if os.path.basename(child) != "objects" or not is_real_dir(child):
            return False
        parent = os.path.dirname(child)
        if parent in roots or any(parent == os.path.join(r, "lfs") for r in roots):
            return True
        return any(parent.startswith(os.path.join(r, "modules") + os.sep) for r in roots) and is_git_dir(parent)
    return prune


def nested_repo_pruner(child):
    """工作树中只跳过嵌套仓库的 .git/objects。"""
    parent = os.path.dirname(child)
    return (os.path.basename(child) == "objects" and os.path.basename(parent) == ".git"
            and is_real_dir(child) and is_git_dir(parent))


# ---------- 快照子命令 ----------

def normalized_codex_config(path, repo):
    with open(path, "rb") as fh:
        data = tomllib.load(fh)
    projects = data.get("projects")
    if isinstance(projects, dict):
        for key in {repo, repo.removeprefix("/private")}:
            if projects.get(key) == {"trust_level": "trusted"}:
                del projects[key]
        if not projects:
            del data["projects"]
    return hashlib.sha256(json.dumps(data, sort_keys=True, default=str).encode()).hexdigest()


def codex_config_line(w, path, repo):
    """Codex 配置：记录链接身份和规范化内容，不复制配置文本。
    本仓库条目恰好只有 trust_level = "trusted" 时不计入（Codex 首次进入目录时自动写入）。"""
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        w.emit("MISSING", q(path))
        return
    ident = ["link", q(os.readlink(path)), q(os.path.realpath(path))] if stat.S_ISLNK(st.st_mode) else ["file"]
    try:
        digest = "toml:" + normalized_codex_config(path, repo)
    except (OSError, tomllib.TOMLDecodeError):
        digest = "raw:" + (w.file_digest(path) or "(not-regular)")
    w.emit("C", format(stat.S_IMODE(st.st_mode), "o"), *ident, digest, q(path))


def cmd_watched(manifest, repo, codex_cfg):
    with open(manifest, encoding="utf-8") as fh:
        paths = json.load(fh)["watched"]
    w = Walker(sys.stdout, lambda child: False)
    for p in paths:
        if p == codex_cfg:
            codex_config_line(w, p, repo)
        else:
            w.walk(p, p)


def cmd_gitadmin(index_path, *dirs):
    """Git 管理目录逐项记录；实际 index 文件单独标为 IDX，供比对时只放过它的字节变化。"""
    buf = io.StringIO()
    w = Walker(buf, object_db_pruner(dirs))
    for d in dirs:
        w.walk(d, d)
    idx = q(index_path)
    for line in buf.getvalue().splitlines():
        if line.startswith("F ") and line.endswith(" " + idx):
            line = "IDX " + line
        print(line)


def cmd_untracked(repo):
    """派单前已有的未跟踪文件；目录条目（如嵌套仓库 vendor/）递归记录内容。输出已排序。"""
    buf = io.StringIO()
    w = Walker(buf, nested_repo_pruner)
    for rel in sys.stdin.buffer.read().split(b"\0"):
        if rel:
            name = os.fsdecode(rel).rstrip("/")
            w.walk(os.path.join(repo, name), name)
    sys.stdout.write("".join(sorted(buf.getvalue().splitlines(keepends=True))))


def remote_host(url):
    if "://" in url:
        rest = url.split("://", 1)[1]
        host = rest.split("/", 1)[0].rsplit("@", 1)[-1]
        return host.split(":", 1)[0] if host.count(":") == 1 else host
    if ":" in url and "/" not in url.split(":", 1)[0]:
        return url.split(":", 1)[0].rsplit("@", 1)[-1]      # scp 形式 user@host:path
    return "(local)"


def cmd_remotes():
    """不保存完整 URL：只记录名称、类型、主机名和 URL 哈希。"""
    for line in sys.stdin.read().splitlines():
        parts = line.split()
        if len(parts) >= 3:
            name, url, kind = parts[0], parts[1], parts[-1]
            print(name, kind, remote_host(url), hashlib.sha256(url.encode()).hexdigest()[:16])


def cmd_config():
    """输入为 git config --list -z：每条记录为 key 或 key\\nvalue。只输出键名和完整值的哈希。"""
    for rec in sys.stdin.buffer.read().split(b"\0"):
        if rec:
            key, _, value = rec.partition(b"\n")
            print(os.fsdecode(key), hashlib.sha256(value).hexdigest()[:16])


def cmd_submodules(repo):
    """逐个记录已初始化 submodule 的 HEAD、分支、工作树状态和 diff 哈希；不受 submodule.*.ignore 影响。"""
    r = git(repo, "submodule", "foreach", "--recursive", "--quiet", 'printf "%s\\0" "$displaypath"')
    for rel in r.stdout.split(b"\0"):
        if not rel:
            continue
        name = os.fsdecode(rel)
        sub = os.path.join(repo, name)
        head = git(sub, "rev-parse", "HEAD").stdout.decode().strip()
        branch = git(sub, "symbolic-ref", "-q", "HEAD", check=False).stdout.decode().strip() or "(detached)"
        status = git(sub, "-c", "core.quotePath=true", "status", "--porcelain=v1",
                     "--untracked-files=all", "--ignore-submodules=none").stdout
        patch = git(sub, "diff", "--binary", "--no-ext-diff", "--no-textconv", "HEAD").stdout
        print(q(name), head, branch, "status:" + hashlib.sha256(status).hexdigest()[:16],
              "diff:" + hashlib.sha256(patch).hexdigest()[:16])
        for line in status.decode(errors="replace").splitlines():
            print("  ", q(name), line)


# ---------- 监视清单 ----------

def expand(path, base_dir, home):
    if path.startswith("~/"):
        return os.path.join(home, path[2:])
    return path if os.path.isabs(path) else os.path.join(base_dir, path)


def config_includes(cfg, home):
    """配置文件中 include.path 和 includeIf.*.path 指向的文件，相对路径按声明它的文件所在目录解析。"""
    if not os.path.isfile(cfg):
        return []
    r = subprocess.run(["git", "config", "-z", "--file", cfg, "--get-regexp", r"^include(if\..*)?\.path$"],
                       capture_output=True)
    out = []
    for rec in r.stdout.split(b"\0"):
        if rec:
            _, _, value = rec.partition(b"\n")
            out.append(expand(os.fsdecode(value), os.path.dirname(cfg), home))
    return out


def cmd_watch_list(repo, git_dir, common_dir, codex_cfg, home, xdg, *extras):
    """生成监视路径清单（JSON 数组）：Codex 配置、所有生效的 Git 配置文件及其 include 目标（即使为空或不存在）、
    全局 ignore/attributes、外部 hooksPath、用户指定路径。拒绝含换行或范围过大的路径。"""
    paths = [codex_cfg, os.path.join(repo, ".codex", "config.toml"),
             os.path.join(home, ".gitconfig"), os.path.join(xdg, "git", "config"),
             os.path.join(xdg, "git", "ignore"), os.path.join(xdg, "git", "attributes")]
    r = git(repo, "config", "--list", "--show-origin", "--name-only", "-z")
    configs = []
    for origin in r.stdout.split(b"\0")[0::2]:
        o = os.fsdecode(origin)
        if o.startswith("file:"):
            configs.append(expand(o[5:], repo, home))
    configs += [os.path.join(git_dir, "config"), os.path.join(common_dir, "config"),
                os.path.join(git_dir, "config.worktree"), os.path.join(home, ".gitconfig"),
                os.path.join(xdg, "git", "config")]
    seen, queue = set(), list(configs)
    while queue:
        c = os.path.realpath(queue.pop())
        if c in seen:
            continue
        seen.add(c)
        paths.append(c)
        queue.extend(config_includes(c, home))
    for key in ("core.excludesFile", "core.attributesFile", "core.hooksPath"):
        v = git(repo, "config", "--type=path", "--get", key, check=False).stdout.decode().strip()
        if v:
            paths.append(expand(v, repo, home))
    paths += [expand(p, repo, home) for p in extras]

    admin = (os.path.realpath(git_dir) + os.sep, os.path.realpath(common_dir) + os.sep)
    home_real, repo_real = os.path.realpath(home), os.path.realpath(repo)
    result = set()
    for p in paths:
        if "\n" in p:
            fail(f"监视路径不能包含换行符：{p!r}", 2)
        if (os.path.realpath(p) + os.sep).startswith(admin):
            continue        # Git 管理目录由快照单独覆盖
        if os.path.isdir(p):
            rp = os.path.realpath(p)
            if rp in ("/", home_real) or (repo_real + os.sep).startswith(rp.rstrip(os.sep) + os.sep):
                fail(f"监视路径范围过大（/、主目录，或仓库本身及其上级目录），拒绝扫描：{p}", 2)
        result.add(p)
    print(json.dumps(sorted(result), ensure_ascii=False))


# ---------- 对比 ----------

def label_of(line):
    i = line.find('"')
    if i < 0:
        return None
    return json.JSONDecoder().raw_decode(line, i)[0]


def read_lines(path):
    with open(path, encoding="utf-8", errors="surrogateescape") as fh:
        return fh.read().splitlines()


def show_diff(a, b, limit=20):
    for line in list(difflib.unified_diff(a, b, "baseline", "current", lineterm="", n=0))[2:2 + limit]:
        print("  " + line)


def cmd_compare(base, cur):
    """对比两份快照。有任一 FAIL 时退出码为 1；工作树改动只展示，由 Claude 判断是否在范围内。"""
    failed = False

    def bad(msg):
        nonlocal failed
        failed = True
        print("FAIL: " + msg)

    for name in STRICT_FILES:
        a, b = read_lines(os.path.join(base, name)), read_lines(os.path.join(cur, name))
        if a == b:
            print(f"ok:   {name} 未变")
        else:
            bad(f"{name} 有变化")
            show_diff(a, b)

    # 只放过实际 index 文件（IDX）的字节变化：条目不变时通常是普通 git status 刷新了 stat 缓存
    ga, gb = read_lines(os.path.join(base, "gitadmin.txt")), read_lines(os.path.join(cur, "gitadmin.txt"))
    na, nb = [l for l in ga if not l.startswith("IDX ")], [l for l in gb if not l.startswith("IDX ")]
    if na == nb:
        print("ok:   Git 管理目录未变")
    else:
        bad("Git 管理目录有变化")
        show_diff(na, nb, 30)
    if [l for l in ga if l.startswith("IDX ")] != [l for l in gb if l.startswith("IDX ")]:
        if read_lines(os.path.join(base, "index-entries.txt")) == read_lines(os.path.join(cur, "index-entries.txt")):
            print("WARN: index 文件字节变化但条目一致，可能是 git status 刷新了 stat 缓存")

    ua, ub = read_lines(os.path.join(base, "untracked.txt")), read_lines(os.path.join(cur, "untracked.txt"))
    sa, sb = set(ua), set(ub)
    gone = [l for l in ua if l not in sb]
    if gone:
        bad("派单前的未跟踪文件被修改或删除：")
        for l in gone[:20]:
            print("  " + l)
    else:
        print("ok:   派单前的未跟踪文件均未改动")
    # 派单前已有的未跟踪目录（含嵌套仓库）里出现的新内容同样不在任务范围内
    old_dirs = [label_of(l) + "/" for l in ua if l.startswith("D ")]
    added = [l for l in ub if l not in sa]
    inside = [l for l in added if any((label_of(l) or "").startswith(d) for d in old_dirs)]
    if inside:
        bad("派单前已有的未跟踪目录中出现新内容：")
        for l in inside[:20]:
            print("  " + l)
    others = [l for l in added if l not in inside]
    if others:
        print("INFO: 新增的未跟踪内容（判断是否在范围内）：")
        for l in others[:20]:
            print("  " + l)

    ia, ib = read_lines(os.path.join(base, "ignored.txt")), read_lines(os.path.join(cur, "ignored.txt"))
    if ia != ib:
        print("INFO: 被忽略文件清单有变化（内容不在审计范围内）：")
        show_diff(ia, ib)
    print("--- 工作树 status 差异（判断是否在范围内）")
    show_diff(read_lines(os.path.join(base, "status.txt")), read_lines(os.path.join(cur, "status.txt")), 50)
    sys.exit(1 if failed else 0)


# ---------- 证据文件 ----------

def file_sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def cmd_tools(*names):
    """记录工具链的路径、实际文件和哈希，供每轮复核是否被替换。"""
    out = []
    for name in names:
        path = shutil.which(name)
        if not path:
            fail(f"缺少依赖：{name}")
        real = os.path.realpath(path)
        out.append({"name": name, "path": path, "real": real, "sha256": file_sha(real)})
    print(json.dumps(out, ensure_ascii=False, sort_keys=True, separators=(",", ":")))


def cmd_digests(directory):
    """目录中各文件的哈希（JSON 对象），用于把基线文件锚定进 manifest。"""
    names = sorted(os.listdir(directory))
    print(json.dumps({n: file_sha(os.path.join(directory, n)) for n in names},
                     sort_keys=True, separators=(",", ":")))


def cmd_identity(path):
    """运行目录身份：设备号、inode、所有者和权限位。"""
    st = os.lstat(path)
    print(f"{st.st_dev}:{st.st_ino}:{st.st_uid}:{st.st_gid}:{stat.S_IMODE(st.st_mode):o}")


def cmd_regular(*paths):
    """要求证据文件都是普通文件，而不是符号链接或其他类型。"""
    bad = [p for p in paths if not (os.path.lexists(p) and stat.S_ISREG(os.lstat(p).st_mode))]
    for p in bad:
        print(f"不是普通文件（不存在、是符号链接或其他类型）：{p}")
    sys.exit(1 if bad else 0)


def cmd_write_report(events, report):
    """从 JSONL 中提取最后一条 agent_message 写成报告；目标已存在（含符号链接）时失败，不跟随链接。"""
    text = ""
    with open(events, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            item = ev.get("item") or {}
            if ev.get("type") == "item.completed" and item.get("type") == "agent_message":
                text = item.get("text") or ""
    try:
        fd = os.open(report, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except OSError as e:
        fail(f"无法创建报告（已存在或是符号链接）：{report}：{e}", 3)
    with os.fdopen(fd, "wb") as fh:
        fh.write(text.encode())


def cmd_state_update(state, thread_id, round_no):
    with open(state, encoding="utf-8") as fh:
        data = json.load(fh)
    if thread_id:
        data["thread_id"] = thread_id
    data["last_round"] = int(round_no)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(state), prefix=".state.")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(data, fh)
    os.replace(tmp, state)


def cmd_mkdtemp(parent, prefix):
    print(tempfile.mkdtemp(prefix=prefix, dir=parent))


def cmd_session(codex_home, thread_id):
    """在 sessions 下查找文件名含线程 ID 的 JSONL；找不到时不输出。"""
    for root, _, files in sorted(os.walk(os.path.join(codex_home, "sessions"))):
        for f in sorted(files):
            if thread_id in f and f.endswith(".jsonl"):
                print(os.path.join(root, f))
                return


COMMANDS = {
    "watched": cmd_watched, "gitadmin": cmd_gitadmin, "untracked": cmd_untracked, "remotes": cmd_remotes,
    "config": cmd_config, "submodules": cmd_submodules, "watch-list": cmd_watch_list, "compare": cmd_compare,
    "tools": cmd_tools, "digests": cmd_digests, "identity": cmd_identity, "regular": cmd_regular,
    "write-report": cmd_write_report, "state-update": cmd_state_update, "mkdtemp": cmd_mkdtemp,
    "session": cmd_session,
}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        fail("用法：snaplib.py <" + "|".join(COMMANDS) + "> ...", 2)
    COMMANDS[sys.argv[1]](*sys.argv[2:])
