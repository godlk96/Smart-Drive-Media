"""导出 media_resource 样本的轨道结构（视频/音频编码、分辨率、声道数）。

为什么需要：同一 60 秒，front 文件 166~173MB，其它机位只有 ~26MB（差 6.5 倍）。
必须看清 front 到底多了什么（更高分辨率？更高码率？多轨？），
因为这决定了"三路并发解码"的负载，以及音频断断续续的成因。
"""

import os
import struct
import sys

CONTAINER = {b"moov", b"trak", b"mdia", b"minf", b"stbl", b"edts", b"udta", b"mvex"}


def boxes(f, end):
    while f.tell() < end:
        start = f.tell()
        header = f.read(8)
        if len(header) < 8:
            return
        size, btype = struct.unpack(">I4s", header)
        hsize = 8
        if size == 1:
            size = struct.unpack(">Q", f.read(8))[0]
            hsize = 16
        elif size == 0:
            size = end - start
        yield btype, start, size, hsize
        if size < hsize:
            return
        f.seek(start + size)


def find(f, end, path):
    """按路径（box 类型列表）查找第一个匹配的 box。"""
    if not path:
        return None
    for btype, start, size, hsize in boxes(f, end):
        if btype == path[0]:
            if len(path) == 1:
                return (start, size, hsize)
            f.seek(start + hsize)
            found = find(f, start + size, path[1:])
            if found:
                return found
            f.seek(start + size)
        else:
            f.seek(start + size)
    return None


def read_stsd_entries(f, moov_end, trak_start, trak_size, trak_hsize):
    """返回该 trak 的 handler 类型与 sample entry 摘要。"""
    f.seek(trak_start + trak_hsize)
    hdlr = find(f, trak_start + trak_size, [b"mdia", b"hdlr"])
    handler = "?"
    if hdlr:
        f.seek(hdlr[0] + hdlr[2] + 8)
        handler = f.read(4).decode("latin1")

    f.seek(trak_start + trak_hsize)
    stsd = find(f, trak_start + trak_size, [b"mdia", b"minf", b"stbl", b"stsd"])
    info = {"handler": handler}
    if stsd:
        f.seek(stsd[0] + stsd[2] + 4)  # version/flags + entry_count
        count = struct.unpack(">I", f.read(4))[0]
        entries = []
        for _ in range(min(count, 4)):
            hdr = f.read(8)
            if len(hdr) < 8:
                break
            esize, etype = struct.unpack(">I4s", hdr)
            etype_s = etype.decode("latin1")
            body = f.read(max(0, esize - 8))
            entry = {"type": etype_s}
            if etype_s in ("avc1", "hvc1", "hev1", "mp4v", "av01"):
                if len(body) >= 78:
                    w, h = struct.unpack(">HH", body[24:28])
                    entry["size"] = f"{w}x{h}"
            elif etype_s == "mp4a":
                if len(body) >= 28:
                    ch = struct.unpack(">H", body[16:18])[0]
                    ss = struct.unpack(">H", body[18:20])[0]
                    rate = struct.unpack(">I", body[24:28])[0] >> 16
                    entry["channels"] = ch
                    entry["sampleSize"] = ss
                    entry["rate"] = rate
            entries.append(entry)
        info["entries"] = entries
    return info


def inspect(path):
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        moov = find(f, size, [b"moov"])
        if not moov:
            return None
        f.seek(moov[0] + moov[2])
        traks = []
        for btype, start, bsize, hsize in boxes(f, moov[0] + moov[1]):
            if btype == b"trak":
                traks.append((start, bsize, hsize))
            f.seek(start + bsize)
        out = []
        for start, bsize, hsize in traks:
            out.append(read_stsd_entries(f, moov[0] + moov[1], start, bsize, hsize))
        return out


root = sys.argv[1] if len(sys.argv) > 1 else "media_resource"
only = sys.argv[2] if len(sys.argv) > 2 else None
for dirpath, _dirs, files in os.walk(root):
    for name in sorted(files):
        if not name.lower().endswith(".mp4"):
            continue
        if only and only not in name:
            continue
        p = os.path.join(dirpath, name)
        mb = os.path.getsize(p) / (1024 * 1024)
        traks = inspect(p)
        bits = []
        if traks:
            for t in traks:
                for e in t.get("entries", []):
                    if "size" in e:
                        bits.append(f"V:{e['type']} {e['size']}")
                    elif "channels" in e:
                        bits.append(
                            f"A:{e['type']} {e['channels']}ch {e['rate']}Hz ss={e['sampleSize']}"
                        )
                    else:
                        bits.append(f"{t['handler']}:{e['type']}")
        print(f"{name:<60} {mb:>7.1f}MB  tracks={len(traks) if traks else 0}  " + " | ".join(bits))
