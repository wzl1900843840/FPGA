# 2026-10-30 显示更新交付记录

日常图片页常显 `PICx MANUAL/AUTO READY`，后接解码器给出的源分辨率 `640X480` 或 `1280X960`；装载时显示 LOAD，故障时显示错误码。右上角显示复位后的 `MM:SS` 计时。中文参数菜单打开后仍保留这些信息，应急页优先显示告警内容。

当前素材 PIC1～3、PIC5 为 640×480，PIC4 为 1280×960。高分辨率输入经既有 2×2 均值缩小后显示，HDMI 输出仍为 640×480。标签来自各图片的缩放标志，不按 PIC 编号硬编码。

数码管周期页从 `PRd 30S` 改为 `SEC   30`：左侧三位为 SEC，最右两位为秒数。保留原页面轮换、事件停留和数字含义。

## 位流与证据

- [本次烧录 BIT](../../../build_out/display_update_candidate_20261030_i/best_result/lab_ex5_i2s_v1.0.bit)
- SHA256：`def8f6753bbb2055079ed52deec28089943f70463435fbe7d7c49709999fb590`
- [源散列与构建记录](../../../build_out/display_update_candidate_20261030_i/best_result/validation.json)：124条RTL/约束散列匹配；完整140个user_source文件逐文件匹配冻结副本，源引用90条。
- [最终时序](../../../build_out/display_update_candidate_20261030_i/best_result/final_timing.rpt)：Slow/Fast 均检查 max/min，SWNS +1.717 ns、HWNS +0.044 ns，STNS/HTNS 均为0；沿用50/40/25/125 MHz及原引脚、时序约束。
- [资源](../../../build_out/display_update_candidate_20261030_i/best_result/lab_ex5_i2s_v1.0_phy.area)：18310 LUT、9519 REG、27 ERAM9K、17 DSP；route.qor 为9329/9800 Slice（95.19%）。
- [RTL回归](../../../build_out/display_update_verification_20261030_i/regression/summary.json)：41/41通过；文字层覆盖菜单、确认、应急和两种日常源分辨率的1536000个像素，检查状态、分辨率和计时器可见。
- [照片叠加回归](../../../build_out/display_update_verification_20261030_i/photo_ui.log)：数值、转换途中改参、帧提交、错误码、图标留白、字幕透传及RGB/同步信号对齐通过。
- [字库审计](../../../build_out/display_update_candidate_20261030_i/best_result/font_init_audit.json)：8组映射BRAM的4096个字与RTL参考逐项一致，零差异。

本轮完成源码、仿真和物理实现验证，`hardware_tested=false`，尚未下载或进行实板显示验收。旧候选21和中间候选d不含最终分辨率标签，不能替代本次BIT。

## 实现与复现

英文信息采用16像素字符格，使用坐标位切片定位字符；数字转换采用两组8位字段共享BCD转换器，16拍整组完成，帧边界提交。波形及其他功能保留。

TD门级打包设置为 `gate pack_effort high`，使剩余寄存器全部配入LUT/Slice；相同RTL从默认打包的4915个MSlice降到4664个。完整隔离构建默认使用该设置及 `route effort routability`，随后执行原生hold修复、最终STA和bitgen。

复现命令（每次使用新目录）：

    D:/Anaconda/python.exe tools/build_gui.py --out build_out/<新目录>

本轮观察到已打开的原生TD会话重写 `.al` 与settings.cfg，清除了字库初始化和打包设置。再次原生编译前需重新载入修订工程并核对设置；完整隔离构建入口会显式写入设置，原生GUI结果与本次隔离交付分别核对。

## 上板快速核对

1. 使用上方BIT，关闭SW2和SW4；日常页应有PIC/模式/READY/源分辨率与右上分秒计时。
2. 用K2切到PIC4，确认标签为1280X960；切回PIC1～3，确认640X480，图片完整显示。
3. 用K3切换手动/自动，确认模式文字对应；观察计时持续更新。
4. 检查数码管周期页为SEC及两位秒数，30秒时显示SEC   30。
5. 打开参数菜单、触发再解除告警，核对菜单和应急文字可读、日常页信息恢复。
