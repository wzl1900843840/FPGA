# 当前比赛素材添加安路标志

处理目录：`C:/Users/wzl123/.config/micu-image/output/tijian_sunburst_20261029_141512/bmp_fpga`。五张 PIC1.BMP 至 PIC5.BMP 已原位更新。

标志复用工程内 `media/elevator_photo_pack/anlogic_logo.png`，透明 RGBA，63×41。640×480 图片使用左上角 (16,16)；1280×960 的 PIC4 使用 (32,32) 和 126×82 标志，以适配工程的 2×2 缩小显示。

原图与原 manifest 的 ZIP 备份位于素材目录的上一级，准确路径及 SHA256 见 validation.json。每个备份成员均与替换前内容逐字节核对。所有图片保持原尺寸、原文件名、24 位无压缩、bottom-up、像素偏移 54；图标矩形之外的像素均与备份一致。

preview_anlogic.png 为当前图片的组合预览。此次只修改外部素材与其清单，没有修改 RTL、工程文件或已有 BIT；没有执行 FPGA 编译或上板验证。Git 记录处理脚本与校验凭据，外部素材保留在用户指定目录。
