# 2026-10-25 最终交付候选包

产品定位：基于安路 EG4S20 的照片优先音视频信息发布与交互终端。

## 使用

1. 将 `lab_ex5_i2s_v1.0_final.bit` 下载到 HX4S20C/EG4S20BG256。
2. 将 `PIC1.BMP`～`PIC4.BMP` 复制到 FAT32 TF 卡根目录。
3. 连接 HDMI 显示设备；首次上电或 K1 复位保持静音，短按 K4 后升至 64 档。
4. 按键、拨码和 UART 用法以工程根目录 `代码说明.md` 为准。

## 证据

`validation.json`、`final_timing.rpt`、`lab_ex5_i2s_v1.0_phy.area` 与 BIT 来自同一隔离构建。`manifest.json` 记录包内文件大小和 SHA-256。

当前包的 `hardware_tested` 为 `false`，烧录后必须完成冷启动、切图、字幕、异常恢复、连续运行和功耗实测，再把实板信息补入最终发布记录。

照片来源、作者、许可和 Logo 说明位于工程根目录 `media/photo_pack_anlogic/README.md`；不要把照片许可理解为安路 Logo 的商标授权。
