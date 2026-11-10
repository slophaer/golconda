# newc-diff.py A B: the header fields in which two newc cpio archives differ, entry by entry.
# checks.initrd-reproducible prints it when two builds of the initrd differ. Exit 0 when the
# archives have the same entries with the same headers and data, 1 otherwise.
import sys
from collections import Counter

FIELDS = (
    "ino mode uid gid nlink mtime filesize devmajor devminor rdevmajor rdevminor namesize check"
).split()


def entries(path):
    data = open(path, "rb").read()
    off = 0
    while True:
        head = data[off : off + 110]
        if head[:6] != b"070701":
            sys.exit(f"{path}: no newc header at {off}")
        h = {k: int(head[6 + 8 * i : 14 + 8 * i], 16) for i, k in enumerate(FIELDS)}
        name = data[off + 110 : off + 110 + h["namesize"] - 1].decode("utf-8", "replace")
        off = (off + 110 + h["namesize"] + 3) & ~3
        body = data[off : off + h["filesize"]]
        off = (off + h["filesize"] + 3) & ~3
        if name == "TRAILER!!!":
            return
        yield name, h, body


a = list(entries(sys.argv[1]))
b = list(entries(sys.argv[2]))
print(f"{len(a)} and {len(b)} entries")
diffs = Counter()
first = {}
for (na, ha, da), (nb, hb, db) in zip(a, b):
    if na != nb:
        diffs["name"] += 1
        first.setdefault("name", f"{na} / {nb}")
        continue
    for k in FIELDS:
        if ha[k] != hb[k]:
            diffs[k] += 1
            first.setdefault(k, f"{na}: {ha[k]} / {hb[k]}")
    if da != db:
        diffs["data"] += 1
        first.setdefault("data", na)
for k, n in diffs.most_common():
    print(f"{k} differs in {n} entries; first: {first[k]}")
sys.exit(0 if not diffs and len(a) == len(b) else 1)
