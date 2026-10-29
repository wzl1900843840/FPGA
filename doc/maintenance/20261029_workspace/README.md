# 工程目录整理记录（2026-10-29）

本轮只整理生成物、文档与开发导航。正式工程仍是 src/td_project/lab_ex5_i2s_v1.0.al，RTL、约束、IP、TD 配置、已有固件与上位机业务代码均按整理前散列保护。

## 整理结果

- 工程内移除 11,996 个旧构建/仿真派生文件，共 2,418,523,161 字节。
- 父目录参考工程中移除一份完全相同的视频副本，261,438,503 字节；保留 archive/reference/演示视频/VID_20260428_143508.mp4。
- 合计减少工作目录冗余 2,679,961,664 字节，约 2.50 GiB。这不是磁盘净增可用空间：本轮另建了约 1.98 GiB 的完整备份。
- 两份散落 ZIP 移入父目录 backups/imported，按 SHA256 验证内容不变。
- 旧 netlist/tb_fade.log 与 tb_fade.ys 移入 archive/maintenance/legacy_netlist。日志和历史源码保留；不再作为活动构建入口。
- README、用户指南、开发指南、Agent 入口与各目录索引统一标明当前工程、素材和证据边界。新增只读 tools/workspace_doctor.py。

精确删除列表与整理前散列见 [cleanup_plan.json](cleanup_plan.json)；移动、保留目录与外部操作见 [cleanup_result.json](cleanup_result.json)。最终检查见 [verification.json](verification.json) 和 [workspace_doctor.json](workspace_doctor.json)。

## 恢复点

外部完整备份目录：

    D:/FPGA/anlu/example_code111/backups/workspace_cleanup_20261029_171953/

其中 project_before.zip 为整理前项目内容（排除 .git、本轮临时维护区及目录联接的重复遍历），15,839 个成员逐项 SHA256 与原文件一致；Git 历史另存 git_before.bundle，已通过 git bundle verify。

- ZIP 大小：2,130,267,959 字节。
- ZIP SHA256：ca83fd9046a3eb11cb7124d21d59d02e205348864fc4190beaf33246ecca6d00。
- backup_manifest.json 保存全部备份成员的大小和散列。
- git_status_before.txt 与 git_diff_before.patch 保存整理前 Git 状态及未提交差异；未跟踪文件包含在 ZIP 中。
- Git 整理分支：chore/workspace-cleanup-20261029；整理前标签：workspace-before-cleanup-20261029。

备份定位另见 [backup_location.json](backup_location.json)。恢复某个文件时先把 ZIP 中对应条目解压到独立临时目录，校验 SHA256 后比较并选择性恢复；不要整包覆盖后续开发成果。恢复 Git 历史可在新目录 git clone git_before.bundle，不要重置当前工作树。

## 原文与用户工作

README 在整理前已经有用户未提交差异。本轮先完整保存该版本再重写导航：[原 README](before_README.md)。另外保留 [旧代码说明](before_代码说明.md)、[旧结构说明](before_doc__工程结构与维护.md)、[旧隔离构建说明](before_doc__隔离构建区.md) 和 [旧归档说明](before_archive__README.md)。

既有未提交上位机代码、config、测试、审查资料及 TD 原生运行差异保留原位，不混入本轮提交。父目录新增 README 与 ZIP 归位不属于内层 Git 仓库，操作记录在上述清单中。

## 为什么保留这些生成物

build_out 下保留 alert_layout_20261029、gui_verified_20261029、gui_20261029_145246、fullchain_I_20261029、resource_R2E_20261029、repair_stage6_final_20261028、rescue_cdc_20261028、maintenance_logs、seg7_block_swap、thumbnail_center 与本轮维护区。

其中包括最近候选、已验证基线、未完成构建的证据，以及旧工具的实际依赖。seg7_block_swap/user_source 和 thumbnail_center/user_source 是指向正式 src/user_source 的目录联接，不能跟随它们递归清理。tests/results/hardware_pass_20260928、其他回归摘要/日志/截图继续保留。

当前素材位于用户指定外部目录，本轮不移动、不修改。原参考工程 lab_ex5_i2s、原始比赛资料及独立 HTML 继续保留；不把“不是活动代码”等同于“无用”。

## 验证口径

以工程引用、受保护文件 SHA256、全部整理前文件差异核对、导航链接、Python 语法及必要工具入口检查验收。没有运行综合、布局布线、下载或串口操作；本次结构验收不能替代最新 RTL 的时序与上板验收。最近隔离构建与最新 OSD 源码之间的版本差异已在根 README 中明确。

已通过：89 条 TD 工程引用、1,666 个保护文件、64 个 Python 文件语法、全部 15,839 条整理前文件差异分类核对、5 张外部素材散列、2 个目录联接、3 项时序门禁软件测试及 41 项上位机核心测试。软件测试生成的三份临时日志另存本轮维护区，原日志从已验证 ZIP 恢复，避免改变原有记录。检查脚本副本见 scripts/；它们是本轮审计证据，不是常规清理入口。

后续使用：根 [README](../../../README.md)、[当前使用指南](../../当前使用指南.md)、[开发指南](../../开发指南.md)、[Agent 入口](../../../AGENTS.md)。
