# 电梯轿厢宣传与应急素材包

本目录包含四张日常宣传图和一张紧急状态图，针对当前电梯轿厢离线宣传屏演示场景制作。

| 文件 | 用途 |
|---|---|
| PIC1.BMP | 住宅电梯厅日常宣传 |
| PIC2.BMP | 办公园区电梯入口日常宣传 |
| PIC3.BMP | 社区花园与电梯厅日常宣传 |
| PIC4.BMP | 城市夜景日常宣传 |
| PIC5.BMP | 紧急状态备用页 |

## FPGA 输入格式

- PIC4.BMP 为 1280×960、其余四张为 640×480；均为 24 位 RGB、BI_RGB 无压缩 BMP
- 标准 54 字节 BMP/DIB 头，正高度表示 bottom-up
- PIC4.BMP 为 3,686,454 字节；其余每张为 921,654 字节
- 左上角叠加安路 Logo，位置 (16,16)，尺寸 63×41
- 当前 RTL 以 `ALLOW_2X_SOURCE=1` 对 PIC4 进行 2×2 平均缩小，写入 640×480 SDRAM bank
- PIC5 可作为告警页，不参与普通四格缩略图

## 生成与校验

源图由 `micu-image` 生成，保存于 `sources/`；`tools/prepare_elevator_photo_pack.py` 完成本地裁切、Logo 叠加、BMP 导出及像素回读校验。`manifest.json` 记录每张图的源图哈希、裁切坐标、BMP 格式和 SHA-256。
