# 缩略图居中与数码管顺序修正

640×480 屏幕中的四张缩略图仍为 2×2 排列，每张 160×120；整组左上角从 (0,0) 移至 (160,120)，占据 x=160..479、y=120..359。缓存生成和焦点边框使用一致的坐标，保留原有选择、缺图处理和 4:1 抽样。

两块四位数码管各自反转内部字符映射，不交换两块数码管的分组。图片页显示 PIC1～PIC4，参数页显示 PRd，音量与周期数字从左到右排列；扫描频率、极性与管脚约束不变。

## 验证

- `tools/run_tests.py`：16 项全部通过，新增全屏四焦点逐像素布局检查与数码管物理位选/段码检查。
- `tools/render_thumbnail_preview.py`：实际缓存 RTL 读取四张照片，检查 307,200 个写入像素与布局源坐标一致，导出 `centered.png`。预览为缓存照片和选中边框，不包含后续状态/音轨叠加。
- `tools/run_vendor_tests.py`：4 项全部通过，包括真实厂商 SDRAM 缓存读写。
- `tools/run_fast_boot_tests.py`：7 项全部通过；并发缓存测试检查 307,200 个缓存字、844,160 个显示像素及 1,479 次刷新，无欠载。

## 构建

独立构建目录：`build_out/thumbnail_center/`。运行命令：

```powershell
D:/Anaconda/python.exe tools/setup_isolated_build.py --out build_out/thumbnail_center
D:/Anaconda/python.exe tools/build_isolated.py --out build_out/thumbnail_center
```

本轮同时修复独立构建脚本的运行目录返回值和 TD Tcl 路径格式，增加流程完成检查。历史 `src/td_project` 构建产物保留。

最终 BIT、时序与源码散列位于独立目录的 `best_result/`；构建验证记录另存本目录。尚未烧录或实板验收。

2026-10-09 14:00:01（构建主机 UTC+08）构建完成，沿用原有管脚和时钟约束。SWNS=0.300 ns、HWNS=0.000 ns、STNS=HTNS=0，建立/保持无违例。保持余量为零，需实板确认。

BIT：`build_out/thumbnail_center/best_result/lab_ex5_i2s_v1.0.bit`。
SHA256：`620c4e988bb342260f3f4f6644616934d9744753ebf758a18f08aa634ec3781d`。
