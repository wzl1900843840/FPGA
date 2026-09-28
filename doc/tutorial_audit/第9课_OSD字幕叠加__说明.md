# 第8课_OSD字幕叠加（完赛新增模块）

> 本文件夹为本课新增/主讲的完赛工程模块，学员在自己工程基础上增量加入。
> 每个文件的作用如下：

- `osd_overlay_24.v` — 24位RGB OSD封装：Y坐标重建、12↔24位转换、OSD区域外透传
- `status_osd_overlay.v` — 12位OSD核心：5×7点阵font_row、帧边界锁存index/auto/error、黄/红双色
- `subtitle_frame_commit.v` — 跨时钟域字幕帧提交：toggle+2FF+frame_start锁存96位文本
- `promax_text_overlay.v` — 完整版文本叠加：滚动字幕、多组文本（扩展内容，讲义选讲）
- `timestamp_osd.v` — 时间戳OSD扩展（讲义选讲，扩展内容）
- `subtitle_uart_controller.v` — UART字幕控制器：串口下发字幕文本（讲义选讲，扩展内容）

## 复刻提示

- 这些模块依赖前序课程已加入的：单PLL（第5课）、四bank帧缓存（第7课）、HDMI音频桥（第3课）。
- 本课模块（OSD叠加）都是纯组合逻辑+寄存器，不依赖外部IP核。
- 每学完一课，先对照讲义图注和验证用例确认功能，再进入下一课。