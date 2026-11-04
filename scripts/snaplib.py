#!/usr/bin/env python3
"""codex-dispatch 快照辅助：为文件系统、Git 配置和工具链输出一行一项、可直接比对的摘要。

由 snapshot.sh、new-run.sh、run.sh、check-run.sh 调用，不单独使用。
路径一律以 JSON 字符串输出，保证含空格或换行的路径也只占一行。
超出扫描上限时以非零状态退出（fail closed），不跳过继续。
"""
import hashlib
import json
import os
import shutil
import stat
import sys
import tomllib

# 单次调用的扫描上限；测试可用环境变量调小
MAX_ENTRIES = int(os.environ.get("CODEX_DISPATCH_MAX_ENTRIES", 200_000))
MAX_BYTES = int(os.environ.get("CODEX_DISPATCH_MAX_BYTES", 4 * 1024**3))


def q(s):
    return json.dumps(s, ensure_ascii=False)


def fail(msg):
    sys.stderr.write(msg + "\n")
    sys.exit(1)


class Walker:
    """递归记录路径；跟随符号链接，按 (st_dev, st_ino) 防止循环，不跨文件系统下降。"""

    def __init__(self, out, prune):
        self.out = out
        self.prune = prune          # prune(parent_path, name) -> 是否跳过该子目录
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
                if self.prune(path, name) and os.path.isdir(child) and not os.path.islink(child):
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


def prune_git_objects(parent, name):
    """工作树中只跳过 .git/objects（嵌套仓库的对象库）。"""
    return name == "objects" and os.path.basename(parent) == ".git"


def prune_any_objects(parent, name):
    """Git 管理目录中跳过所有 objects（含 modules/*/objects、lfs/objects）；对象数量另行比对。"""
    return name == "objects"


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
    w = Walker(sys.stdout, prune_git_objects)
    for p in paths:
        if p == codex_cfg:
            codex_config_line(w, p, repo)
        else:
            w.walk(p, p)


def cmd_gitadmin(index_path, dirs):
    """Git 管理目录逐项记录；实际 index 文件单独标为 IDX，供比对时只放过它的字节变化。"""
    import io
    buf = io.StringIO()
    w = Walker(buf, prune_any_objects)
    for d in dirs:
        w.walk(d, d)
    idx = q(index_path)
    for line in buf.getvalue().splitlines():
        if line.startswith("F ") and line.endswith(" " + idx):
            line = "IDX " + line
        print(line)


def cmd_untracked(repo):
    """派单前已有的未跟踪文件；目录条目（如嵌套仓库 vendor/）递归记录内容。"""
    w = Walker(sys.stdout, prune_git_objects)
    for rel in sys.stdin.buffer.read().split(b"\0"):
        if rel:
            name = os.fsdecode(rel).rstrip("/")
            w.walk(os.path.join(repo, name), name)


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


def file_sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def cmd_tools(names):
    """记录工具链的路径、实际文件和哈希，供每轮复核是否被替换。"""
    out = []
    for name in names:
        path = shutil.which(name)
        if not path:
            fail(f"缺少依赖：{name}")
        real = os.path.realpath(path)
        out.append({"name": name, "path": path, "real": real, "sha256": file_sha(real)})
    print(json.dumps(out, ensure_ascii=False, sort_keys=True))


def cmd_digests(directory):
    """目录中各文件的哈希（JSON 对象），用于把基线文件锚定进 manifest。"""
    names = sorted(os.listdir(directory))
    print(json.dumps({n: file_sha(os.path.join(directory, n)) for n in names}, sort_keys=True, separators=(",", ":")))


def cmd_identity(path):
    st = os.stat(path)
    print(f"{st.st_dev}:{st.st_ino}")


def main():
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "watched":
        cmd_watched(*args)
    elif cmd == "gitadmin":
        cmd_gitadmin(args[0], args[1:])
    elif cmd == "untracked":
        cmd_untracked(args[0])
    elif cmd == "remotes":
        cmd_remotes()
    elif cmd == "config":
        cmd_config()
    elif cmd == "tools":
        cmd_tools(args)
    elif cmd == "digests":
        cmd_digests(args[0])
    elif cmd == "identity":
        cmd_identity(args[0])
    else:
        fail(f"未知子命令：{cmd}")


if __name__ == "__main__":
    main()
