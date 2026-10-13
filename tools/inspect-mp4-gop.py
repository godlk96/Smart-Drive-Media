"""检查样本是否为全 I 帧（stss 缺失 = 所有样本都是同步样本），以及音频码率。

为什么重要：
  front 文件 60s/166MB ≈ 22Mbps、约 1200 帧 → 每帧 ~1.1Mbit，
  远高于普通 P 帧（~20-40kbit），强烈怀疑是 all-intra（每帧都是关键帧）。
  全 I 帧意味着解码负载极高：三路并发（其中一路 22Mbps 全 I 帧）时，
  音频管线可能被拖垮 → "声音断断续续"；主轨 timeUpdate 节奏被打乱 → "进度条卡顿"。
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


def find_deep(f, start, end, path):
    if not path:
        return None
    for btype, st, size, hsize in boxes(f, end):
        if btype == path[0]:
            if len(path) == 1:
                return (st, size, hsize)
            f.seek(st + hsize)
            got = find_deep(f, st + hsize, st + size, path[1:])
            if got:
                return got
            f.seek(st + size)
        else:
            f.seek(st + size)
    return None


def trak_summary(f, moov_start, moov_size, moov_hsize):
    f.seek(moov_start + moov_hsize)
    results = []
    for btype, start, size, hsize in boxes(f, moov_start + moov_size):
        if btype != "trak":
            f.seek(start + size)
            continue
        f.seek(start + hsize)
        hdlr = find_deep(f, start + hsize, start + size, ["mdia", "hdlr"])
        handler = "?"
        if hdlr:
            f.seek(hdlr[0] + hdlr[2] + 8)
            handler = f.read(4).decode("latin1")
        f.seek(start + hsize)
        stsz = find_deep(f, start + hsize, start + size, ["mdia", "minf", "stbl", "stsz"])
        f.seek(start + hsize)
        stss = find_deep(f, start + hsize, start + size, ["mdia", "minf", "stbl", "stss"])
        f.seek(start + hsize)
        stts = find_deep(f, start + hsize, start + size, ["mdia", "minf", "stbl", "stts"])
        f.seek(start + hsize)
        mdhd = find_deep(f, start + hsize, start + size, ["mdia", "mdhd"])

        ts = None
        if mdhd:
            f.seek(mdhd[0] + mdhd[2])
            ver = struct.unpack(">B", f.read(1))[0]
            f.read(3)
            if ver == 1:
                f.read(16)
                ts = struct.unpack(">I", f.read(4))[0]
                dur = struct.unpack(">Q", f.read(8))[0]
            else:
                f.read(8)
                ts = struct.unpack(">I", f.read(4))[0]
                dur = struct.unpack(">I", f.read(4))[0]
            duration_s = dur / ts if ts else 0
        else:
            duration_s = 0

        sample_count = None
        total_bytes = None
        if stsz:
            f.seek(stsz[0] + stsz[2] + 4)
            sample_size = struct.unpack(">I", f.read(4))[0]
            sample_count = struct.unpack(">I", f.read(4))[0]
            if sample_size == 0:
                total_bytes = sum(struct.unpack(">I", f.read(4))[0] for _ in range(sample_count))
            else:
                total_bytes = sample_size * sample_count

        keyframes = None
        if stss:
            f.seek(stss[0] + stss[2] + 4)
            keyframes = struct.unpack(">I", f.read(4))[0]

        results.append({
            "handler": handler,
            "duration_s": duration_s,
            "samples": sample_count,
            "bytes": total_bytes,
            "keyframes": keyframes,
        })
    return results


for path in sys.argv[1:]:
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        top = list(boxes(f, size))
        moov = next(((st, s, h) for b, st, s, h in top if b == "moov"), None)
        print(f"\n=== {os.path.basename(path)} ({size/1024/1024:.1f}MB) ===")
        if not moov:
            print("  无 moov")
            continue
        for t in trak_summary(f, moov[0], moov[1], moov[2]):
            if t["handler"] == "vide" and t["samples"]:
                fps = t["samples"] / t["duration_s"] if t["duration_s"] else 0
                kf = t["keyframes"]
                kf_txt = "无 stss → 全部样本都是关键帧（全 I 帧）" if kf is None else f"{kf} 个关键帧"
                avg_frame = (t["bytes"] * 8 / t["samples"] / 1000) if t["bytes"] and t["samples"] else 0
                print(f"  视频: {t['samples']} 帧 / {t['duration_s']:.1f}s ≈ {fps:.1f}fps, {kf_txt}")
                print(f"        平均每帧 {avg_frame:.0f} kbit → 视频码率 {(t['bytes']*8/1e6)/t['duration_s']:.1f} Mbps")
            elif t["handler"] == "soun" and t["samples"]:
                br = (t["bytes"] * 8 / t["duration_s"] / 1000) if t["bytes"] and t["duration_s"] else 0
                print(f"  音频: {t['samples']} 帧 / {t['duration_s']:.1f}s → {br:.0f} kbps")
