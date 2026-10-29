# 隔离构建区

把 TD 综合、布局布线的**过程文件**全部收进 `build_out/`，让 `src/` 保持只读。RTL 仍只有一份，隔离树是派生副本，不手工编辑。

## 为什么原来的生成物会落进 src/

TD 引擎把日志、临时文件和流程产物写到**启动时的当前目录**：

| 生成物 | 原来的落点 | 写入者 |
| --- | --- | --- |
| `_Runs/syn_1`、`_Runs/phy_1` 全部中间文件 | `src/td_project/` | `tools/build_gui.py` 在 `_Runs/<stage>` 里启动引擎 |
| `td_<时间戳>.log`、`td_<时间戳>.logw`、`.lock.f` | `src/td_project/` | 引擎自身的运行日志（与启动目录绑定，改不了） |
| `gate.qor`、`place.qor`、`route.qor`、`final_timing.rpt` | `src/td_project/` | `tools/build.py` 在 `src/td_project` 里启动引擎 |
| `build_complete/` 中间库 | `src/td_project/` | `build_complete.tcl`、`place_route_complete.tcl` |

`DefaultFlow.tcl` 的每一条输出都是相对路径（`${prj_name}_gate.db`、`.bitgen_param.f`、`flow.status` 等），因此**产物落在哪里完全由启动目录决定**。把启动目录换到 `build_out/` 下的同构目录，`src/` 就不会再被写。

## 目录结构

```text
build_out/
├─ td_project/            复制自 src/td_project，剔除全部生成物
│  ├─ lab_ex5_i2s_v1.0.al           路径指向隔离树，源列表与 src 完全一致
│  └─ lab_ex5_i2s_v1.0_Runs/
│     ├─ syn_1/{settings.cfg,run.bat,lab_ex5_i2s_v1.0.prj}
│     └─ phy_1/{settings.cfg,run.bat,lab_ex5_i2s_v1.0.prj}
├─ user_source/           目录联接 → src/user_source（RTL 单份，不复制、不会漂移）
└─ best_result/           通过时序检查后发布的 .bit / STA / validation.json
```

`td_project/` 与 `user_source/` 同级，因此 `.al` 里的 `../user_source/...`、`settings.cfg` 里的 `../../../user_source/...` 在隔离树中指向同一份 RTL，路径无需改写，只有 `.al` 的绝对工程路径改为隔离树。

`_Runs/<stage>` 的 `settings.cfg` 与 `run.bat` 从 `src/` 现有运行目录复制。物理策略**不在** `settings.cfg` 里——当前已验证 bit 用的 `place effort high / place opt_timing high / route effort high` 是 GUI 里配的，只留在 `phy_1/diagnostic_build.log` 的 `set_param` 记录中；脚本从该日志回读并写入隔离树 `phy_1/settings.cfg` 的 `set phyWildParams {...}`，避免隔离构建悄悄退回默认的 medium 强度。

## 使用

```powershell
# 1) 生成或刷新隔离树（RTL、约束、.al 变更后必须重跑）
D:/Anaconda/python.exe tools/setup_isolated_build.py

# 2) 综合 + 布局布线 + 时序检查 + 发布
D:/Anaconda/python.exe tools/build_isolated.py

# 只重跑布局布线（综合结果仍与源码一致时）
D:/Anaconda/python.exe tools/build_isolated.py --physical-only

# 不跑引擎，只校验并发布已完成的隔离构建
D:/Anaconda/python.exe tools/build_isolated.py --collect

# 换输出根目录（仍限制在工程内）
D:/Anaconda/python.exe tools/setup_isolated_build.py --out build_out_2
D:/Anaconda/python.exe tools/setup_isolated_build.py --link-mode copy   # 联接不可用时改为复制 RTL
```

`setup_isolated_build.py` 每次都会重建 `td_project/`（只保留 `_Runs/<stage>` 的配置文件），并校验 `.al` 中**每一条源文件引用**都能在隔离树里解析；缺一个就报错退出，不会带着残缺的源列表去综合。`build_isolated.py` 先比对隔离 `.al` 与 `src` 的源列表，过期直接拒绝构建，避免用旧源列表产出"看起来成功"的 bit。

TD GUI 也可以直接用隔离工程：打开 `build_out/td_project/lab_ex5_i2s_v1.0.al`，它产生的运行目录与日志同样落在 `build_out/` 内。

## 产物与验收口径

构建通过后写入 `build_out/best_result/`：

| 文件 | 内容 |
| --- | --- |
| `lab_ex5_i2s_v1.0.bit` | 比特流 |
| `lab_ex5_i2s_v1.0_pr.timing`、`lab_ex5_i2s_v1.0_phy.ts` | 最终 STA 与建立/保持余量 |
| `lab_ex5_i2s_v1.0_phy.area` | 资源与 IO |
| `place.qor`、`route.qor`、`*_flow.status` | 各阶段质量与流程状态 |
| `validation.json` | 构建时间、bit SHA256、SWNS/STNS/HWNS/HTNS、全部源文件 SHA256、警告清单、`hardware_tested:false` |

判定规则与既有脚本一致：`ERROR/FATAL` 一律失败；`CRITICAL-WARNING` 除已复核项（`PHY-7002` 的 `U3/sdram` 硬宏位置合法化、`PHY-5079` 的移相时钟本地布线）外一律失败；`SWNS/STNS/HWNS/HTNS` 任一为负即失败，**不放宽时钟约束**。构建期间任一源文件散列变化即报错，保证发布物与源一致。

`validation.json` 的 `hardware_tested` 始终为 `false`：隔离构建只证明工具链与时序，不代表实板验收。

## 与既有流程的关系

| 位置 | 状态 |
| --- | --- |
| `build_out/` | **本轮新增的隔离构建区**，后续构建都用它 |
| `tools/build_gui.py` | 仍在 `src/td_project/*_Runs` 内跑 TD GUI 流程，会继续写 `src/`；保留供追溯 |
| `tools/build.py` | 旧脚本流程，写 `src/td_project/build_complete/` 与 `release/`；保留供追溯 |
| `src/td_project/*_Runs/best_result/`、`build_complete/`、`release/` | 历史产物，README 与文档仍引用，**本轮未移动、未删除** |

需要彻底清空过程文件时，删除 `build_out/` 即可重建；它不在 `src/` 内，删除不影响工程与历史产物。

## 已验证与未验证

已核对：`lab_ex5_i2s_v1.0.al` 共 84 条源文件引用（82 个 Verilog、`pin.adc`、`timing.sdc`），全部使用 `../user_source/...` 相对路径；`_Runs/syn_1` 与 `phy_1` 的 `settings.cfg`、`DefaultFlow.tcl` 的每条输出路径均为相对路径；`phy_1/diagnostic_build.log` 中确有 3 条 `set_param` 记录；`src/td_project` 下生成物清单已完整列出。

未执行：本轮没有运行 `setup_isolated_build.py`、`build_isolated.py` 或任何 TD 流程。当前会话的 shell 被 Windows 文件权限拦住（工作区写权限授予失败），无法执行命令，所以**隔离构建尚未实跑**。首次运行后请按下面三项核对：

1. `git status --short src/` 不应出现新的日志、`_Runs` 或中间文件；
2. `build_out/td_project/lab_ex5_i2s_v1.0_Runs/{syn_1,phy_1}/isolated_build.log` 与 `td_*.log` 都落在 `build_out/` 内；
3. `build_out/best_result/validation.json` 的 SWNS/HWNS 均为正，且与 `doc/build_photo_ui_20261009/` 的历史记录同量级（源文件不同会有差异，负值一律失败）。
