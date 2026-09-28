# HX4S20C HDMI 多媒体播放工程

## 打开与下载

- **唯一日常工程入口：** [lab_ex5_i2s_v1.0.al](src/td_project/lab_ex5_i2s_v1.0.al)，顶层 `top`。沿用原工程名称。
- **当前已验证固件：** [lab_ex5_i2s_v1.0.bit](src/td_project/lab_ex5_i2s_v1.0_Runs/best_result/lab_ex5_i2s_v1.0.bit)。
- 构建时间：2026-09-28 15:52:25。SHA256：`5da0cca6640e639fede72455c69a0c8c2cd9f44c787242f77701b8563458c4a9`。
- [构建记录](src/td_project/lab_ex5_i2s_v1.0_Runs/best_result/validation.json)；[实板通过快照](tests/results/hardware_pass_20260928)。

TF 卡根目录使用 PIC1.BMP～PIC4.BMP。当前 PCM 物理范围为 0，音频为 FPGA 合成音调。`release/` 和 `archive/releases/` 中的旧固件不作为当前下载入口。

## 文档导航

| 用途 | 文档 |
| --- | --- |
| 按键、拨码、使用和验收 | [代码说明](代码说明.md) |
| 目录职责、源码分层、工具入口 | [工程结构与维护](doc/工程结构与维护.md) |
| 详细模块、接口和时钟设计 | [设计参考例程文档](设计参考例程文档.md) |
| 第一讲到第十六讲落实情况 | [教程落实对照](doc/教程落实对照.md) |
| 故障及解决过程 | [问题与解决方案复盘](doc/问题与解决方案复盘.md) |
| 花屏单变量实板证据 | [实板实验](doc/花屏单变量实板实验.md) |
| Git 基线、压缩备份与恢复 | [版本基线与备份](doc/版本基线与备份.md) |

## 当前状态

用户已确认图片显示、切图、自动轮播、HDMI 音频、亮度/对比度、字幕滚动计时和音频波形正常。UART 此前无回复的原因已定位为发送命令缺少回车；串口助手需追加 CRLF。不同分辨率缩放、重复冷启动和长时间稳定性仍需专项验收。软件仿真通过不能替代这些实板验收。

## 目录

```text
lab_ex4_tf/
├─ src/          原工程、有效源码、IP、约束及 TD 工作目录
├─ tools/        构建、仿真、TF 卡检查与素材工具
├─ tests/        测试源、模型、结果及实板通过快照
├─ media/        演示素材和磁盘镜像
├─ doc/          当前说明、教程对照和历史排查证据
├─ archive/      历史固件、原始 DOCX 和演示视频
└─ release/      旧 build.py 的输出位置，非当前默认固件
```

不重复执行 `doc/migration_scripts/` 中的迁移脚本。`doc/original_baseline/` 为原始资料备份，不是当前编译入口。
