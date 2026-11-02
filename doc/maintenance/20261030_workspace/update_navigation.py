"""Write the reviewed 2026-10-30 navigation; originals are in the verified backup."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
FILES = {
'README.md': '''# 梯间守望 — 安路 EG4S20 电梯信息与应急提示终端

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

2026-10-30核对的隔离候选为[candidate_21/best_result](build_out/final_repair_candidate_20261030_21/best_result)。其中140个user_source文件与正式源逐文件相同，TD源清单均为90条；完整核对见[本轮记录](doc/maintenance/20261030_workspace/verification.json)。

|项目|工具原始报告值|
|---|---|
|BIT SHA256|d329a9bcdc4149515aa835f2c3fd871a0f52231d0c96be14c7eecc693ebd8ecb|
|布线后时序|SWNS +0.409 ns，HWNS +0.023 ns，STNS/HTNS均为0|
|LUT / REG|18425/19600（94.01%） / 9524/19600（48.59%）|
|ERAM9K / DSP|27/64（42.19%） / 17/29（58.62%）|
|Slice（route.qor）|9785/9800（99.85%）|
|实板验收|validation.json标为hardware_tested=false，不能据此签收冷启或长时运行|

同目录BOARD_ACCEPTANCE.md手写LUT/MSlice数字与工具报告不一致，上表以.area、route.qor、final_timing.rpt为准，原证据文件保留原样。

TD原生best_result是另一份BIT（SHA256 3a699337436f7a059fb0adf0b0c255333ac286d56f8b89d348b0e0f6dbd1045b）；其当前.ts显示HWNS −0.054 ns、HTNS −0.157 ns。原生GUI与额外hold修复的隔离流程仍是两条路径，不混用结论。拍摄前登记实际烧录文件；本轮未编译、未下载，也未连接设备。

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
''',
'AGENTS.md': '''# 梯间守望工程Agent入口

先读根README与tools/workspace_layout.json，再按任务读对应指南。用户当前明确指令优先。不要按历史计划重复开发已有能力。

## CodeGraph

仓库根存在.codegraph/时，理解或定位代码先用codegraph_explore（如可用）或codegraph explore，再用rg。不存在时跳过，不自动索引。不全量扫描生成物。

## 当前事实来源

- 用户2026-10-30确认作品名为“梯间守望”；旧文档的“梯安·灵眸”保留历史语境，不继续用于新交付物。不因名称变化重命名TD文件或HDL模块。
- 活动仓库lab_ex4_tf；正式工程src/td_project/lab_ex5_i2s_v1.0.al，EG4S20BG256，顶层top，源清单以.al为准。
- 顶层src/user_source/hdl_source/top_tf_hdmi_audio.v；约束src/user_source/constraints_source/，厂商IP与加密源原址保留。
- 当前结构doc/工程框架.md；操作doc/当前使用指南.md；录像doc/演示视频/20261030/梯间守望_拍摄SOP.html。
- 最新核对隔离候选build_out/final_repair_candidate_20261030_21/best_result，BIT SHA256 d329a9bcdc4149515aa835f2c3fd871a0f52231d0c96be14c7eecc693ebd8ecb。140个user_source文件与90条源引用已核对，不据此认定板上烧录相同。
- candidate_21时序SWNS +0.409 ns、HWNS +0.023 ns、TNS 0；hardware_tested=false。BOARD_ACCEPTANCE手写资源汇总与工具报告不同，采用.area/route.qor。
- 原生src/..._Runs/best_result为不同BIT，当前.ts的HWNS −0.054 ns。不把隔离正裕量写成原生GUI按钮已修复。
- 当前素材以tools/workspace_layout.json的current_media为准；工程内media旧包是工具/测试fixture，不当成用户当前卡图。
- 上位机start_console.cmd → tools/launch_console.py → tools/stairwell_watch.py → tools/host_app/。真实串口、SIM和回放证据分开；未经要求不占用现有端口。

## 能力地图

|任务|拥有实现的入口|
|---|---|
|主链与时钟/复位|top_tf_hdmi_audio.v、media_recovery_manager.v|
|按键、拨码、参数|demo_ui_controller.v、demo_switch_filter.v、param_menu_controller.v|
|TF/FAT32/BMP与缩小|media_storage_ingest_top.v、sd_media_service.v、fat32_*、bmp24_decoder.v、media_ingest_*|
|SDRAM/CDC|media_sdram_arbiter.v、media_frame_reader.v、media_sdram_write_cdc.v、frame_config_cdc.v|
|播放、转场、缩略图|media_video_pipeline.v、media_player_control.v、video_fade_transition.v、thumbnail_*|
|中文OSD与告警布局|promax_text_overlay.v；ALERT_TEXT_X/ALERT_STATUS_Y/ALERT_HINT_Y/ALERT_ID_Y均基于640×480|
|HDMI、音频、波形|media_hdmi_audio_bridge.v、hdmi_phy_wrapper、promax_audio_waveform.v|
|应急、UART与确认|elevator_demo_controller.v、uart_status_reporter.v、subtitle_uart_controller.v、uart_secure_ingress_bram.v|
|PC状态/协议/界面|tools/host_app/core.py、protocol.py、ui.py、transport.py、journal.py|
|现行需求与待实板项|docs/README.md及docs/工作区/任务/进行中/安路赛题一验收矩阵与演示操作_20261029.md|

## 操作与表述边界

SW1字幕、SW2参数页、SW3时域波形、SW4本地告警；不用旧版SW3进入电梯模式。K2下一张，K3短按自动/手动、长按上一张，K4短按静音/恢复、长按缩略图；上下文行为以使用指南和生产逻辑为准。

PIC1～4日常、PIC5应急；PIC4输入1280×960，其他当前图640×480，输出固定640×480。48kHz合成音频与PCM时域波形不称TF音乐/FFT。楼层是演示输入；ACK仅接收确认，解除须所有有效来源清除，不宣称电梯安全控制或救援到场。

## 修改与验证

1. 先git status --short，保护已有差异。禁止git add -A、git reset --hard、批量替换活动工程，不自动提交。
2. 先定位再局部读取。build_out、archive、tests/results不作活动源；需历史证据时读具体路径。
3. 完整构建用D:/Anaconda/python.exe tools/build_gui.py --out build_out/<新目录>或build_verified.cmd，它不是原生按钮钩子。不降时钟、放宽约束、伪造false path或以旧BIT代新编译。
4. 结构检查tools/workspace_doctor.py；RTL回归tools/run_tests.py；其他按doc/开发指南.md和tests/README.md选。
5. 只改文档/导航且源散列不变时，查工程引用、散列和导航即可，不启动综合覆盖候选。不因整理顺手改实现或测试逻辑。
6. 分别报告源码、仿真、物理实现、上板功能和长时运行。代码存在不代表下载位流一致；资源、时序和录像使用同版。

## 清理与恢复

用户2026-10-30授权整理当前工程并清除冗余旧文件。清单与恢复入口doc/maintenance/20261030_workspace/README.md；完整备份在父目录backups/workspace_cleanup_20261030，逐文件核验ZIP与Git bundle已建立。

删除前核对已备份字节、当前散列、绝对路径在工作区内且不穿联接。不要重跑已完成的清理脚本。src、tools、tests、config、logs、media、候选21、final_repair_baseline_20261030、gui_blackbox_fix_20261030受保护。

build_out/seg7_block_swap/user_source与thumbnail_center/user_source指向正式源码，禁止跟随递归删除。build_out/promax_audio_waveform_old.v被波形等价测试使用，虽含old仍保留；pre_blend_refactor.v也保留作同轮参考。旧日志/摘要是证据，不按日期一律删。
''',
'build_out/README.md': '''# 本地构建与证据区

完整构建用根build_verified.cmd或tools/build_gui.py --out build_out/<新目录>。best_result/validation.json、final_timing.rpt和实际BIT散列共同识别候选，不凭final目录名认定已验收。

当前保留final_repair_candidate_20261030_21，140个user_source文件与正式源一致，90条源引用一致；SWNS +0.409 ns、HWNS +0.023 ns，hardware_tested=false。其BOARD_ACCEPTANCE手写资源数字不同于工具报告，采用.area/route.qor。原生TD输出仍为另一BIT与时序结果。

试验1～20与根目录旧VVP/PPM已按清单清理，完整副本在父目录backups/workspace_cleanup_20261030/project_before.zip。候选21、final_repair_baseline_20261030、gui_blackbox_fix_20261030、近期回归和旧依赖保留。

promax_audio_waveform_old.v包含波形等价测试需要的模块，不能按old名称直接删；pre_blend_refactor也保留。seg7_block_swap/user_source与thumbnail_center/user_source是正式源目录联接，禁止跟随递归删除。

更早gui_verified/R2E/I/阶段6等证据和工具依赖原位保留。详见[整理记录](../doc/maintenance/20261030_workspace/README.md)与[开发指南](../doc/开发指南.md)。
''',
'archive/README.md': '''# 历史资料归档

这里不是当前编译或下载入口。版本与候选看[根README](../README.md)，背景看[历史资料索引](../doc/历史资料索引.md)。

|目录|内容|
|---|---|
|releases/|历史manifest、资源/时序报告与日志；修复前旧.bit从工作区移除，可从完整备份恢复|
|reference/|原始参考DOCX；旧演示视频已移除，原片保存在完整备份中|
|maintenance/legacy_netlist/|旧netlist占位文件，保留当时内容|

旧固件和视频ZIP条目仍为原路径，原manifest散列不改写。备份D:/FPGA/anlu/example_code111/backups/workspace_cleanup_20261030/project_before.zip；先解压单个条目到独立目录并核对SHA256，不整包覆盖。详见[恢复说明](../doc/maintenance/20261030_workspace/README.md)。
''',
}

for relative, content in FILES.items():
    (ROOT / relative).write_text(content, encoding='utf-8', newline='\n')
print('Updated navigation:', ', '.join(FILES))
