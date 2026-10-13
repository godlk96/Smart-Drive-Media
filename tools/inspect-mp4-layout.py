"""查看 MP4 顶层 box 顺序（moov 在前还是在后）+ 视频帧率/码率。

为什么重要：
  SingleTrackController.beginLoad() 在每次跨段时都执行 reset() + fdSrc + prepare()。
  若 moov 在文件尾部（非 faststart），prepare() 必须先 seek 到 166MB 文件的末尾读索引，
  这段耗时直接变成"每个切片交界处的静音时长"（用户听到的声音断续）。
"""

import os
import struct
import sys


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
        yield btype.decode("latin1"), start, size, hsize
        if size < hsize:
            return
        f.seek(start + size)


def walk(f, end, depth=0, prefix=""):
    out = []
    for btype, start, size, hsize in boxes(f, end):
        out.append((depth, btype, start, size))
        if depth < 3 and btype in ("moov", "trak", "mdia", "minf", "stbl"):
            f.seek(start + hsize)
            out.extend(walk(f, start + size, depth + 1, prefix + "/" + btype))
            f.seek(start + size)
    return out


def video_stats(f, moov_start, moov_size, moov_hsize):
    """返回 (timescale, sample_count) 用于估算帧率。"""
    f.seek(moov_start + moov_hsize)
    for btype, start, size, hsize in boxes(f, moov_start + moov_size):
        if btype != "trak":
            f.seek(start + size)
            continue
        f.seek(start + hsize)
        hdlr = None
        for b2, s2, sz2, h2 in boxes(f, start + size):
            if b2 == "mdia":
                f.seek(s2 + h2)
                for b3, s3, sz3, h3 in boxes(f, s2 + sz2):
                    if b3 == "hdlr":
                        f.seek(s3 + h3 + 8)
                        hdlr = f.read(4).decode("latin1")
                    elif b3 == "mdhd":
                        f.seek(s3 + h3)
                        ver = struct.unpack(">B", f.read(1))[0]
                        f.read(3)
                        if ver == 1:
                            f.read(16)
                            ts = struct.unpack(">I", f.read(4))[0]
                        else:
                            f.read(8)
                            ts = struct.unpack(">I", f.read(4))[0]
                        mdhd_ts = ts
                    f.seek(s3 + sz3)
            f.seek(s2 + sz2)
        f.seek(start + hsize)
        stsz_count = None
        for b2, s2, sz2, h2 in boxes(f, start + size):
            if b2 == "mdia":
                f.seek(s2 + h2)
                for b3, s3, sz3, h3 in boxes(f, s2 + sz2):
                    if b3 == "minf":
                        f.seek(s3 + h3)
                        for b4, s4, sz4, h4 in boxes(f, s3 + sz3):
                            if b4 == "stbl":
                                f.seek(s4 + h4)
                                for b5, s5, sz5, h5 in boxes(f, s4 + sz4):
                                    if b5 == "stsz":
                                        f.seek(s5 + h5 + 8)
                                        stsz_count = struct.unpack(">I", f.read(4))[0]
                                    f.seek(s5 + sz5)
                            f.seek(s4 + sz4)
                    f.seek(s3 + sz3)
            f.seek(s2 + sz2)
        if hdlr == "vide":
            return mdhd_ts, stsz_count
    return None, None


for path in sys.argv[1:]:
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        top = list(boxes(f, size))
        order = " ".join(f"{b}({s/1024/1024:.0f}MB)" for b, _st, s, _h in top)
        moov = next(((st, s, h) for b, st, s, h in top if b == "moov"), None)
        print(f"\n=== {os.path.basename(path)}  ({size/1024/1024:.1f}MB) ===")
        print(f"  顶层 box 顺序: {order}")
        if moov:
            print(f"  moov 偏移={moov[0]/1024/1024:.1f}MB / 文件 {size/1024/1024:.1f}MB  "
                  f"→ {'faststart(moov在前)' if moov[0] < size/2 else 'moov在尾部(非faststart)'}")
            ts, count = video_stats(f, moov[0], moov[1], moov[2])
            if ts and count:
                print(f"  视频: timescale={ts} 帧数={count} → 时长={count/ts:.1f}s 帧率≈{count/(count/ts):.1f}fps "
                      f"平均码率≈{(size*8/1e6)/(count/ts):.1f}Mbps")
