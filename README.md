# 梯间守望 — 安路 EG4S20 电梯信息与应急提示终端

面向电梯轿厢的信息发布与应急提示场景。FPGA独立完成TF/FAT32 BMP读取、SDRAM缓存、HDMI音视频、中文OSD、图像转场和输出PCM时域波形；串口上位机提供楼层演示输入、事件接收与人工确认。作品名称按用户2026-10-30确认为“梯间守望”，历史资料中的“梯安·灵眸”是旧称。

## 直接使用

|要做什么|入口|
|---|---|
|录制最终演示视频|[完整拍摄SOP](doc/演示视频/20261030/梯间守望_拍摄SOP.html) / [现场速查单](doc/演示视频/20261030/梯间守望_现场速查单.txt)|
|打开正式FPGA工程|[lab_ex5_i2s_v1.0.al](src/td_project/lab_ex5_i2s_v1.0.al)，EG4S20BG256，顶层top|
|打开上位机|双击[start_console.cmd](start_console.cmd)，实机录像选择真实串口|
|按键、拨码、TF卡准备|[当前使用指南](doc/当前使用指南.md)|
|理解系统与模块分工|[工程框架](doc/工程框架.md)|
|完整编译与时序验收|[build_verified.cmd](build_verified.cmd)，输出新的build_out子目录|
|开发或Agent接手|[开发指南](doc/开发指南.md) / [AGENTS.md](AGENTS.md) / [机器入口](tools/workspace_layout.json)|

## 当前功能

- PIC1～PIC4日常手动/自动播放；PIC5专用于告警。输入支持640×480与1280×960 RGB24 BMP，后者2×2平均缩小；HDMI输出固定640×480。
- SW1滚动字幕，SW2中文参数菜单，SW3音频波形，SW4本地告警。详细按键统一看使用指南，不再采用旧版“SW3进入电梯模式”的操作。
- 48kHz HDMI合成音调与应急提示；波形来自最终输出PCM，不称TF音乐或FFT频谱。
- 告警优先显示、主动事件上报、有限重发、人工ACK、解除后恢复。ACK表示接收确认，不解除告警；本地与串口来源都解除才结束应急状态。
- 当前UART控制采用会话/序号/CRC封装，RESCUE带CRC，旧裸ELEV写入已禁用；见[当前串口协议](doc/当前串口协议.md)。
- 上位机支持真实串口和离线模拟。楼层变化是演示输入；PC不参与FPGA图像渲染，也不控制电梯运动或安全回路。

## 当前构建证据

2026-10-30显示更新的隔离候选为[display_update_candidate_20261030_i/best_result](build_out/display_update_candidate_20261030_i/best_result)。140个user_source文件与正式源逐文件相同，TD源清单90条。日常页常显 PIC/模式/就绪状态、源分辨率和分秒计时，数码管周期页显示 SEC；见[本轮记录](doc/maintenance/20261030_display_update/README.md)。

|项目|工具原始报告值|
|---|---|
|BIT SHA256|def8f6753bbb2055079ed52deec28089943f70463435fbe7d7c49709999fb590|
|布线后时序|SWNS +1.717 ns，HWNS +0.044 ns，STNS/HTNS均为0|
|LUT / REG|18310/19600（93.42%） / 9519/19600（48.57%）|
|ERAM9K / DSP|27/64（42.19%） / 17/29（58.62%）|
|Slice（route.qor）|9329/9800（95.19%）|
|实板验收|validation.json标为hardware_tested=false，不能据此签收冷启或长时运行|

41项RTL回归、照片叠加回归和4096字库映射初始化审计通过。采用高强度门级打包与routability布线，时钟和约束保持50/40/25/125 MHz。旧候选21保留，不能用于展示本次新增文字。


## 工程目录

|目录|用途|
|---|---|
|src/|正式TD工程、RTL、约束和厂商IP，路径不变|
|tools/、tests/|构建、素材、上位机与测试；[工具](tools/README.md) / [测试](tests/README.md)|
|doc/|当前操作、框架、拍摄SOP和技术证据；[文档索引](doc/README.md)|
|docs/|需求、设计、任务状态；[任务索引](docs/README.md)|
|media/|当前素材位置及历史fixture；[素材说明](media/README.md)|
|build_out/|当前候选、基线、回归证据和可再生生成物|
|config/、logs/|上位机个人设置与运行日志|
|archive/、release/|历史资料与旧流程输出，不能凭final文件名选择烧录版本|

## 整理与恢复

本轮先对10,681个文件建立完整ZIP并逐项核验，另存Git bundle，再按清单移除试验候选1～20、旧演示视频、历史固件副本和可再生输出。当前候选21、修复前基线、原生GUI复现目录、源码/工具/测试、两处源码目录联接和当前素材保留。

备份位于D:/FPGA/anlu/example_code111/backups/workspace_cleanup_20261030/。清理明细与按文件恢复方法见[2026-10-30整理记录](doc/maintenance/20261030_workspace/README.md)；上轮恢复点见[2026-10-29整理记录](doc/maintenance/20261029_workspace/README.md)。用户原有未提交差异继续保留，本轮不自动提交。

只读结构检查：

    D:/Anaconda/python.exe tools/workspace_doctor.py
