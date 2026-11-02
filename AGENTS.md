# 梯间守望工程Agent入口

先读根README与tools/workspace_layout.json，再按任务读对应指南。用户当前明确指令优先。不要按历史计划重复开发已有能力。

## CodeGraph

仓库根存在.codegraph/时，理解或定位代码先用codegraph_explore（如可用）或codegraph explore，再用rg。不存在时跳过，不自动索引。不全量扫描生成物。

## 当前事实来源

- 用户2026-10-30确认作品名为“梯间守望”；旧文档的“梯安·灵眸”保留历史语境，不继续用于新交付物。不因名称变化重命名TD文件或HDL模块。
- 活动仓库lab_ex4_tf；正式工程src/td_project/lab_ex5_i2s_v1.0.al，EG4S20BG256，顶层top，源清单以.al为准。
- 顶层src/user_source/hdl_source/top_tf_hdmi_audio.v；约束src/user_source/constraints_source/，厂商IP与加密源原址保留。
- 当前结构doc/工程框架.md；操作doc/当前使用指南.md；录像doc/演示视频/20261030/梯间守望_拍摄SOP.html。
- 最新核对隔离候选build_out/display_update_candidate_20261030_i/best_result，BIT SHA256 def8f6753bbb2055079ed52deec28089943f70463435fbe7d7c49709999fb590。140个user_source文件与90条源引用已核对，不据此认定板上烧录相同。
- 显示更新候选时序SWNS +1.717 ns、HWNS +0.044 ns、TNS 0；hardware_tested=false。资源采用.area/route.qor：18310 LUT、9329/9800 Slice。41项RTL回归与4096字库初始化映射审计通过；记录doc/maintenance/20261030_display_update/README.md。候选21为本次显示修改之前的历史版本。
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
