#!/bin/bash
# 离线验证多段滤镜描述串：用一份「原生 x86_64」ffmpeg 真跑一遍同样的 filter_complex，
# 检查时长与静音是否符合预期。native 版只是把 h264_oh 换成软件编码器，滤镜图完全一致。
#
# 前置：先跑 build-native-x86-for-validation.sh 生成 $HOME/ffx86-src/ffmpeg。
# 用法：bash validate-filter-graph.sh
set -e
FF="$HOME/ffx86-src/ffmpeg"
W="$HOME/ffx86-test"

if [ ! -x "$FF" ]; then
  echo "缺少 $FF，请先跑 build-native-x86-for-validation.sh"
  exit 2
fi

rm -rf "$W"; mkdir -p "$W"; cd "$W"

echo "=== 生成三段测试源（front/back/side，60s 30fps + 正弦音）==="
for n in front back side; do
  "$FF" -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=1920x1080:rate=30:duration=60" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=60" \
    -c:v mpeg4 -q:v 5 -c:a aac -shortest "$n.mp4"
done

duration_of() {
  "$FF" -hide_banner -i "$1" 2>&1 | grep -oE 'Duration: [0-9:.]+' | head -1
}

echo
echo "=== 场景 1：单段 0-60 无倍速（对照旧行为，期望 60.00）==="
"$FF" -hide_banner -loglevel error -y \
 -filter_complex "movie='$W/front.mp4',trim=start=0:end=60,setpts=PTS-STARTPTS,fps=30/1,scale=1920:1080[s0_top];movie='$W/side.mp4',trim=start=0:end=60,setpts=PTS-STARTPTS,fps=30/1,scale=960:540[s0_bl];movie='$W/back.mp4',trim=start=0:end=60,setpts=PTS-STARTPTS,fps=30/1,scale=960:540[s0_br];[s0_bl][s0_br]hstack=inputs=2[s0_bottom];[s0_top][s0_bottom]vstack=inputs=2,format=pix_fmts=yuv420p,setsar=1[outv];amovie='$W/front.mp4',atrim=start=0:end=60,asetpts=PTS-STARTPTS,volume=1,aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[outa]" \
 -map "[outv]" -map "[outa]" -c:v mpeg4 -q:v 5 -c:a aac -t 60 out1.mp4
echo "场景1 $(duration_of out1.mp4)  期望 60.00"

echo
echo "=== 场景 2：两段 0-15(1.0x,有声) + 30-59(2.0x,静音) 期望 29.50 ==="
"$FF" -hide_banner -loglevel error -y \
 -filter_complex "movie='$W/front.mp4',trim=start=0:end=15,setpts=PTS-STARTPTS,fps=30/1,scale=1920:1080[s0_top];movie='$W/side.mp4',trim=start=0:end=15,setpts=PTS-STARTPTS,fps=30/1,scale=960:540[s0_bl];movie='$W/back.mp4',trim=start=0:end=15,setpts=PTS-STARTPTS,fps=30/1,scale=960:540[s0_br];[s0_bl][s0_br]hstack=inputs=2[s0_bottom];[s0_top][s0_bottom]vstack=inputs=2,format=pix_fmts=yuv420p,setsar=1[seg0];movie='$W/front.mp4',trim=start=30:end=59,setpts=(PTS-STARTPTS)/2,fps=30/1,scale=1920:1080[s1_top];movie='$W/side.mp4',trim=start=30:end=59,setpts=(PTS-STARTPTS)/2,fps=30/1,scale=960:540[s1_bl];movie='$W/back.mp4',trim=start=30:end=59,setpts=(PTS-STARTPTS)/2,fps=30/1,scale=960:540[s1_br];[s1_bl][s1_br]hstack=inputs=2[s1_bottom];[s1_top][s1_bottom]vstack=inputs=2,format=pix_fmts=yuv420p,setsar=1[seg1];[seg0][seg1]concat=n=2:v=1:a=0[outv];amovie='$W/front.mp4',atrim=start=0:end=15,asetpts=PTS-STARTPTS,volume=1,aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[a0];amovie='$W/front.mp4',atrim=start=30:end=59,asetpts=PTS-STARTPTS,atempo=2,volume=0,aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[a1];[a0][a1]concat=n=2:v=0:a=1[outa]" \
 -map "[outv]" -map "[outa]" -c:v mpeg4 -q:v 5 -c:a aac out2.mp4
echo "场景2 $(duration_of out2.mp4)  期望 29.50"

echo
echo "=== 场景 3：三段 0.75x / 1.0x静音 / 1.5x 期望 30.00 ==="
"$FF" -hide_banner -loglevel error -y \
 -filter_complex "movie='$W/front.mp4',trim=start=0:end=10,setpts=(PTS-STARTPTS)/0.75,fps=30/1,scale=1920:1080,format=pix_fmts=yuv420p,setsar=1[seg0];movie='$W/front.mp4',trim=start=20:end=30,setpts=PTS-STARTPTS,fps=30/1,scale=1920:1080,format=pix_fmts=yuv420p,setsar=1[seg1];movie='$W/front.mp4',trim=start=40:end=50,setpts=(PTS-STARTPTS)/1.5,fps=30/1,scale=1920:1080,format=pix_fmts=yuv420p,setsar=1[seg2];[seg0][seg1][seg2]concat=n=3:v=1:a=0[outv];amovie='$W/front.mp4',atrim=start=0:end=10,asetpts=PTS-STARTPTS,atempo=0.75,volume=1,aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[a0];amovie='$W/front.mp4',atrim=start=20:end=30,asetpts=PTS-STARTPTS,volume=0,aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[a1];amovie='$W/front.mp4',atrim=start=40:end=50,asetpts=PTS-STARTPTS,atempo=1.5,volume=1,aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[a2];[a0][a1][a2]concat=n=3:v=0:a=1[outa]" \
 -map "[outv]" -map "[outa]" -c:v mpeg4 -q:v 5 -c:a aac out3.mp4
echo "场景3 $(duration_of out3.mp4)  期望 30.00"

echo
echo "=== 场景 4：单段单路（走 outv 直出分支）期望 10.00 ==="
"$FF" -hide_banner -loglevel error -y \
 -filter_complex "movie='$W/front.mp4',trim=start=0:end=10,setpts=PTS-STARTPTS,fps=30/1,scale=1920:1080,format=pix_fmts=yuv420p,setsar=1[outv];amovie='$W/front.mp4',atrim=start=0:end=10,asetpts=PTS-STARTPTS,volume=1,aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[outa]" \
 -map "[outv]" -map "[outa]" -c:v mpeg4 -q:v 5 -c:a aac out4.mp4
echo "场景4 $(duration_of out4.mp4)  期望 10.00"

echo
echo "=== 静音校验（mean_volume 应约为 -91 dB，有声段约 -24 dB）==="
echo -n "场景2 有声段(1-6s): "; "$FF" -hide_banner -ss 1 -t 5 -i out2.mp4 -af volumedetect -f null - 2>&1 | grep -oE 'mean_volume: .*'
echo -n "场景2 静音段(20-25s): "; "$FF" -hide_banner -ss 20 -t 5 -i out2.mp4 -af volumedetect -f null - 2>&1 | grep -oE 'mean_volume: .*'
echo -n "场景3 有声段(2-7s): "; "$FF" -hide_banner -ss 2 -t 5 -i out3.mp4 -af volumedetect -f null - 2>&1 | grep -oE 'mean_volume: .*'
echo -n "场景3 静音段(16-20s): "; "$FF" -hide_banner -ss 16 -t 4 -i out3.mp4 -af volumedetect -f null - 2>&1 | grep -oE 'mean_volume: .*'
echo -n "场景3 有声段(26-29s): "; "$FF" -hide_banner -ss 26 -t 3 -i out3.mp4 -af volumedetect -f null - 2>&1 | grep -oE 'mean_volume: .*'
echo "=== 完成 ==="
