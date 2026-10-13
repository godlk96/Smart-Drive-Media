"""测量 media_resource 里 DVR 样本的真实时长（解析 MP4 moov/mvhd，无需 ffprobe）。

用途：判断"一文件一切片、切片时长 60s"的网格模型是否与真实数据一致。
如果每个机位每个行程只有一个文件，而文件时长远超 60s，
那么 buildTimeGrid() 会算出 sliceCount=1、总时长 60s —— 与真实数据不符。
"""

import os
import struct
import sys


def read_boxes(f, end, depth=0, path=""):
    """递归遍历 box，产出 (type, start, size, header_size)。"""
    while f.tell() < end:
        start = f.tell()
        header = f.read(8)
        if len(header) < 8:
            return
        size, btype = struct.unpack(">I4s", header)
        header_size = 8
        if size == 1:
            size = struct.unpack(">Q", f.read(8))[0]
            header_size = 16
        elif size == 0:
            size = end - start
        btype = btype.decode("latin1")
        yield btype, start, size, header_size
        if size < header_size:
            return
        f.seek(start + size)


def find_mvhd(f, end):
    """在 moov 下找 mvhd，返回 (timescale, duration)。"""
    for btype, start, size, hsize in read_boxes(f, end):
        if btype == "moov":
            f.seek(start + hsize)
            for b2, s2, sz2, h2 in read_boxes(f, start + size):
                if b2 == "mvhd":
                    f.seek(s2 + h2)
                    version = struct.unpack(">B", f.read(1))[0]
                    f.read(3)  # flags
                    if version == 1:
                        f.read(16)  # creation + modification (8 bytes each)
                        timescale = struct.unpack(">I", f.read(4))[0]
                        duration = struct.unpack(">Q", f.read(8))[0]
                    else:
                        f.read(8)
                        timescale = struct.unpack(">I", f.read(4))[0]
                        duration = struct.unpack(">I", f.read(4))[0]
                    return timescale, duration
                f.seek(s2 + sz2)
    return None, None


def mp4_duration_sec(path):
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            # 优先 moov；样本可能把 moov 放在尾部
            ts, dur = find_mvhd(f, size)
        if ts and ts > 0 and dur:
            return dur / ts
    except Exception as exc:  # noqa: BLE001
        return f"ERR {exc}"
    return None


root = sys.argv[1] if len(sys.argv) > 1 else "media_resource"
rows = []
for dirpath, _dirs, files in os.walk(root):
    for name in sorted(files):
        if not name.lower().endswith((".mp4", ".mov", ".ts")):
            continue
        p = os.path.join(dirpath, name)
        mb = os.path.getsize(p) / (1024 * 1024)
        d = mp4_duration_sec(p)
        rows.append((name, mb, d))

print(f"{'文件':<62} {'大小MB':>8} {'时长s':>10}")
for name, mb, d in rows:
    ds = f"{d:.1f}" if isinstance(d, float) else str(d)
    print(f"{name:<62} {mb:>8.1f} {ds:>10}")

# 按行程分组统计
groups = {}
for name, mb, d in rows:
    key = name.rsplit("_", 2)[0]
    groups.setdefault(key, []).append(d)
print("\n按行程分组（每组的文件数 / 时长）:")
for key, ds in sorted(groups.items()):
    pretty = ", ".join(f"{x:.1f}s" if isinstance(x, float) else str(x) for x in ds)
    print(f"  {key:<45} n={len(ds)}  {pretty}")
