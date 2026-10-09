# 安路 FPGA 照片素材包

将 PIC1.BMP～PIC4.BMP 复制到 FAT32 TF 卡根目录。保留项目原有演示素材。
每张 640×480、24 位、BI_RGB 无压缩、54 字节头、921,654 字节。无需额外上下翻转。

照片均为来源网站发布的实拍摄影，裁切缩放后加入用户提供的安路 Logo。
Logo 位于 (16,16)，63×41（限制框为 64×41），白底透明，图形和颜色来自原始 BMP。

| 文件 | 主题 | 作者 | 来源和许可 |
|---|---|---|---|
| PIC1.BMP | 日间城市建筑 | Mitul Shah | [来源](https://www.shopify.com/stock-photos/photos/downtown-city-skyline) · [CC0 1.0](https://www.shopify.com/stock-photos/licenses/creative-commons) |
| PIC2.BMP | 城市黄昏 | Mitul Shah | [来源](https://www.shopify.com/stock-photos/photos/toronto-stunning-sunset) · [CC0 1.0](https://www.shopify.com/stock-photos/licenses/creative-commons) |
| PIC3.BMP | 山地湖泊 | Samuel Mitchell | [来源](https://www.shopify.com/stock-photos/photos/mountains-and-blue-lake) · [Burst Some Rights Reserved](https://www.shopify.com/stock-photos/licenses/shopify-some-rights-reserved) |
| PIC4.BMP | 林间自然光 | Angelique Downing | [来源](https://www.shopify.com/stock-photos/photos/sunlit-forest) · [Burst Some Rights Reserved](https://www.shopify.com/stock-photos/licenses/shopify-some-rights-reserved) |

CC0 允许复制、修改和再分发。Burst 许可明确允许下载、复制、修改、分发和展示；本素材包用于免费 FPGA 演示，勿将其作为照片商品出售或汇编成竞争图库。
来源页面、作者和许可页面快照保存在 sources/。完整裁切坐标及 SHA-256 见 manifest.json。
许可仅涉及照片；安路 Logo 由用户提供，其商标权不由照片许可授予。

制作：D:/Anaconda/python.exe tools/prepare_photo_pack.py（读取已保存照片，不联网）。
validation.json 记录真实 RTL 解码、界面渲染和端到端链路验证。
ui_preview.png 为实际 RTL 渲染；音轨预览使用模拟 PCM，实板上电时为静音零轴。
