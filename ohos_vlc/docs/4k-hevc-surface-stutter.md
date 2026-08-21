# OHOS 4K HEVC Surface 卡顿 / 丢帧：定位与修改

状态：已在 HUAWEI Mate 70 Pro 上验证，系统图库同片源流畅，VLC 修后「完全不卡」。

测试片源：相册 `VID_20260821_150201.mp4`，HEVC 3840×2160 @ 60fps，硬解 `SetOutputSurface` 成功。

---

## 1. 现象

- 系统图库 / AVPlayer 播放同一文件流畅。
- VLC 开头明显丢帧、卡顿；后续相对好一些，但仍不稳。
- App 统计 `decoded` 在涨，`displayed` 始终为 0，`lost` 为 0。
- 用户观感是「解出来了，但上屏在跳」。

`displayed=0` 不能当成「没画出」。Surface 硬解绕过 VLC vout 统计，画面是 `OH_VideoDecoder_RenderOutputBufferAtTime` / `FreeOutputBuffer` 直接送到 XComponent 的。

---

## 2. 正确模型（图库在做什么）

OHOS 硬解 + NativeWindow 的约定（`OH_VideoDecoder_RenderOutputBufferAtTime` 头文件）：

1. 输出 buffer 在时间戳到达、且 Surface 用完之前，**不会还给解码器**。
2. buffer **按提交顺序**处理，前面一帧堵着，后面的也出不去。
3. **同一 VSYNC 上交多帧，只显示最后一帧，其余丢掉**（这就是观感上的丢帧）。
4. 时间戳离 `SystemNanoTime` 太远，Surface **忽略时间戳、尽快显示，且不再丢帧**（会快放/一窝蜂，而不是匀速 60fps）。

图库把「解码」和「上屏」拆开：硬解可以突发，上屏必须锁在 60Hz，Surface 上大约只挂 1～2 帧。VLC 原先把两件事绑在一起，解一帧就立刻上屏。

---

## 3. 原因分层

这次卡顿不是单点 bug，是几层叠在一起。前面几层修完之后，最后一层才是「完全不卡」的那一刀。

### 3.1 已修：0ms 忙轮询（开头约 5s 假死 + hilog 被打爆）

OHOS FFmpeg 适配层 `wait=false` → `wait_for(0ms)`，输入队列空时每秒打约 8 万条 `InputData failed, errcode=-5`，hilog 丢日志，解码线程空转。

- 补丁：`patches/0006-ohosavcodec-avoid-zero-timeout-busy-poll.patch`
- 输入等待改为 8ms；TIMEOUT / QUEUE_EMPTY 不再打 ERROR。
- 修后：`InputData failed` 为 0。这不是本次丢帧的主因，但会让开头更差、日志无法看。

### 3.2 已修：Surface 帧被当成 CPU 帧丢掉

VLC avcodec 在 `!linesize[0]` 时直接 `av_frame_free`。OHOS Surface 模式没有 CPU plane，这等于 `FreeOutputBuffer` **而不** `Render`。

硬解仍可能把 buffer 送上窗口（无时间戳），合成器在同一 VSYNC 上丢掉多余帧。统计上就是 `decoded=N, displayed=0`。

另外 preroll 阶段 `b_need_output_picture=false` 也会走同一条「free 不上屏」路径，开播几十毫秒内的突发 GOP 会被砸到第一个 VSYNC 上。

### 3.3 已修：排程方案踩坑（80ms 提前量）

曾经把时间戳打到「现在 + 80ms + n×16.7ms」，想把突发帧排到未来 vsync。

这违反上面第 1 条：未来时间戳会让 Surface **占住硬解输出池**。4K HEVC 输出槽很少，解码器饿死，再一窝蜂吐帧，合成器按第 3 条丢掉。日志表现：第一秒只解出约 31 帧（60fps 片源），之后 45 / 75 帧振荡。

### 3.4 根因（修完才完全不卡）：解码速率 ≠ 上屏速率，且排程代码没跑到

片源 60fps。修 3.4 之前的实测解码（每秒 `decoded` 增量）：

| 秒 | 解码 fps |
|----|----------|
| 1 | 61 |
| 2 | 45 |
| 3 | 60 |
| 4 | 75 |
| 5 | 45 |
| 6 | 76 |

上屏本应锁 60Hz。实际路径却是：

1. VLC 在 `InitVideoDecCommon` 里把 `pix_fmt` 设成 `AV_PIX_FMT_OHOSCODEC`，并 `SetOutputSurface`。
2. FFmpeg `ff_OhosAvcodec_createCodecByName()` **无条件写成 `AV_PIX_FMT_NV21`**：

```320:321:openharmony_tpc_samples/ohos_vlc/tpc_c_cplusplus/community/FFmpeg-surface-dev/FFmpeg/libavcodec/ohosvideodecoder_wrapper.cpp
    // default output format
    avctx->pix_fmt = AV_PIX_FMT_NV21;
```

3. `GetOutput` 在 Surface 模式下仍走 `WrapperSurfaceContext`：`linesize[0]=0`，`data[3]` 是 `OHOSAVCodecSurfaceCtx`。
4. VLC 只对 `pix_fmt == OHOSCODEC` 做 60fps 排程。NV21 分支调用：

   `av_ohosavcodec_render_buffer_at_time(ctx, 0)`

   时间戳 0 相对 `SystemNanoTime` 极远 → 走头文件第 4 条：忽略时间戳、尽快显示。
5. 解码 75fps 时同一 VSYNC 挤多帧 → 丢帧；45fps 时又会顿。观感就是卡。

日志旁证：排程成功时应打 `OHOS surface pace ...`，修 3.4 之前这条从未出现。`displayed` 一直为 0，因为画面不经 vout。

一句话：**硬解已经在 Surface 上出图，但 VLC 按 NV21 把每一帧立刻 Render(0)，上屏速率跟着解码突发走，没有锁 60Hz。**

---

## 4. 修改方案

原则：Surface 帧在解码线程里按 60fps **背压**，解太快就 `nanosleep`，再 `Render(now)`。Surface 上大约只挂 1 帧，不占输出池，也不会在同一 VSYNC 上堆帧。

### 4.1 识别真正的 Surface 帧

不要只看 `pix_fmt == OHOSCODEC`。Surface 帧特征：

- `frame->data[3]` 为 `OHOSAVCodecSurfaceCtx`
- `frame->buf[0]` 有效
- `linesize[0] == 0`（无 CPU plane）
- `pix_fmt` 为 `NV21` 或 `OHOSCODEC`

### 4.2 解码线程里锁 60Hz

`ohos_surface_timestamp_ns()`：

- 帧间隔取自 `fmt_in` 帧率；若算出来不在 8～42ms（例如把 60000 当成 fps），则强制 16.67ms。
- 若下一帧时刻还没到，`nanosleep` 等到该时刻（单次不超过一帧间隔）。
- 然后 `RenderOutputBufferAtTime(CLOCK_MONOTONIC now)`，并把下一允许时刻设为 `now + period`。

效果：解码突发被睡回 60fps；解码偏慢时立刻上屏、不把多帧挤成 `now`。

### 4.3 不要把 Surface 帧送进 VLC vout

识别为 Surface 帧后：Render → `av_frame_free` → `continue`。

不再 `decoder_NewPicture` / `lavc_CopyPicture`。否则 4K NV21 会进 GLES vout，和 Surface 抢、还可能堵在 picture pool 上。

Preroll（`!b_need_output_picture`）和 `!linesize[0]` 丢弃逻辑对 Surface 帧豁免，避免开播 GOP 被 `FreeOutputBuffer` 砸上屏。

### 4.4 辅助 LibVLC 参数

`vlc_napi.cpp` `LibvlcCreate`：

- `--file-caching=100`：减小相对图库的起播缓存。
- `--no-drop-late-frames`：vout 侧不再按「已经晚了」丢图（Surface 主路径已不走 vout，作双保险）。
- `--no-avcodec-hurry-up`：禁止 avcodec 因追赶丢掉参考帧。

### 4.5 明确不做的事

| 做法 | 为什么不行 |
|------|------------|
| 时间戳打到「现在 + 80ms + n×period」 | 占住硬解输出池，解码饿死再突发 |
| `Render(0)` / 解一帧送一帧 | 上屏跟着解码 fps 走，同一 VSYNC 丢帧 |
| 用 VLC clock / PTS 排程 | preroll `buffer deadlock prevented` 后 clock 经常判「已经晚了」，帧被折成 `now` |
| 只处理 `AV_PIX_FMT_OHOSCODEC` | FFmpeg 会改成 NV21，排程代码根本进不去 |

---

## 5. 改动文件

| 文件 | 作用 |
|------|------|
| `thirdparty/vlc/.../modules/codec/avcodec/video.c` | Surface 识别、60fps 背压、Render 后不进 vout |
| `vlc-harmony/ohos_vlc/patches/0007-ohoscodec-attach-surface-context.patch` | 上述 video.c 的可复现补丁 |
| `vlc-harmony/entry/src/main/cpp/vlc_napi.cpp` | file-caching / no-drop-late / no-hurry-up |
| `patches/0006-ohosavcodec-avoid-zero-timeout-busy-poll.patch` | 禁止 0ms 忙轮询（前置） |

核心判断与排程在 `video.c`：`ohos_is_surface_frame()`、`ohos_surface_timestamp_ns()`；DecodeBlock 里 Surface 帧走 Render + continue。

---

## 6. 如何验证

1. 增量编插件并装进 HAP：

```bash
cd openharmony_tpc_samples/ohos_vlc/tpc_c_cplusplus/thirdparty/vlc/vlc-ohos-3.0.21/arm64-v8a-build/modules
make -j8 libavcodec_plugin.la
# 拷到 lycium / library / vlc-harmony/entry 三处 plugins/codec/
cd vlc-harmony && devecocli run --device <serial> --product default --build-mode debug --uninstall
```

2. 播同一条 4K 60fps HEVC，hilog 应出现：

```text
OHOS surface pace 16666666 ns (rate ...)
OHOS present 60 fps (target 60, period 16666666 ns)
```

`present N fps` 应稳定在约 60，而不是 45/75 振荡。

3. `displayed` 仍可能为 0，这是预期（不经 vout）。看画面和 `OHOS present` 即可。

---

## 7. 未做的收尾（不影响当前流畅）

- FFmpeg `createCodecByName` 仍无条件写 `pix_fmt = NV21`。VLC 侧已按 Surface 帧特征识别，可不改 libavcodec。若要语义干净，可在已有 native window 时保留 `AV_PIX_FMT_OHOSCODEC`（需重编 `libavcodec.so.60`）。
- `OHOS present` 目前用 `msg_Err` 打到 hilog，便于对照图库。确认稳定后可改成 `msg_Dbg` 或加开关。
- 音画同步仍是「视频按单调时钟 60Hz，音频走 VLC clock」。本次目标是对齐图库流畅度；若以后出现口型不准，再把第一帧锚到音频 clock。
