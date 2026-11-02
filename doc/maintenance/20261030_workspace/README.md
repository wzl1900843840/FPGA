# 梯间守望工程整理与恢复记录

日期：2026-10-30。用户授权在制作最终视频拍摄SOP的同时，整理当前工程框架，更新Agent入口和README，删除冗余及旧文件。范围为lab_ex4_tf，不包含父目录参考工程、其他工程和用户桌面原PPT。

## 结果

- 作品新交付名称统一为“梯间守望”。新增[工程框架](../../工程框架.md)、[拍摄SOP](../../演示视频/20261030/梯间守望_拍摄SOP.html)和[现场速查单](../../演示视频/20261030/梯间守望_现场速查单.txt)。
- 更新根README、AGENTS.md、机器入口、当前指南及文档/构建/测试/工具/归档索引。TD工程名、源码路径和启动方式保持原址。
- 移除5,397个文件，合计797,597,793字节，约760.65 MiB。删除清单见[cleanup_plan.json](cleanup_plan.json)，实际执行见[cleanup_result.json](cleanup_result.json)。这是工作目录减少量；另存了完整备份，不等同磁盘净释放量。
- 删除内容为：被候选21取代的20261030试验候选1～20、根build_out下6个可再生VVP/PPM、旧参考演示视频、archive/releases中5份历史BIT、根目录旧“设计参考例程文档.md”。历史报告、manifest和日志原文保留。
- 保留src、tools、tests、config、logs、media、候选21、final_repair_baseline_20261030、gui_blackbox_fix_20261030、最近回归、历史实板证据和两处源码目录联接。
- build_out/promax_audio_waveform_old.v虽名为old，仍被波形等价测试使用，原样保留；pre_blend_refactor.v参考也保留。

## 完整恢复点

备份目录：D:/FPGA/anlu/example_code111/backups/workspace_cleanup_20261030/。

|文件|用途|
|---|---|
|project_before.zip|整理前工作树完整文件快照，排除.git本体与联接重复遍历|
|backup_manifest.json|每个ZIP条目的原路径、大小和SHA256；联接单列登记|
|backup_verified.json|逐成员验证结果、ZIP散列和Git bundle验证状态|
|git_before.bundle|完整Git引用与历史|
|git_bundle_verify.txt|Git bundle验证输出|
|git_status_before.txt / git_diff_before.patch|整理前状态与已有未提交差异|

ZIP共有10,681个成员，均逐项SHA256核验；原文件总量1,879,089,631字节，ZIP为1,227,259,012字节。备份没有遗漏，2个目录联接保存其目标记录，不重复打包。ZIP SHA256：

    ee826eb8739f83237e528d63010b8d5fdcacbdbd0805df66901871122d7ab418

恢复单个文件：在ZIP中找到cleanup_plan或backup_manifest记录的原相对路径，解压到独立临时目录，核对SHA256，再与现有文件比较，按需放回原位。恢复试验目录也先解压到独立位置，不整包覆盖当前源或用户后续修改。Git历史可在新目录从bundle克隆，不重置现有工作树。

上轮更老的文件仍从[20261029备份](../20261029_workspace/README.md)恢复。

## 当前构建核对

candidate_21的140个user_source文件与当前正式源一致，两个.al的90条源引用集合及重复次数相同，排列顺序不同。BIT为d329a9bcdc4149515aa835f2c3fd871a0f52231d0c96be14c7eecc693ebd8ecb，时序SWNS +0.409 ns、HWNS +0.023 ns，TNS 0；报告hardware_tested=false。

原生TD best_result的BIT是3a699337436f7a059fb0adf0b0c255333ac286d56f8b89d348b0e0f6dbd1045b，当前.ts为SWNS +0.409 ns、HWNS −0.054 ns、HTNS −0.157 ns；不能把两套输出混用。旧README仅描述20261029候选，已按实际文件更新。

candidate_21的BOARD_ACCEPTANCE手写LUT/MSlice汇总与工具原始报告不一致，本轮不改写已有证据。README和SOP采用.area的LUT 18425/19600、REG 9524/19600、BRAM27/64、DSP17/29，Slice采用route.qor的9785/9800。

## 验证

最终检查见[verification.json](verification.json)和[workspace_doctor.json](workspace_doctor.json)。检查整理前文件的完整差异分类、受保护内容散列、TD源引用、导航、Python语法、当前素材、位流和联接目标。

拍摄SOP已用无界面Edge检查1400px桌面和390px手机宽度，无页面横向溢出，素材图片正常，8个章节和19个检查框可用；预览为本目录sop_desktop.png、sop_story.png、sop_mobile.png。没有在PowerPoint中修改用户原PPT。

本轮不改RTL、约束、厂商IP、上位机业务逻辑和测试源，不执行综合、布局布线、烧录或串口命令；不新增实板或长时运行结论。现有未提交用户修改继续保留，本轮未自动提交Git。

本目录Python/CJS是本次维护的操作与验证记录，不是日常工程入口；尤其不要重跑已执行的cleanup_archived_files.py --apply。新一轮清理需新备份、新清单、新散列校验。
