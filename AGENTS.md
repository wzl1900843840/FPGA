# FPGA 工程 Agent 工作入口

先读根 README 与 tools/workspace_layout.json；用户当前明确指令优先。按任务定位，不全量扫描生成物。

## CodeGraph

仓库根存在 .codegraph/ 时，理解或定位代码先用 codegraph_explore（如可用）或 codegraph explore，再用 rg。不存在时跳过，不自动索引。

## 单一事实来源

- 正式工程：src/td_project/lab_ex5_i2s_v1.0.al，器件 EG4S20BG256，顶层 top。工程名虽是 lab_ex5，活动仓库是 lab_ex4_tf。
- 顶层：src/user_source/hdl_source/top_tf_hdmi_audio.v；有效源清单以 .al 为准，不按文件名猜参与综合情况。
- 时钟/引脚：src/user_source/constraints_source/；不得放宽约束、伪造 false path 或用旧 BIT 代替新编译。
- UI 坐标：promax_text_overlay.v 的 ALERT_TEXT_X/ALERT_STATUS_Y/ALERT_HINT_Y/ALERT_ID_Y；基于 640×480 输出坐标。
- 当前素材目录见 tools/workspace_layout.json，工程内 media 的旧包是参考素材。
- 上位机：start_console.cmd → tools/launch_console.py → tools/stairwell_watch.py / tools/host_app/。已有未提交代码必须保护，不能当冗余删除或擅自一并提交。

## 按任务定位

|任务|入口|
|---|---|
|按键/菜单/拨码|demo_ui_controller.v、demo_switch_filter.v、promax_text_overlay.v|
|TF/FAT32/BMP|sd_media_service.v、fat32_*、bmp24_decoder.v、media_ingest_*|
|SDRAM/CDC|media_sdram_arbiter.v、media_frame_reader.v、media_sdram_write_cdc.v、frame_config_cdc.v|
|应急/串口|elevator_demo_controller.v、uart_status_reporter.v、subtitle_uart_controller.v|
|资源/时序证据|doc/优化验证/20261029/；报告与源散列必须匹配|
|现行任务/需求|docs/README.md 与 docs/工作区/；未测硬件项目不能擅自归档|

## 修改与验证

1. 先 git status --short；保护用户已有差异，禁止 git add -A、git reset --hard 和批量替换活动工程。
2. 用 rg 定位后小范围读取。build_out/、archive/、tests/results/ 不作活动代码来源；确需历史复现时读指定文件。
3. 完整构建验收：D:/Anaconda/python.exe tools/build_gui.py --out build_out/<新目录>，或双击 build_verified.cmd。它不是 TD 原生按钮钩子。不要重用旧目录覆盖历史结果。
4. 结构检查：D:/Anaconda/python.exe tools/workspace_doctor.py；RTL 回归：D:/Anaconda/python.exe tools/run_tests.py。开发指南列其他入口。
5. 若只整理目录/文档且源文件散列不变，验证引用与哈希即可，无需启动综合覆盖产物。
6. 分别报告源码修改、仿真、物理实现、上板功能与持续运行证据。用户反馈上板正常，不代表所有边界条件已验收。

## 清理边界

src/、tools/、tests/*.v、约束/IP、当前候选与实板证据受保护；先外部备份、逐项核验再清理。seg7_block_swap/user_source 和 thumbnail_center/user_source 是指向活动源码的目录联接，禁止跟随它们递归删除。历史失败日志也是证据；保留摘要或备份索引。

本轮恢复位置与删除清单见 [目录整理记录](doc/maintenance/20261029_workspace/README.md)。
