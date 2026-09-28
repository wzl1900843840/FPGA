# 第10课_WAV音频播放（完赛新增模块）

> 本文件夹为本课新增/主讲的完赛工程模块，学员在自己工程基础上增量加入。
> 每个文件的作用如下：

- `wav_stream_player.v` — 核心：WAV流式播放器，写侧状态机+BRAM循环缓冲+格雷码读指针+下溢静音
- `audio_source_mux.v` — 音频源多路选择：WAV流/琶音两源，按 wav_active 优先级切换（ready只路由给被选源）
- `sync_fade_gain.v` — 音画同步音量淡入淡出：按帧边界更新gain，避免爆音
- `pcm_content_mux.v` — 媒体内容音源4选1 + 音量缩放（volume乘法，可选）
- `media_hdmi_audio_bridge.v` — PCM→I2S→HDMI音频桥（第3课已讲，此处为完整音频链路参考）

## 复刻提示

- 这些模块依赖前序课程已加入的：单PLL（第5课）、四bank帧缓存（第7课）、HDMI音频桥（第3课）。
- IP核（BRAM/FIFO）若用到，需在安路TD中重新生成；本目录中的wav_stream_player用reg数组实现BRAM，不依赖外部IP。
- 每学完一课，先对照讲义图注和验证用例确认功能，再进入下一课。