# 梯安·灵眸 — 安路 EG4S20 FPGA 音视频终端

纯硬件、无 OS 的 TF/FAT32 图片播放、SDRAM 缓存、HDMI 音视频、中文字幕、波形与 UART 应急交互工程。电梯是应用场景；验收按安路赛题一的基础/拓展要求组织。

## 先找到入口

|要做什么|入口|
|---|---|
|打开 FPGA 工程|[lab_ex5_i2s_v1.0.al](src/td_project/lab_ex5_i2s_v1.0.al)，顶层 top；不要打开旁边历史工程|
|完整编译与时序验收|双击 [build_verified.cmd](build_verified.cmd)，成功后使用它打印的 best_result 路径|
|打开上位机|双击 [start_console.cmd](start_console.cmd)；支持模拟设备与真实串口|
|操作按键/拨码、准备 TF 卡|[当前使用指南](doc/当前使用指南.md)|
|改代码、跑回归、定位模块|[开发指南](doc/开发指南.md) / [工具索引](tools/README.md)|
|Agent 接手|[AGENTS.md](AGENTS.md) / [机器可读入口](tools/workspace_layout.json)|

## 当前状态与证据边界

- 最新源码包括中文参数菜单、资源优化及告警文字移入新 PIC5 下方留白（提交 79930d3）；本轮整理没有改 RTL、约束、IP、已有固件或上位机逻辑。
- OSD 修改后 37 项模块回归通过，包含 WAIT/ACKED/TIMEOUT/解除、两种输入倍率及 BRAM 字库流水线检查；记录保留在 build_out/alert_layout_20261029/regression。
- 最近一次已验收的完整隔离构建是 build_out/gui_verified_20261029/best_result：SWNS +1.185 ns、HWNS +0.021 ns、TNS 为 0。它早于告警文字位置修改，不能代表最新源码已重新物理实现。证据见 [GUI 构建验收记录](doc/优化验证/20261029/GUI重编译验收修复/处理说明.md)。
- 用户反馈已有上板版本功能正常；TD 原生 GUI 的一次重编译报告 HWNS −0.061 ns。原生按钮尚未自动接入仓库的额外 hold 修复流程，不能混用两套结论。
- 当前素材为用户指定的五张新图，均已加安路图标：[素材入口与格式](media/README.md)。PIC4 为 1280×960，其余 640×480，输出画布为 640×480。
- 本轮不新增上板或性能结论。连续运行、热拔插等实板验收仍以 [验收矩阵](docs/工作区/任务/进行中/安路赛题一验收矩阵与演示操作_20261029.md) 的实际记录为准。

## 目录怎么用

|目录|职责|
|---|---|
|src/|正式 RTL、厂商 IP、约束和 TD 工程；保持原路径|
|tools/、tests/|开发工具、测试源与模型；原有入口不搬动|
|doc/|技术说明、操作指南与验证证据，见 [文档索引](doc/README.md)|
|docs/|需求、实现前设计与任务，见 [任务索引](docs/README.md)|
|media/|参考素材及当前素材索引|
|build_out/、tests/results/|本地生成物；当前候选与实板快照须先归档再清理|
|archive/、release/|历史资料与旧流程输出，不能当最新固件|
|config/、logs/|上位机本地偏好与运行日志；不清空用户配置|

## 整理与恢复

本次清理明细、完整备份及校验结果见 [目录整理记录](doc/maintenance/20261029_workspace/README.md)。README 原文与此前未提交改动已原样保存在该目录和外部 ZIP 中。

只读检查（不编译、不下载、不访问串口）：

    D:/Anaconda/python.exe tools/workspace_doctor.py
