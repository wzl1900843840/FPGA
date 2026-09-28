# 第7课 四bank帧缓存架构

---

## 本课对应赛题说明

**本节课在整个赛题中的位置：扩展要求的显示架构升级部分**

| 赛题要求 | 类型 | 本节课覆盖程度 |
|---|---|---|
| 基础要求①：TF卡BMP读取+SDRAM帧缓存+HDMI显示 | 基础 | ✅ 已实现，本节课升级其帧缓存架构 |
| 基础要求②：按键手动切换+自动轮播模式 | 基础 | ✅ 第2课已优化，本节课不改动 |
| 基础要求③：HDMI音频输出+音视频同步 | 基础 | ✅ 官方例程已实现，本节课不改动 |
| 基础要求④：Flash固化+上电自启动+系统稳定 | 基础 | ✅ 第5课已完成，本节课不改动 |
| 扩展要求：存储架构升级+显示架构升级+流畅切换 | 扩展 | ✅ 本节课核心内容：四bank帧缓存+loader/reader分离，解决双缓冲切换撕裂、读写冲突、无错误处理等问题 |

**本节课的定位：**
- 这是架构升级线的第二课，继第6课FAT32文件系统之后，继续升级显示架构
- 核心改动：把官方例程"双缓冲+frame_read_write桥接"的原始帧缓存架构，升级为"四bank帧缓存+loader/reader分离"的正规架构
- 官方例程功能上能跑，但帧缓存架构非常原始——只有2个buffer来回切换、读写挤在一个桥接模块里、没有FIFO缓存、没有错误处理、切换时容易撕裂
- 本节课做1个核心架构升级：用四bank帧缓存替换双缓冲，用loader/reader分离替换frame_read_write桥接，包含2个新模块（media_frame_loader+media_frame_reader）和1个控制模块替换
- 学完这节课，你的工程能支持四bank独立存储、loader/reader完全分离、FIFO缓存+burst读写、双时钟域异步FIFO、underflow检测、完善错误码，显示架构从"原始"升级到"正规"

**学完本节课你将掌握：**
1. 官方例程双缓冲帧缓存架构的原理和6个严重局限
2. 四bank帧缓存的核心概念：bank划分、地址映射、独立存储
3. loader/reader分离的设计思想和优势
4. FIFO缓存+burst读写的原理和实现
5. 双时钟域异步FIFO的跨时钟域处理
6. 从官方"双缓冲+桥接"到"四bank+loader/reader分离"的过渡思路
7. 完赛工程media_frame_loader和media_frame_reader两个模块的工作原理
8. 完整的修改代码和验证方法
9. 从官方到完赛的帧缓存架构演进思路

---

## 一、官方例程的帧缓存架构与局限

### 1.1 官方帧缓存架构深度拆解

官方例程的帧缓存由三个模块协作完成：`sd_card_bmp`（双缓冲管理+BMP解析）、`frame_read_write`（读写桥接+跨时钟域）、`sdram`（SDRAM控制器，加密IP）。

**核心架构：双缓冲+frame_read_write桥接**

[代码/图示块另行核对]

数据流：

写路径：TF卡→sd_card_bmp（BMP解析）→frame_read_write（写桥接）→sdram

读路径：video_timing_data（产生时序+读请求）→frame_read_write（读桥接）→sdram→frame_read_write→video_delay（延迟对齐）→HDMI显示



**双缓冲机制：**

- 只有2个buffer：`BUF0_ADDR = 0`，`BUF1_ADDR = 307200`（640×480=307200像素）
- `write_buf_idx`：当前正在写入的buffer（0或1）
- `disp_buf_idx`：当前正在显示的buffer（0或1）
- `pending_buf_idx`：正在写入的目标buffer（写完后切换为disp_buf_idx）
- 写的时候必须写到"非当前显示"的另一块buffer（next_buf_lut函数）
- 写完成后通过`frame_write_toggle_mem`同步到sd_card_clk域，然后`disp_buf_idx <= pending_buf_idx`切换显示

frame_read_write会输出frame_write_finish脉冲，顶层把这个脉冲转成frame_write_toggle_mem（toggle信号，跨时钟域用），同步到sd_card_clk域后，sd_card_bmp检测到write_finish_pulse，就把disp_buf_idx <= pending_buf_idx，切换显示buffer

写完成→toggle同步→检测脉冲→切换

**frame_read_write桥接模块：**

写侧（sd_card_clk 域 → SDRAM 控制器）

写侧工作在 `sd_card_clk`（100MHz），它的上游是 `bmp_read` 模块

- `write_req`：写请求。sd_card_bmp 发起的，要写一帧图到 SDRAM。这个信号要一直保持高，直到 `write_req_ack` 回了应答。
- `write_req_ack`：写应答。frame_read_write 收到请求、准备好之后回一个单拍脉冲。
- `write_en`：写使能。每个写数据周期拉高一拍。
- `write_data[31:0]`：写数据。32 位宽，就是一个像素的 24 位 RGB 加上 8 位保留位。

这四个信号进来之后，frame_read_write 把它们转换成 SDRAM 控制器认识的信号

- `App_wr_en`：写使能，直接对接 SDRAM 控制器的写端口。
- `App_wr_addr[20:0]`：写地址。
- `App_wr_din[31:0]`：写数据。
- `App_wr_dm[3:0]`：写字节掩码。代码里固定赋值 `4'b0000`，意思是 4 个字节全部写入，不屏蔽。

重点说**写地址怎么算**。大家看代码，它有 4 个基地址输入：`write_addr_0`、`write_addr_1`、`write_addr_2`、`write_addr_3`，都是 21 位。然后有一个 `write_addr_index[1:0]`，2 位，用来选择用哪个基地址。

官方例程虽然只用双缓冲（BUF0/BUF1），但接口设计成了 4 个 bank—— 这是官方留好的升级口子，第 7 课我们扩成四 bank 的时候就直接用上了，不用改这个模块。现在大家只要知道：`write_addr_index` 就是 `write_buf_idx`，sd_card_bmp 告诉它 "你这次往 BUF0 写还是 BUF1 写"，它就选对应的基地址，然后在这个基地址上连续写 `write_len` 个像素。

#### 读侧（video_clk 域 ← SDRAM 控制器）

读侧工作在 `video_clk`（25MHz），上游是视频时序模块 `video_timing_data`。端口是镜像的：

- `read_req`：读请求。video_timing_data 要读一帧显示数据，一直保持高直到应答。
- `read_req_ack`：读应答。
- `read_en`：读使能，每个像素周期拉高一拍。
- `read_data[31:0]`：读数据，输出给 video_timing_data。

同样，它有 4 个读基地址 `read_addr_0` 到 `read_addr_3`，用 `read_addr_index[1:0]` 选择。这个 `read_addr_index` 就是 `disp_buf_idx`—— 显示哪个缓冲，sd_card_bmp 告诉它 "现在显示 BUF0 还是 BUF1"。

SDRAM 控制器返回的数据是：

- `Sdr_rd_en`：读数据有效。
- `Sdr_rd_dout[31:0]`：读数据。

frame_read_write 把这两个信号转换成标准的 `read_en` 和 `read_data` 输出给视频域。

#### 内部跨时钟域 FIFO

为什么需要 FIFO？因为写侧在 100MHz，读侧在 25MHz，两个时钟域完全不同。写侧塞数据很快（SD 卡读 BMP），读侧取数据很慢（一个像素一个像素地喂给 HDMI）。如果直接连，必然溢出或者欠载。

所以模块内部有两个异步 FIFO：

1. **写侧 FIFO**：`wfifo_32_32_512`，32 位宽，512 深度。写侧（100MHz）往 FIFO 里塞像素，读侧（SDRAM 控制器时钟 mem_clk）从 FIFO 里取出来，攒够一个 burst（BURST_SIZE=256 个字）就一次性写 SDRAM。
2. **读侧 FIFO**：SDRAM burst 读完一整行之后，数据灌进读侧 FIFO，video_clk 慢慢往外取。

大家看代码第 92 行，写 FIFO 例化的是 `wfifo_32_32_512`，写时钟是 `write_clk`，读时钟是 `mem_clk`。这就是跨时钟域的标准做法 —— 异步 FIFO，两端用各自的时钟。

#### V_FLIP 垂直翻转

还有一个参数大家要注意：`WRITE_V_FLIP = 1`。这是什么意思？

BMP 文件的存储顺序是**从下往上**的 —— 第一行数据其实是图片最底下那一行。但屏幕显示是从上往下的。如果直接按 BMP 文件顺序写进 SDRAM，读出来图片就是倒的。

所以 frame_read_write 在写 SDRAM 的时候，做了一个垂直翻转：写的时候倒着写，从最后一行开始写，写回 SDRAM 地址空间的低地址；读的时候正序读，读出来图片就是正的了。这个翻转逻辑在 `frame_fifo_write` 子模块里，由 `WRITE_V_FLIP` 参数控制。



总结：

**桥接**：把写侧的简单握手信号转换成 SDRAM 控制器的 burst 接口。

**跨时钟域**：写侧 100MHz、读侧 25MHz、SDRAM 控制器侧又是 mem_clk，三个时钟域之间用异步 FIFO 隔开（第92行的wfifo)

**缓冲选择**：通过 write_addr_index/read_addr_index 选择 BUF0 或 BUF1，实现双缓冲



**SDRAM控制器（sdram U3）：**

- 加密IP，绝对不能修改
- 接口：`App_wr_en/App_wr_addr/App_wr_din/App_wr_dm`（写），`App_rd_en/App_rd_addr`（读请求），`Sdr_rd_en/Sdr_rd_dout`（读数据返回）
- 状态信号：`Sdr_init_done`（初始化完成）、`Sdr_init_ref_vld`（刷新有效）、`Sdr_busy`（忙）

**数据流：**

- 写：TF卡→sd_card_bmp（BMP解析）→frame_read_write（写桥接）→sdram
- 读：video_timing_data（时序+读请求）→frame_read_write（读桥接）→sdram→frame_read_write→video_delay（延迟对齐）→HDMI

### 1.2 官方方式的6个严重局限

把官方帧缓存架构彻底搞懂之后，我们能发现6个严重局限：

[代码/图示块另行核对]

> **Note：** ①只有双缓冲，2个buffer来回切换，4张图片不能同时驻留；②读写挤在一个桥接模块frame_read_write二合一，职责不清修改困难；③无FIFO缓存，直接写SDRAM，像素速率不匹配时丢数据；④无burst读写，单字读写效率低，SDRAM带宽浪费；⑤无错误处理，写溢出/读下溢/超时，系统卡死无反馈；⑥切换复杂且易撕裂，write_buf/disp_buf/pending_buf三套索引toggle同步延迟导致撕裂。

**逐个说明：**

1. **只有双缓冲，4张图片不能同时驻留**：官方只有BUF0和BUF1两个buffer，4张图片需要来回覆盖。切换图片时必须重新从TF卡加载到"非当前显示"的另一块buffer，加载完成后才能切换。这意味着每次切换都有加载延迟（几百毫秒），而且如果TF卡读取慢，切换等待时间更长。四bank架构可以让4张图片同时驻留SDRAM，切换时只需要改读地址，零延迟。

2. **读写挤在一个桥接模块，职责不清**：frame_read_write同时处理写和读，是一个"二合一"模块。写侧和读侧耦合在一起，修改任何一方都可能影响另一方。而且这个模块内部有跨时钟域FIFO，逻辑复杂，出问题时很难定位是写侧的问题还是读侧的问题。正规架构应该把loader（写）和reader（读）完全分离，各自独立，职责清晰。

3. **无FIFO缓存，像素速率不匹配时丢数据**：官方写路径是sd_card_bmp直接输出像素给frame_read_write，没有FIFO缓存。BMP解析的像素输出速率和SDRAM写入速率可能不匹配——BMP解析可能突发输出一批像素，然后停顿；SDRAM写入可能因为刷新/忙而停顿。没有FIFO缓存的话，速率不匹配时就会丢像素，导致图片花屏。

4. **无burst读写，SDRAM带宽浪费**：官方是单字读写（每次写/读一个32位字），没有burst。SDRAM的特性是burst读写效率高——连续读写多个字时，只有第一个字有行激活延迟，后面的字可以连续输出。单字读写每次都有行激活延迟，SDRAM带宽利用率很低。四bank架构用128字burst读写，带宽利用率大幅提升。

5. **无错误处理，系统卡死无反馈**：官方帧缓存几乎没有错误处理——写溢出（FIFO满了还在写）、读下溢（FIFO空了还在读）、写超时（SDRAM一直忙）、读超时（请求发了没数据返回），这些错误都没有检测和反馈。出问题时系统卡死，没有任何错误码，调试非常困难。四bank架构有完善的错误码（loader 6个+reader 4个错误码通过reader_error输出+1个独立underflow信号），出问题时能快速定位。

6. **切换复杂且易撕裂**：官方有三套buffer索引（write_buf_idx、disp_buf_idx、pending_buf_idx），切换逻辑复杂。写完成后通过frame_write_toggle_mem跨时钟域同步，然后才切换disp_buf_idx。这个同步有延迟，如果在同步完成前读侧已经开始读新的buffer，就会读到半新半旧的数据，导致画面撕裂。四bank架构每个图片固定一个bank，切换只需要改active_index，在frame_start（帧消隐期）提交，完全避免撕裂。

这6个局限，就是本节课要解决的。解决方案就是：**四bank帧缓存+loader/reader分离**，让写和读完全独立，每个图片固定一个bank，用FIFO+burst提升效率，用完善的错误码保证可靠性。

---

## 二、四bank帧缓存基础

在讲怎么改之前，我们先把四bank帧缓存的核心概念搞清楚。

### 2.1 四bank的核心概念

**图2.1a 四Bank地址范围：**

[代码/图示块另行核对]

**图2.1b Bank与图片对应关系：**

[代码/图示块另行核对]

**四bank划分：**
- 每张图片640×480=307200像素，每个像素32位（24位RGB+8位保留），所以每张图片占307200个字
- Bank0基地址：`BANK0_BASE = 0`
- Bank1基地址：`BANK1_BASE = 307200`
- Bank2基地址：`BANK2_BASE = 307200 × 2 = 614400`
- Bank3基地址：`BANK3_BASE = 307200 × 3 = 921600`
- 总占用：4 × 307200 = 1228800字 × 4字节 = 4,915,200字节 ≈ 4.7MiB（4.9MB）（SDRAM通常8MB/16MB，足够）

**跟双缓冲的本质区别：**
- 双缓冲：2个buffer是"临时"的，4张图片轮流覆盖，切换时需要重新加载
- 四bank：4个bank是"固定"的，每张图片永久占用一个bank，切换时只需要改读地址
- 双缓冲切换有加载延迟（几百毫秒），四bank切换零延迟（只改一个寄存器）

**地址映射公式：**
[代码/图示块另行核对]
- `image_index`：图片编号（0~3）
- `pixel_offset`：像素在图片内的偏移（0~307199）
- 写的时候：`app_wr_addr = bank_base(active_image) + pixels_written`
- 读的时候：`app_rd_addr = bank_base(reader_index) + issued_count`

### 2.2 loader/reader分离的设计思想

[代码/图示块另行核对]

**为什么要分离？**
1. **职责清晰**：loader只负责"把像素写进SDRAM"，reader只负责"从SDRAM读像素送显示"，各自独立，互不干扰
2. **修改安全**：修改loader不会影响reader，修改reader不会影响loader，出问题时容易定位
3. **时钟域独立**：loader工作在sd_card_clk（或mem_clk），reader工作在mem_clk+pix_clk双时钟域，各自独立处理时钟域
4. **可复用性强**：loader可以复用给任何需要写帧缓存的场景，reader可以复用给任何需要读帧缓存的场景

**loader的职责：**

- 接收BMP解码器的像素流（pixel_valid + pixel_rgb）

- 内部FIFO缓存像素，解决速率不匹配

- burst写SDRAM（128字burst），提升带宽利用率

- 管理写地址（bank_base + pixels_written）

- 检测错误（FIFO溢出、像素计数错误、写超时、解码错误、短帧）

- 输出image_complete标记（4张图片哪些加载完成）

	burst写的流程：

	1. BMP解析输出像素，写入FIFO，pixels_received++

	2. 当FIFO里有≥128字（或收到frame_commit且FIFO非空），发起burst写

	3. 连续输出app_wr_en=1，地址bank_base(active_image)+pixels_written，数据从FIFO取，连续写128个字

	4. burst完成后，等待下一次burst触发条件

	5. 收到frame_commit且FIFO为空且burst不活跃时，检查pixels_received==307200且pixels_written==307200，正确则标记image_complete[active_image]=1，输出load_done；错误则输出对应错误码

		这里有个重要的信号：`image_complete[3:0]`，4位寄存器，每一位对应一张图片是否加载完成。reader和controller可以通过这个信号知道哪些图片可以显示——比如图片2还没加载完成，controller就不会切换到图片2，避免显示空白或错误数据。loader还有6个错误码，后面详细说

**reader的职责：**

- 接收显示时序的帧起始信号（frame_start）和像素消费信号（pixel_consume）
- 双时钟域：mem_clk（SDRAM控制器时钟）+ pix_clk（像素时钟）  

​    reader的核心流程（mem_clk域）：

1. frame_start到来（pix_clk域），通过toggle信号+2级同步器同步到mem_clk域
2. 检测到新帧请求，设置reload_pending和reload_index
3. 当reader不忙且in-flight为空，开始读新帧：重置issued_count/returned_count，设置reader_index
4. 当异步FIFO有足够空间（预留128字+margin）且in-flight burst未满，发起128字burst读
5. 连续输出app_rd_en=1，地址bank_base(reader_index)+issued_count，连续读128个字
6. SDRAM返回数据（sdram_rd_valid有效），写入异步FIFO，returned_count++
7. 一帧307200字读完，输出frame_read_done



reader的核心流程（pix_clk域）：

1. frame_start到来，发起读请求，重置consumed_count
2. 下一个周期才锁存active_index，翻转request_toggle（通知mem_clk域）。这里为什么要延迟一个周期才锁存？因为media_player_control需要在frame_start同一个时钟沿提交index_commit（把待切换的pending_index生效为active_index），reader延迟一个周期才锁存，保证拿到的是controller刚提交的最新值，而不是上一帧的旧值。这个设计保证了切换的原子性——不会在帧中间读到半新半旧的index。
3. pixel_consume（HDMI的de信号，数据有效）有效时，从prefetch取数据，consumed_count++
4. 如果pixel_consume时prefetch没有有效数据（prefetch_valid=0），说明显示下溢，置underflow=1



关键设计：

**异步FIFO**：用的是rfifo_32_32_512——32位写、32位读、512深度。写侧在mem_clk域（SDRAM返回数据时写），读侧在pix_clk域（pixel_consume时读）。内部用格雷码指针跨时钟域，避免亚稳态。满/空信号在各自时钟域生成。

**prefetch缓冲**：异步FIFO之后还有一级fifo_prefetch_2（2级预取缓冲）。作用是提前把异步FIFO的数据取出来，减少pix_clk域的读取延迟。pixel_consume时直接从prefetch取数据，不需要等异步FIFO的读延迟，避免显示下溢。

**in-flight burst管理**：reader最多允许2个burst同时在飞（MAX_INFLIGHT_BURSTS=2），也就是2×128=256字。发起burst时inflight_count+=128，收到数据时inflight_count--。作用是流水线操作——上一个burst的数据还在返回时，可以发起下一个burst，提升SDRAM读效率。如果只有1个在飞，必须等上一个burst全部返回才能发起下一个，效率低。

**underflow检测**：在pix_clk域，如果pixel_consume时prefetch_valid=0，说明SDRAM读速度跟不上显示速度，像素断供了，这就是下溢。下溢会导致画面花屏/撕裂，reader输出underflow信号，顶层可以用来做错误指示（比如数码管显示错误码）或自动恢复（比如重新读帧）。







- 内部异步FIFO跨时钟域，把SDRAM读数据从mem_clk域传到pix_clk域
- burst读SDRAM（128字burst），提升带宽利用率
- in-flight burst管理（最多2个burst同时在飞），提升流水线效率
- prefetch缓冲，提前预读像素，避免显示下溢
- 管理读地址（bank_base + issued_count）
- 检测错误（帧溢出、FIFO溢出、下溢、短帧）
- 输出underflow标记（显示下溢检测）

### 2.3 FIFO缓存+burst读写的原理

**FIFO缓存的作用：**
- 解决"生产者速率"和"消费者速率"不匹配的问题
- 生产者（BMP解析）可能突发输出一批像素然后停顿
- 消费者（SDRAM写）可能因为刷新/忙而停顿
- FIFO在中间缓存，生产者写FIFO，消费者读FIFO，速率不匹配时FIFO吸收抖动
- loader的FIFO深度：512字
- reader的异步FIFO深度：512字

**burst读写的原理：**
- SDRAM的特性：连续读写多个字时，只有第一个字有行激活延迟（tRCD），后面的字可以连续输出（潜伏期后）
- 单字读写：每次都有行激活延迟，带宽利用率低
- burst读写：一次请求连续读/写N个字，只有第一个字有行激活延迟，后面N-1个字连续输出，带宽利用率高
- 完赛工程的burst大小：128字
- loader：FIFO里攒够128字（或收到frame_commit）就发起一次128字burst写
- reader：一次发起128字burst读，数据存入异步FIFO，prefetch缓冲后送显示

**burst写的流程（loader）：**
1. BMP解析输出像素，写入FIFO
2. 当FIFO里有≥128字（或收到frame_commit且FIFO非空），发起burst写
3. 连续写128字到SDRAM（app_wr_en连续128个周期有效）
4. burst完成后，等待下一次burst触发条件
5. 收到frame_commit且FIFO为空时，一帧写完，输出load_done

**burst读的流程（reader）：**
1. frame_start到来，发起帧读请求
2. 当异步FIFO有足够空间（预留128字+margin）且in-flight burst未满，发起128字burst读
3. SDRAM返回128字数据，写入异步FIFO
4. prefetch缓冲从异步FIFO取数据，pix_clk域pixel_consume时输出像素
5. 一帧307200字读完，输出frame_read_done

### 2.4 双时钟域异步FIFO的跨时钟域处理

reader是双时钟域设计：
- `mem_clk`：SDRAM控制器时钟（通常100MHz），负责发起SDRAM读请求、接收读数据
- `pix_clk`：像素时钟（25MHz for 640×480@60Hz），负责输出像素给HDMI

**为什么需要双时钟域？**
- SDRAM控制器工作在mem_clk，读数据在mem_clk域返回
- HDMI显示工作在pix_clk，像素消费在pix_clk域
- 两个时钟频率不同、相位无关，不能直接传数据
- 需要异步FIFO做跨时钟域数据传输

**异步FIFO的工作原理：**
- 写侧（mem_clk域）：SDRAM返回数据时，写入异步FIFO
- 读侧（pix_clk域）：pixel_consume时，从异步FIFO读数据
- 异步FIFO内部用格雷码指针跨时钟域，避免亚稳态
- 满/空信号在各自时钟域生成
- 完赛工程用的是`rfifo_32_32_512`（32位写、32位读、512深度）

**prefetch缓冲：**
- 异步FIFO之后还有一级`fifo_prefetch_2`（2级预取缓冲）
- 作用：提前把异步FIFO的数据取出来，减少pix_clk域的读取延迟
- pixel_consume时直接从prefetch取数据，不需要等异步FIFO的读延迟
- 避免显示下溢

**underflow检测：**
- 在pix_clk域，如果pixel_consume时prefetch没有有效数据（prefetch_valid=0），说明显示下溢
- 下溢意味着SDRAM读速度跟不上显示速度，可能导致画面花屏/撕裂
- reader输出underflow信号，顶层可以用来做错误指示或自动恢复

---

### 2.5 640×480视频时序参数详解

视频显示的核心是**行场同步时序**，理解这些参数是调试显示问题的基础。

**一行的结构（从左到右）**：

[代码/图示块另行核对]
一行总时钟数 = 640 + 16 + 96 + 48 = **800像素时钟**                 

**一帧的结构（从上到下）**：
[代码/图示块另行核对]
一帧总行数 = 480 + 10 + 2 + 33 = **525行**

**640×480@60Hz完整参数表**：
| 参数 | 值 | 说明 |
|------|-----|------|
| H_ACT | 640 | 水平有效像素 |
| H_FP | 16 | 水平前肩（Front Porch） |
| H_SYNC | 96 | 水平同步脉宽 |
| H_BP | 48 | 水平后肩（Back Porch） |
| H_TOTAL | 800 | 一行总时钟数 |
| V_ACT | 480 | 垂直有效行 |
| V_FP | 10 | 垂直前肩 |
| V_SYNC | 2 | 垂直同步脉宽 |
| V_BP | 33 | 垂直后肩 |
| V_TOTAL | 525 | 一帧总行数 |
| 像素时钟 | 25.175MHz | 800×525×60≈25.2MHz |
| 帧率 | 60Hz | 25.175MHz / (800×525) ≈ 60Hz |

**四段的作用**：
1. **有效区（ACTIVE）**：真正显示像素的区域，de=1
2. **前肩（FRONT PORCH）**：有效区结束后，同步脉冲开始前的空白期，给显示器准备时间
3. **同步脉冲（SYNC）**：hsync/vsync低有效，告诉显示器"新的一行/一帧开始了"
4. **后肩（BACK PORCH）**：同步脉冲结束后，下一个有效区开始前的空白期

**为什么需要前肩后肩？**
- 老式CRT显示器需要时间让电子枪从右回到左（行消隐）、从下回到上（场消隐）
- 现代LCD/HDMI虽然不需要电子枪回扫，但时序标准保留了这些参数
- 前肩后肩也是"消隐期"，可以用来传输其他数据（如HDMI的音频包就在消隐期传输）

### 2.6 video_timing_ctrl模块详解

完赛工程的视频时序控制器是一个**纯计数器+组合译码**模块，非常简洁：

[代码/图示块另行核对]

**设计要点**：
1. **纯计数器**：x和y两个计数器，x从0到799，y从0到524
2. **同拍组合译码**：de/hsync/vsync都是x/y的组合逻辑，和计数器同拍，不存在错拍
3. **参数化**：所有时序参数都是parameter，可以改成其他分辨率（如800×600、1024×768）
4. **x/y即坐标**：de=1时，x就是列坐标（0..639），y就是行坐标（0..479），不需要额外转换

**frame_start信号**：
完赛工程在video_timing_ctrl基础上还生成了`frame_start`脉冲（vsync上升沿，即y从524回到0的那一拍），用于帧边界提交、OSD锁存、转场计数等。

### 2.7 SDRAM burst读写接口时序

四bank帧缓存的loader和reader都通过SDRAM控制器的burst接口读写数据，理解这个接口时序很重要。

**SDRAM控制器接口（安路加密IP）**：

[代码/图示块另行核对]

**burst写时序（以128字burst为例）**：

[代码/图示块另行核对]
- loader攒够128字（256字节）后发起一次burst写
- 写地址连续递增，写数据连续输出
- SDRAM控制器内部自动处理行激活/预充电/刷新

**burst读时序**：
[代码/图示块另行核对]
- 发一个读请求，经过CAS latency（通常2~3个时钟）后数据开始连续返回
- reader用异步FIFO缓存返回的数据，避免下游来不及消费

**关键概念**：
1. **burst长度**：一次连续读写的字数，完赛工程用128字（256字节）
2. **CAS latency**：读请求到数据返回的延迟，SDRAM的固有特性
3. **bank interleaving**：四个bank可以交替读写，隐藏行激活延迟
4. **刷新**：SDRAM需要定期刷新（每64ms刷新所有行），控制器自动处理

**为什么用burst？**
- 单字读写效率低：每次读写都要行激活→读写→预充电，开销大
- burst读写效率高：一次行激活后连续读写多个字，带宽利用率高
- 640×480@60Hz需要约23MB/s的读带宽，burst是必须的

---## 三、从官方到四bank的过渡思路

### 3.1 整体架构替换

[代码/图示块另行核对]

**核心替换：用loader/reader分离替换frame_read_write桥接**
- `media_frame_loader`（帧加载器）：替换frame_read_write的写桥接侧，负责把BMP解码器的像素写入SDRAM对应bank
- `media_frame_reader`（帧读取器）：替换frame_read_write的读桥接侧+video_delay，负责从SDRAM对应bank读取像素，跨时钟域送显示
- `media_player_control`（播放控制器）：替换sd_card_bmp里的双缓冲管理逻辑，负责active_index/pending_index管理、自动轮播、切换控制
- `video_timing_ctrl`（时序控制器）：替换video_timing_data，负责产生HDMI时序
- `rgb_video_adapter`（输出适配器）：替换video_delay，负责像素输出对齐

**保持不变：**

- SDRAM控制器（sdram U3，加密IP，绝对不能修改）
- HDMI发射器（hdmi_1_4b_transmitter_core_wrapper + hdmi_phy_wrapper，加密IP）
- 时钟PLL（sys_pll、video_pll、PLL_HDMI_AUDIO）

### 3.2 接口适配

**写路径接口适配：**

- 官方：sd_card_bmp输出`write_req/write_req_ack/write_en/write_data[31:0]`给frame_read_write
- 新架构：BMP解码器输出`pixel_valid/pixel_rgb[23:0]/frame_commit`给media_frame_loader
- media_frame_loader输出`app_wr_en/app_wr_addr[20:0]/app_wr_data[31:0]/app_wr_mask[3:0]`直接对接SDRAM控制器
- 注意：官方write_data是`{bmp_data[23:16], bmp_data[15:8], bmp_data[7:0], 8'b0}`（RGB+保留），新架构loader内部做`{8'h00, pixel_rgb}`拼接

**读路径接口适配：**
- 官方：video_timing_data输出`read_req/read_req_ack`给frame_read_write，frame_read_write输出`read_en/read_data[31:0]`给video_delay
- 新架构：video_timing_ctrl输出`frame_start`和`de`（数据有效）给media_frame_reader
- media_frame_reader输出`pixel_rgb[23:0]/pixel_valid`给rgb_video_adapter
- media_frame_reader输出`app_rd_en/app_rd_addr[20:0]`直接对接SDRAM控制器，接收`sdram_rd_valid/sdram_rd_data[31:0]`
- 注意：官方SDRAM控制器的读数据信号是`Sdr_rd_en/Sdr_rd_dout`，新架构reader期望`sdram_rd_valid/sdram_rd_data`，需要在顶层做信号名映射（语义一致，只是名字不同）

**控制接口适配：**

- 官方：sd_card_bmp管理`write_buf_idx/disp_buf_idx/pending_buf_idx`，输出给frame_read_write
- 新架构：media_player_control管理`active_index/pending_index`，输出给media_frame_reader
- 切换方式：官方是写完成后toggle同步→切换disp_buf_idx；新架构是frame_start时提交active_index→reader读对应bank
- 按键/自动轮播：官方在sd_card_bmp里处理；新架构在media_player_control里处理

### 3.3 SDRAM控制器接口映射

**关键：SDRAM控制器是加密IP，不能修改，必须做信号名映射**

| 新架构信号（loader/reader） | 官方SDRAM控制器信号 | 说明 |
|---|---|---|
| controller_init_done | Sdr_init_done | 初始化完成 |
| controller_busy | Sdr_busy | 忙 |
| refresh_active | Sdr_init_ref_vld | 刷新有效（或接1'b0，视控制器行为） |
| app_wr_en | App_wr_en | 写使能 |
| app_wr_addr[20:0] | App_wr_addr[20:0] | 写地址 |
| app_wr_data[31:0] | App_wr_din[31:0] | 写数据 |
| app_wr_mask[3:0] | App_wr_dm[3:0] | 写字节掩码 |
| app_rd_en | App_rd_en | 读使能 |
| app_rd_addr[20:0] | App_rd_addr[20:0] | 读地址 |
| sdram_rd_valid | Sdr_rd_en | 读数据有效（语义一致，名字不同） |
| sdram_rd_data[31:0] | Sdr_rd_dout[31:0] | 读数据 |

> 注意：`Sdr_rd_en`的语义需要确认——如果是"读数据输出有效"（跟sdram_rd_valid一致），直接映射即可；如果是"读请求应答"，则需要额外逻辑。从官方frame_read_write的用法看，`Sdr_rd_en`应该是跟`Sdr_rd_dout`同时有效的"读数据有效"信号，跟`sdram_rd_valid`语义一致。

### 3.4 最小改动方案

**替换frame_read_write桥接为loader/reader分离，SDRAM控制器和HDMI保持不变。**

具体来说：
1. 新增三个文件：`media_frame_loader.v`、`media_frame_reader.v`、`media_player_control.v`
   - 前两个参考完赛工程的代码
   - 第三个是播放控制器，负责切换管理
2. 修改顶层`top_tf_hdmi_audio.v`：
   - 删除frame_read_write实例
   - 删除video_timing_data实例（替换为video_timing_ctrl）
   - 删除video_delay实例（替换为rgb_video_adapter）
   - 新增media_frame_loader实例
   - 新增media_frame_reader实例
   - 新增media_player_control实例
   - 新增video_timing_ctrl实例（如果没有的话）
   - 新增rgb_video_adapter实例（如果没有的话）
   - SDRAM控制器信号名映射（app_wr_*→App_wr_*，app_rd_*→App_rd_*，sdram_rd_*→Sdr_rd_*）
3. sd_card_bmp的修改：把BMP解析部分独立出来，输出pixel_valid/pixel_rgb/frame_commit给loader；双缓冲管理部分删除（替换为media_player_control）
4. SDRAM控制器和HDMI发射器保持不变

这个方案的好处是：SDRAM控制器（加密IP）完全不动，只替换中间的桥接层，风险可控。

---

## 四、完赛工程的四bank实现详解

### 4.1 media_frame_loader（帧加载器）

**功能**：接收BMP解码器的像素流，通过FIFO缓存+burst写，把像素写入SDRAM对应bank。

**核心参数：**
- `ADDR_WIDTH = 21`：地址位宽
- `IMAGE_WORDS = 307200`：每帧像素数（640×480）
- `FIFO_DEPTH = 512`：FIFO深度
- `BURST_SIZE = 128`：burst大小
- `STALL_TIMEOUT = 65535`：写超时阈值

**四bank地址：**
[代码/图示块另行核对]

**核心流程：**

1. **接收像素**：`pixel_valid`有效时，把`pixel_rgb`拼成`{8'h00, pixel_rgb}`写入FIFO，`pixels_received++`
2. **FIFO管理**：`wr_ptr`写指针、`rd_ptr`读指针、`fifo_count`计数
3. **burst触发**：当`fifo_count >= BURST_SIZE`（128）或收到`frame_commit`且FIFO非空时，发起一次burst写。为什么frame_commit也要触发？因为一帧的最后一个burst可能不足128字（307200除以128等于2400，刚好整除，所以最后一个burst也是128字，但如果图片尺寸不是128的倍数，最后一个burst就不足128字），这时候需要frame_commit触发把剩余数据写完
4. **burst写**：连续输出`app_wr_en=1`，地址`bank_base(active_image) + pixels_written`，数据从FIFO取，连续写N个字（N=128或剩余字数）
5. **完成判断**：收到`frame_commit`且FIFO为空且burst不活跃时，检查`pixels_received == IMAGE_WORDS && pixels_written == IMAGE_WORDS`，正确则标记`image_complete[active_image]=1`，输出`load_done`；错误则输出对应错误码

**错误码（6个）：**

- `ERR_NOT_ACTIVE (0x41)`：未激活时收到像素
- `ERR_FIFO_OVERFLOW (0x42)`：FIFO溢出
- `ERR_PIXEL_COUNT (0x43)`：像素计数错误（超过IMAGE_WORDS）
- `ERR_DECODE (0x44)`：解码错误
- `ERR_SHORT_FRAME (0x45)`：短帧（像素数不足）
- `ERR_WRITE_STALL (0x46)`：写超时（SDRAM一直忙）

**关键设计：**
- `image_complete[3:0]`：4位寄存器，每一位对应一张图片是否加载完成。reader/controller可以通过这个信号知道哪些图片可以显示
- `stall_count`：写超时计数器，当FIFO有数据但无法发起burst写时递增，超过STALL_TIMEOUT报错
- `commit_seen`：帧提交标记，收到frame_commit后置1，用于判断一帧是否接收完成

### 4.2 media_frame_reader（帧读取器）

**功能**：从SDRAM对应bank读取像素，通过双时钟域异步FIFO+prefetch缓冲，送到HDMI显示。

**核心参数：**

- `ADDR_WIDTH = 21`：地址位宽
- `IMAGE_WORDS = 307200`：每帧像素数
- `FIFO_DEPTH = 512`：异步FIFO深度
- `FIFO_MARGIN = 8`：FIFO预留空间（防止溢出）
- `BURST_SIZE = 128`：burst大小
- `BURST_GAP_CYCLES = 12`：burst之间的间隔周期
- `MAX_INFLIGHT_BURSTS = 2`：最大在飞burst数（流水线）
- `DIAG_RETURN_PATTERN = 0`：诊断参数（默认关闭），开启后用测试彩条图案替换SDRAM返回数据，用于调试显示链路
- `DIAG_SYNTH_STREAM = 0`：诊断参数（默认关闭），开启后内部合成测试图案流，不依赖SDRAM读，用于单独调试reader输出

**双时钟域：**
- `mem_clk/mem_rst_n`：SDRAM控制器时钟域，负责发起读请求、接收读数据、写异步FIFO
- `pix_clk/pix_rst_n`：像素时钟域，负责接收frame_start、消费像素、读异步FIFO、输出显示

**核心流程（mem_clk域）：**

1. **请求同步**：pix_clk域的`request_toggle_pix`通过2级同步器同步到mem_clk域（`request_sync1_mem/request_sync2_mem`）
2. **帧重载**：检测到新请求（`request_sync2_mem != request_seen_mem`），如果reader不忙且in-flight为空，设置`reload_pending_mem`和`reload_index_mem`
3. **发起burst读**：当`reader_busy && controller_init_done && FIFO有空间 && in-flight未满 && burst间隔到`时，发起128字burst读
4. **burst读**：连续输出`app_rd_en=1`，地址`bank_base(reader_index) + issued_count`，连续读128字
5. **接收数据**：`sdram_rd_valid`有效时，数据写入异步FIFO，`returned_count++`
6. **完成判断**：`returned_count == IMAGE_WORDS - 1`时，一帧读完，输出`frame_read_done`

**核心流程（pix_clk域）：**

1. **帧起始**：`frame_start`到来时，发起读请求（`request_pending_pix=1`），重置`consumed_count_pix`
2. **请求提交（延迟一个周期锁存）**：下一个周期，才锁存`active_index`，翻转`request_toggle_pix`（通知mem_clk域）。**为什么要延迟一个周期？** 因为`media_player_control`需要在`frame_start`同一个时钟沿提交`index_commit`（把pending_index生效为active_index），reader延迟一个周期才锁存active_index，保证拿到的是controller刚提交的最新值，而不是上一帧的旧值。这个设计保证了切换的原子性——不会在帧中间读到半新半旧的index。
3. **像素消费**：`pixel_consume`（即HDMI的de信号）有效时，从prefetch取数据，`consumed_count_pix++`
4. **underflow检测**：如果`pixel_consume`时`prefetch_valid=0`，说明显示下溢，置`underflow=1`

**in-flight burst管理：**
- `inflight_count_mem`：当前在飞的字数（已发起读请求但未收到数据）
- 最多允许`MAX_INFLIGHT_BURSTS × BURST_SIZE = 2 × 128 = 256`字在飞
- 发起burst时`inflight_count += burst_size`，收到数据时`inflight_count--`
- 作用：流水线操作，上一个burst的数据还在返回时，可以发起下一个burst，提升SDRAM读效率

**异步FIFO+prefetch：**
- `rfifo_32_32_512`：异步FIFO，32位写/32位读，512深度，mem_clk写/pix_clk读
- `fifo_prefetch_2`：2级预取缓冲，从异步FIFO提前取数据，减少pix_clk域读取延迟
- `pixel_rgb = prefetch_data[23:0]`：取低24位作为RGB（高8位是保留）

**错误码（4个，通过reader_error输出）+ 独立underflow信号：**
- `ERR_FRAME_OVERRUN (0x61)`：帧溢出（上一帧没读完就来了新请求）
- `ERR_FIFO_OVERFLOW (0x62)`：异步FIFO溢出
- `ERR_SHORT_FRAME (0x64)`：短帧（返回数据不足）
- 独立`underflow`信号：显示下溢（pix_clk域单独输出，不通过reader_error，顶层可合并为0x63显示）
- `ERR_NONE (0x00)`：无错误状态（复位值，不算错误码）

### 4.3 两个模块的协作关系

[代码/图示块另行核对]

> **Note：** burst写SDRAM=FIFO攒够128字发起app_wr_en+app_wr_addr(bank+offset)+app_wr_data；burst读SDRAM=app_rd_en+app_rd_addr(bank+offset)，最多2个在飞；返回数据=sdram_rd_valid+sdram_rd_data；跨时钟域=异步FIFO(mem_clk→pix_clk)；输出像素=pixel_valid+pixel_rgb。

1. loader和reader完全独立，各自对接SDRAM控制器的写端口和读端口
2. loader在上电/切换时加载图片到对应bank，加载完成后image_complete置位
3. reader在每个frame_start时根据active_index读对应bank，通过异步FIFO跨时钟域送显示
4. 切换图片时，controller只需要改active_index，reader在下一个frame_start读新bank，零延迟切换
5. SDRAM控制器内部仲裁写和读（加密IP内部处理），loader和reader不需要关心对方

---

## 五、完整修改代码

> 本节汇总所有修改的完整代码，标注插入位置，方便直接复制使用。

### 5.0 改动位置总览

[代码/图示块另行核对]

> **Note：** ①sd_card_bmp修改：BMP解析输出pixel流，删除双缓冲管理；②删除frame_read_write、video_timing_data、video_delay；③新增loader、reader、播放控制、视频时序、rgb适配实例；④sdram U3保持不变（信号名映射）；⑤HDMI发射器保持不变；⑥新增文件：media_frame_loader.v、media_frame_reader.v、media_player_control.v（参考完赛工程）。

### 5.1 新增文件：media_frame_loader.v

**位置**：在工程的src/目录下新建`media_frame_loader.v`文件，添加到工程。

代码参考完赛工程`rtl/memory/media_frame_loader.v`，约218行。核心端口：

[代码/图示块另行核对]

> 注意：loader的时钟`clk`应该接SDRAM控制器时钟（ext_mem_clk），因为loader直接对接SDRAM控制器的写端口。BMP解码器如果工作在sd_card_clk域，需要在解码器和loader之间加异步FIFO做跨时钟域，或者把BMP解码器也改到ext_mem_clk域。完赛工程的BMP解码器工作在mem_clk域，跟loader同时钟。

### 5.2 新增文件：media_frame_reader.v

**位置**：在工程的src/目录下新建`media_frame_reader.v`文件，添加到工程。

代码参考完赛工程`rtl/memory/media_frame_reader.v`，约370行。核心端口：

[代码/图示块另行核对]

> 注意：reader内部例化了`rfifo_32_32_512`（异步FIFO）和`fifo_prefetch_2`（预取缓冲），这两个是安路FPGA的原语或自定义模块。如果你的工程里没有这两个模块，需要从完赛工程里拷贝过来，或者用安路TD的IP核生成等效的异步FIFO。

### 5.3 新增文件：media_player_control.v（播放控制器）

**位置**：在工程的src/目录下新建`media_player_control.v`文件，添加到工程。

代码参考完赛工程`rtl/control/media_player_control.v`。核心功能：
- 管理`active_index`（当前显示图片）和`pending_index`（待切换图片）
- 处理按键（下一张/上一张）和自动轮播
- 在`frame_start`时提交`index_commit`，把pending_index生效为active_index
- 输出`auto_enabled`（自动轮播使能）和`control_error`（控制错误码）

核心端口：
[代码/图示块另行核对]

### 5.4 修改文件：顶层top_tf_hdmi_audio.v

这是最核心的修改。需要删除frame_read_write/video_timing_data/video_delay，新增loader/reader/controller/timing_ctrl/adapter，并做SDRAM控制器信号名映射。

**修改点1：删除frame_read_write、video_timing_data、video_delay实例**

删除以下三个实例：
[代码/图示块另行核对]

**修改点2：新增media_frame_loader实例**

[代码/图示块另行核对]

**修改点3：新增media_frame_reader实例**

[代码/图示块另行核对]

**修改点4：新增media_player_control实例**

[代码/图示块另行核对]

**修改点5：SDRAM控制器信号名映射**

[代码/图示块另行核对]

> 注意：`Sdr_rd_en`的语义需要跟reader的`sdram_rd_valid`一致（都是"读数据有效"）。如果你的SDRAM控制器`Sdr_rd_en`语义不同（比如是"读请求应答"），需要额外逻辑转换。从官方frame_read_write的用法看，`Sdr_rd_en`应该是跟`Sdr_rd_dout`同时有效的"读数据有效"信号。

**修改点6：新增video_timing_ctrl和rgb_video_adapter**

> ⚠️ 以下例化代码中的参数名（H_ACT/H_FP等）和端口名（pclk/hsync/vsync/de/x/y/hs_in/vs_in等）为**示例写法**，不一定与完赛工程真实接口完全一致。复制前请务必对照完赛工程中这两个模块的实际端口定义调整参数名和信号名。

[代码/图示块另行核对]

> 注意：`video_timing_ctrl`和`rgb_video_adapter`在完赛工程中有现成代码，可参考`rtl/integration/media_video_pipeline.v`中的集成方式，以及`rtl/display/`目录下的源文件（具体文件名以工程实际为准）。如果你的工程里没有，需要从完赛工程拷贝，或者用安路TD的IP核生成等效模块。

**修改点7：sd_card_bmp修改（BMP解析输出像素流）**

sd_card_bmp需要做两个修改：
1. 把BMP解析部分的输出从`write_req/write_en/write_data`改成`pixel_valid/pixel_rgb/frame_commit`，对接loader
2. 删除双缓冲管理部分（write_buf_idx/disp_buf_idx/pending_buf_idx/load逻辑），替换为对接media_player_control

**具体信号映射：**
- BMP解析输出：`bmp_data_wr_en`→`loader_pixel_valid`，`bmp_data[23:0]`→`loader_pixel_rgb`
- 帧提交：`bmp_ready`→`loader_frame_commit`

> ⚠️ **bmp_ready语义风险（重要）**：必须确认`bmp_ready`的准确语义。如果`bmp_ready`是"**BMP解析完成（最后一个像素已输出）**"，可以直接对接`loader_frame_commit`；如果`bmp_ready`是"**TF卡源文件读取完成**"（此时BMP解析可能还在进行，最后几个像素还没输出），则**不能直接对接**——否则loader会在像素还没全部进FIFO时就认为一帧结束，报`ERR_SHORT_FRAME`。正确做法是：在BMP解析模块内部，当最后一个像素输出后（`pixels_received == 307200`）再产生`frame_commit`脉冲，而不是用源文件读取完成信号。建议上板前用SignalTap确认`bmp_ready`与最后一个`bmp_data_wr_en`的时序关系。

**BMP解析输出改造代码示例（在sd_card_bmp的BMP解析模块内）：**

[代码/图示块另行核对]

**loader加载控制状态机示例（在顶层或sd_card_bmp内）：**

[代码/图示块另行核对]

> 注意：loader的时钟是`ext_mem_clk`，而sd_card_bmp的BMP解析工作在`sd_card_clk`域。如果`sd_card_clk`和`ext_mem_clk`是同一个PLL输出的同频时钟（通常都是100MHz），可以直接对接；如果频率不同，需要在BMP解析和loader之间加异步FIFO做跨时钟域。完赛工程的BMP解码器工作在mem_clk域，跟loader同时钟，所以不需要跨域。

**按键对接：**
- 原来的key_next/key_auto消抖输出对接media_player_control的`next_event`/`toggle_auto_event`
- `loader_image_complete`信号对接media_player_control的`image_complete`输入（controller只切换到已加载完成的图片）

> 以上是sd_card_bmp的核心修改点。完整的修改需要根据你的实际工程调整信号名和位宽。建议参考完赛工程的顶层集成（`rtl/integration/media_video_pipeline.v`和`board/player_audio_integration/`目录下的顶层文件）来理解完整的连接关系。

### 5.5 SDRAM控制器和HDMI发射器

**保持不变**：
- `sdram U3`：加密IP，绝对不能修改，只需要做信号名映射
- `hdmi_1_4b_transmitter_core_wrapper` + `hdmi_phy_wrapper`：加密IP，保持不变
- 时钟PLL：sys_pll、video_pll、PLL_HDMI_AUDIO，保持不变

---

## 六、改动量汇总

| 改动项 | 类型 | 主要改动文件 | 新增/修改 | 改动量 |
|---|---|---|---|---|
| 1. 新增media_frame_loader | 必做 | 新增media_frame_loader.v | 新增1个模块 | ~218行（参考完赛工程） |
| 2. 新增media_frame_reader | 必做 | 新增media_frame_reader.v | 新增1个模块 | ~370行（参考完赛工程） |
| 3. 新增media_player_control | 必做 | 新增media_player_control.v | 新增1个模块 | ~200行（参考完赛工程） |
| 4. 新增video_timing_ctrl | 必做 | 新增video_timing_ctrl.v | 新增1个模块 | ~100行（参考完赛工程） |
| 5. 新增rgb_video_adapter | 必做 | 新增rgb_video_adapter.v | 新增1个模块 | ~50行（参考完赛工程） |
| 6. 顶层修改 | 必做 | top_tf_hdmi_audio.v | 删除3个实例+新增5个实例+信号映射+sd_card_bmp修改 | ~300行修改 |
| 7. sd_card_bmp修改 | 必做 | sd_card_bmp.v | BMP解析输出改像素流+删除双缓冲管理 | ~150行修改 |

**总改动量：** 新增5个文件约938行（参考完赛工程），修改2个文件约450行。主要工作量在顶层信号连接和sd_card_bmp的BMP解析输出改造。

> 注意：完赛工程的loader/reader/controller/timing_ctrl/adapter代码可以参考，但**不能直接拷过来就用**——因为完赛工程的顶层集成跟官方例程不同，信号名、时钟域、复位极性可能有差异。核心工作是：①理解每个模块的接口和功能；②在顶层做正确的信号连接和时钟域对接；③改造sd_card_bmp的BMP解析输出。

---

## 七、验证方法与测试用例

| 编号 | 测试用例 | 操作方法 | 预期结果 | 验证的功能 |
|---|---|---|---|---|
| 1 | 正常启动显示 | 上电，TF卡有PIC1~4.BMP | 正常显示PIC1.BMP，无花屏 | 基本功能不破坏 |
| 2 | 手动切换 | 按"下一张"按键 | 依次显示PIC2→PIC3→PIC4→PIC1，切换零延迟无撕裂 | 四bank切换正常（核心验证） |
| 3 | 自动轮播 | 按"自动"按键开启轮播 | 每隔N秒自动切换图片，切换零延迟无撕裂 | 自动轮播正常 |
| 4 | 切换撕裂测试 | 快速连续按"下一张"按键 | 每次切换都在帧消隐期完成，画面无撕裂 | frame_start提交机制正常 |
| 5 | 四bank独立存储测试 | 切换到每张图片后，观察显示是否正确 | 4张图片都能正确显示，互不干扰 | 四bank地址映射正确 |
| 6 | loader错误码测试 | 用损坏的BMP文件（像素数不足） | loader输出ERR_SHORT_FRAME错误码，系统不卡死 | loader错误处理正常 |
| 7 | reader underflow测试 | 降低SDRAM时钟或提高像素时钟（模拟读速度不足） | reader输出underflow信号，系统不卡死 | reader下溢检测正常 |
| 8 | burst读写测试 | 用SignalTap抓取app_wr_en/app_rd_en | 写/读都是连续128个周期的burst，不是单字 | burst读写正常 |
| 9 | FIFO缓存测试 | 用SignalTap抓取loader内部fifo_count | FIFO有数据缓存，速率不匹配时不丢像素 | FIFO缓存正常 |
| 10 | 双时钟域测试 | 用SignalTap抓取pix_clk域的pixel_valid | 像素输出连续，无亚稳态/丢数据 | 异步FIFO跨域正常 |
| 11 | image_complete测试 | 上电后观察loader的image_complete[3:0] | 4张图片加载完成后对应位置1，controller只切换到已完成的图片 | image_complete机制正常 |

**验证注意事项：**
- 测试用例2（手动切换）是最核心的验证——官方双缓冲切换有加载延迟（几百毫秒），四bank切换应该是零延迟（只改active_index）。如果切换还是有延迟，说明loader还在重新加载，四bank架构没生效。
- 测试用例4（切换撕裂测试）验证frame_start提交机制——切换应该在帧消隐期（vsync期间）完成，画面活跃期不应该有半新半旧的数据。如果有撕裂，说明active_index提交时机不对。
- 测试用例8（burst读写）验证效率提升——用SignalTap抓取app_wr_en/app_rd_en，应该看到连续128个周期的burst，而不是单字读写。如果还是单字，说明FIFO/burst逻辑没生效。

---

## 八、从官方到完赛的帧缓存架构演进

[代码/图示块另行核对]

**演进的核心思路：**
1. 第一步（第7课）：四bank帧缓存+loader/reader分离，解决双缓冲的6个局限（只有2个buffer、读写耦合、无FIFO、无burst、无错误处理、切换易撕裂）
2. 第二步：完善显示架构——多图层混合（视频层+OSD层+字幕层）、动态分辨率切换、硬件缩放（图片缩放到屏幕分辨率）、3D加速（SDRAM纹理映射）
3. 第三步（完赛工程）：完整显示子系统——四bank帧缓存+OSD叠加（状态显示/字幕）+淡入淡出转场（切换动画）+音频可视化（频谱显示）

每一步都保证上板能跑，每一步都只改显示子系统，存储子系统（FAT32）和控制逻辑保持稳定。

---

## 九、帧缓存设计的核心原则

1. **读写分离，职责清晰**：loader只负责写，reader只负责读，各自独立。不要把读写挤在一个桥接模块里，职责不清、修改困难、出问题难定位。

2. **多bank独立存储，避免来回搬移**：每张图片固定一个bank，切换时只改读地址，零延迟。不要用双缓冲来回覆盖，切换有加载延迟。

3. **FIFO缓存解决速率不匹配**：生产者（BMP解析）和消费者（SDRAM写）速率可能不匹配，必须有FIFO在中间缓存。没有FIFO的话，速率不匹配时就会丢像素。

4. **burst读写提升SDRAM带宽利用率**：SDRAM的特性是burst读写效率高，连续读写多个字时只有第一个字有行激活延迟。用128字burst读写，带宽利用率比单字读写高很多。

5. **双时钟域用异步FIFO，不要直接跨域**：SDRAM控制器时钟（mem_clk）和像素时钟（pix_clk）频率不同、相位无关，必须用异步FIFO做跨时钟域数据传输。不要直接把mem_clk域的信号接到pix_clk域，会有亚稳态。

6. **切换在帧消隐期提交，避免撕裂**：切换图片时，active_index应该在frame_start（vsync消隐期）提交，reader在下一帧读新bank。不要在帧活跃期切换，会导致半新半旧的撕裂画面。

7. **完善错误处理，系统不能卡死**：写溢出、读下溢、像素计数错误、短帧、写超时、帧溢出，这些错误都要有明确的错误码。出问题时系统不能卡死，要能报错并恢复。underflow检测尤其重要——显示下溢意味着SDRAM读速度跟不上显示速度，会导致花屏。

