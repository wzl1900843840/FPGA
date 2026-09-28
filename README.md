# HX4S20C 教程整合工程

完整复盘见 [问题与解决方案复盘](doc/问题与解决方案复盘.md)，包含故障现象、有效处理、证据边界和当前可用固件。

**实板阶段验证通过：官方原始读 FIFO 恢复后，用户确认二级测试图清晰，正常上电也能显示照片。** 当前保留已验证数据链路，不再追加猜测性修改。下载仍使用 `src/td_project/lab_ex5_i2s_v1.0_Runs/best_result/lab_ex5_i2s_v1.0.bit`（2026-09-28 15:52:25），SHA256 `5da0cca6640e639fede72455c69a0c8c2cd9f44c787242f77701b8563458c4a9`。同目录 validation.json 记录源码、构建及实板验证范围；四图切换、自动循环、长稳及其他外设功能尚未完成验收。[实验记录](doc/花屏单变量实板实验.md)。

按 `D:\FPGA\anlu\micu` 第一讲至第十六讲整合为一个镜像。入口为 `src/td_project/lab_ex5_i2s_v1.0.al`，顶层 `top`。沿用原工程文件名，不另建工程。

**当前默认配置（F盘实板排障后）：** 根目录PIC1.BMP～PIC4.BMP，PCM物理范围为0，播放合成音调。此前匹配demo_tf.img的固件保留在 `release_demo_pcm_previous`。

先读 [全链路使用与验收](代码说明.md)，模块、接口、时钟及教程差异见 [设计说明](设计参考例程文档.md) 和 [逐讲落实表](doc/教程落实对照.md)。

上一轮重复工程入口和刷新宏处理见 [工程入口与花屏排查](doc/工程入口与花屏排查.md)，该轮实板仍花屏，不代表当前修复范围。未重构目录或更改 PLL/管脚。刷新宏修复前固件在 `release_before_refresh_fix`；本轮之前固件在 `release_before_read_alignment`。

- `src/td_project/lab_ex5_i2s_v1.0_Runs/best_result/lab_ex5_i2s_v1.0.bit`：当前原工程默认下载文件；诊断操作见上文。
- `release/lab_ex4_tf_complete.bit`：上一轮脚本构建的历史文件。
- `media/demo_tf.img`：64 MiB FAT32整盘镜像，四张BMP和10秒PCM；当前默认固件为普通FAT32图片卡配置，使用镜像音乐前须重新配置PCM参数并编译。
- `release/manifest.json`：源码/bitstream散列、时序、工具警告。
- `tests/results/summary.json`、`tests/results/chain.log`：自检仿真结果。

**软件验证不等于实板验收。** 用户已反馈上一版本实板 OSD 和切图编号正常、图片花屏。当前原始 FIFO 版本已确认二级图案与正常照片显示，其他功能、重复冷启动和长期运行仍需验收。

旧版源码和说明保存在 `doc/original_baseline`。根目录原有DOCX和演示视频是历史资料。`doc/migration_scripts` 是迁移记录，不是构建入口，不要重复执行。
