# 当前与历史素材

## 当前使用的一组

用户指定目录：C:/Users/wzl123/.config/micu-image/output/tijian_sunburst_20261029_141512/bmp_fpga

PIC1～PIC5 已添加原工程透明安路图标。PIC1、2、3、5 为 640×480；PIC4 为 1280×960。图标在 640 输出上的位置统一为 (16,16)、63×41；PIC4 按两倍源坐标叠加后再缩小。五张均为 24 位无压缩、bottom-up、54 字节像素偏移的 BMP。

将这五个 BMP 文件拷到 FAT32 卡根目录即可更换图片，图标已经写入图片像素。告警字幕坐标是 FPGA RTL 参数，图片替换不能替代重新编译该逻辑。

处理凭据与预览见 [20261029 素材校验](../doc/media_validation/20261029_anlogic_logo/README.md)。源目录上一级保留加图标前 ZIP，准确路径见该目录的 validation.json。

## 工程内的其他包

elevator_photo_pack/、photo_pack_anlogic/ 和根 PIC*.BMP 是历史参考或测试 fixture，保留给生成器和原有测试使用，不能当成用户目前 TF 卡的图。不要为了统一名称删除这些依赖。

需要重做图标时运行 tools/apply_anlogic_logo.py <素材目录>，不要对已经加过图标的图反复叠加；优先从原 ZIP 恢复干净素材。
