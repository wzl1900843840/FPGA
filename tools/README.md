# 工具索引

在工程根目录执行 Python 工具。现有路径保持不变，避免破坏脚本导入与启动器。

|类别|入口|说明|
|---|---|---|
|结构检查|workspace_doctor.py|只读检查工程引用、Python 语法、导航、素材和可选保护散列|
|机器入口|workspace_layout.json|正式工程、当前素材、历史已验收 BIT；不自动等同最新源码|
|完整构建|build_gui.py / 根 build_verified.cmd|冻结源码、综合/布局布线/hold 修复/验收，输出新的 build_out|
|分步构建|setup_isolated_build.py、build_isolated.py|明确 --out；物理阶段复用须核对源一致|
|旧兼容构建|build.py|被 build_isolated.py 导入，不能随意删除|
|模块与资源回归|run_tests.py、run_resource_tests.py|见 [测试入口](../tests/README.md)|
|集成与厂商测试|run_emergency_top_test.py、run_recovery_top_test.py、run_vendor_tests.py、run_vendor_chain.py|有模型和工具前置依赖|
|上位机|launch_console.py、stairwell_watch.py、host_app/|根 start_console.cmd 启动；--check 仅检查解释器|
|协议接收|rescue_receiver.py|兼容接收入口；实际串口操作前核对端口|
|素材|prepare_media.py、prepare_photo_pack.py、prepare_elevator_*、apply_anlogic_logo.py|旧生成器会覆盖参考包，先确认目标；图标工具会备份后写入指定目录|
|卡与时序审查|inspect_card.py、verify_card_files.py、audit_font_init.py、inspect_routed_clocks.tcl|先读参数；不能把帮助输出当验证通过|
|历史修复证据|create_repair_baseline.py、collect_repair_stage.py、archive_repair_checkpoint.py|保留复现入口，不默认重复执行|

更完整的执行与版本边界见 [开发指南](../doc/开发指南.md)。
