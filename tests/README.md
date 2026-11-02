# 测试入口

## 日常回归

    D:/Anaconda/python.exe tools/run_tests.py

当前run_tests.py定义41项模块测试，含新增UART安全接入、仲裁公平性和波形检查；结果写tests/results。历史37项记录保留当时口径。测试源与模型原位保留，OSD/菜单还会写build_out预览，两处输出目录均须存在。

tests/tb_wave_blend_equiv.v额外实例化promax_audio_waveform_old，参考模块仍保留在build_out/promax_audio_waveform_old.v；该等价用例不在常规41项中，不仅删除参考文件而留下孤立测试。

## 按变化选择

|变化|入口|
|---|---|
|按键/菜单/应急文字|run_tests.py 中 demo_ui/demo_menu/emergency_osd/font_pipeline|
|资源优化兼容性|tools/run_resource_tests.py（Git 中保留的 I 基线）|
|实际顶层应急/恢复|tools/run_emergency_top_test.py / run_recovery_top_test.py|
|SDRAM/厂商 FIFO|tools/run_vendor_tests.py / run_vendor_chain.py，需要本地 ModelSim 与厂商库|
|新图片解码|tools/run_bmp_fullsize_test.py；先看参数和实际 fixture 来源|
|上位机核心|python -m unittest discover -s tests -p test_host_app.py|
|上位机布局|python -m unittest discover -s tests -p test_host_display.py；会创建 Tk 窗口|
|最终时序门禁|python -m unittest discover -s tests -p test_final_timing_gate.py|

tests/results/hardware_pass_20260928 是实板证据，不清除。其余仿真大 HEX、PPM、VVP、ModelSim 缓存可由原脚本再生；日志、摘要与截图保留。不能将仿真 PASS 描述为实板验收。

本轮仅目录整理且 HDL/约束/测试源不变，以 [结构检查](../tools/workspace_doctor.py) 和保护散列证明不改变功能；无需重新综合。
