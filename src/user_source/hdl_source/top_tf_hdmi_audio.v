`timescale 1ns/1ps
//==============================================================================
// 模块：top（HX4S20C / EG4S20BG256 单镜像媒体播放器）
//
// 职责：整个工程唯一的顶层。它自己不做图像/音频算法，只负责四件事：
//   1) 生成四个时钟域及其各自的复位；
//   2) 把 SD卡→FAT32→BMP→SDRAM→显示→HDMI 这条链上的模块按顺序连起来；
//   3) 控制上电启动顺序（初始化→装载图片→排空写入→建缩略图缓存→开始播放）；
//   4) 把所有跨时钟域的信号用规定方式搬过去（单拍事件用 toggle、多位参数用帧提交）。
//
// 四个时钟域（都由 sys_pll_promax_40 一个 PLL 产生）：
//   clk        50MHz 系统域：SD卡SPI、FAT32、BMP解码、按键/菜单/拨码、UART、参数Flash
//   mem_clk    40MHz 内存域：SDRAM读写、缩略图缓存构建、帧读取
//   pixel_clk  25MHz 像素域：颜色调节、转场、OSD/字幕/波形、HDMI音频包
//   pixel_clk_5x 125MHz 串行域：TMDS 10:1 串化输出
//
// 图片数据链：
//   TF卡 → sd_media_service → fat32_* → bmp24_decoder(+2×2缩小) → media_frame_loader
//        → media_sdram_write_cdc(50→40MHz) → SDRAM四图常驻
//        → media_frame_reader/预取FIFO → 亮度对比度 → 转场 → OSD/字幕/波形
//        → media_hdmi_audio_bridge → hdmi_phy_wrapper → HDMI_B
//
// 音频数据链：
//   TF卡扇区 → wav_stream_player(BRAM) → 音量/淡入淡出 → HDMI Data Island 音频包
//   （PCM_START_LBA=0 时不读卡，音频来自 pcm_media_tone 合成音调）
//
// 板上操作：K1复位 / K2下一张 / K3手动自动+长按上一张 / K4音量+长按周期 /
//           K2+K3同时按3秒保存参数；SW1缩略图 / SW2参数调节 / SW3选对比度 / SW4强制1kHz测试音
//==============================================================================
module top #(
    // 音频PCM在卡上的物理起始LBA与总扇区数。两个都为0表示"不读卡音频"，
    // 此时 wav_stream_player 不启动，声音来自合成音调。
    parameter [31:0] PCM_START_LBA=0,
    parameter [31:0] PCM_TOTAL_SECTORS=0,
    // 置1则上电直接进入"本地图案"诊断模式，完全绕过SD卡与SDRAM读取。
    parameter integer DIAG_LOCAL_PATTERN=0,
    // 置1时 SW4 作为本地电梯告警开关；默认媒体模式仍保留 SW4 测试音。
    parameter integer ELEVATOR_DEMO_MODE=0
)(
    input wire clk,rst_n,key1,key2,key3,   // 50MHz输入、低有效复位、K2/K3/K4
    input wire [3:0] sw,                   // 拨码开关逻辑值（不是面板ON字样）
    input wire uart_rx,
    output wire uart_tx,
    output wire [7:0] seg_sel,seg_data,    // 数码管位选/段选
    output wire HDMI_CLK_P,HDMI_D2_P,HDMI_D1_P,HDMI_D0_P,
    output wire HDMI_DDC_SCL,inout wire HDMI_DDC_SDA,
    output wire sd_ncs,sd_dclk,sd_mosi,input wire sd_miso,   // TF卡SPI
    output wire flash_cs_n,flash_sclk,flash_mosi,flash_wp_n,flash_hold_n,
    input wire flash_miso                  // 参数保存用的U33 W25X64用户Flash
);
    //--------------------------------------------------------------------------
    // 1. 时钟与复位
    //    PLL 输出 mem_clk(40M)/mem_clk_shift(40M移相144°供SDRAM采样)/
    //    pixel_clk(25M)/pixel_clk_5x(125M)。ext_reset_n 等 PLL 锁定后才释放，
    //    每个域再用 reset_sync 各自同步释放，避免跨域异步复位。
    //--------------------------------------------------------------------------
    wire mem_clk,mem_clk_shift,pixel_clk,pixel_clk_5x,mem_locked;
    wire sys_reset_n,mem_reset_n,pix_reset_n,serial_reset_n;
    wire ext_reset_n=rst_n && mem_locked;
    sys_pll_promax_40 u_mem_pll(.refclk(clk),.reset(~rst_n),.clk0_out(),
        .clk1_out(mem_clk),.clk2_out(mem_clk_shift),.clk3_out(pixel_clk),
        .clk4_out(pixel_clk_5x),.locked(mem_locked));
    reset_sync u_sys_reset(.clk(clk),.ext_rst_n(ext_reset_n),.rst_n_sync(sys_reset_n));
    reset_sync u_mem_reset(.clk(mem_clk),.ext_rst_n(ext_reset_n),.rst_n_sync(mem_reset_n));
    reset_sync u_pix_reset(.clk(pixel_clk),.ext_rst_n(ext_reset_n),.rst_n_sync(pix_reset_n));
    reset_sync u_serial_reset(.clk(pixel_clk_5x),.ext_rst_n(ext_reset_n),.rst_n_sync(serial_reset_n));

    //--------------------------------------------------------------------------
    // 2. 单变量实板诊断入口
    //    操作：按住 K4(key2)、把 SW4(sw[3]) 拨到1，再释放 K1 复位。
    //    复位释放后只采样一次，随后可以松开 K4；下次正常复位自动退出。
    //    diag_local_sys：输出本地图案，完全不读SDRAM（隔离显示链）。
    //    diag_fifo_sys ：仍走读取FIFO路径，用于对比"FIFO前/FIFO后"哪个环节花屏。
    //    这两个标志是系统域单拍量，下面用 sync_2ff 分别同步到内存域和像素域。
    //--------------------------------------------------------------------------
    reg [5:0] diag_boot_count;
    reg diag_local_sys,diag_fifo_sys;
    reg [1:0] diag_key_sync,diag_sw_sync,diag_fifo_sw_sync;
    always @(posedge clk or negedge sys_reset_n)
        if(!sys_reset_n) begin
            diag_boot_count<=0;diag_local_sys<=0;diag_fifo_sys<=0;diag_fifo_sw_sync<=0;
            diag_key_sync<=2'b11;diag_sw_sync<=0;
        end else begin
            diag_key_sync<={diag_key_sync[0],key2};
            diag_sw_sync<={diag_sw_sync[0],sw[3]};
            diag_fifo_sw_sync<={diag_fifo_sw_sync[0],sw[2]};
            if(diag_boot_count!=63) begin          // 只在复位后的固定窗口内采样一次
                diag_boot_count<=diag_boot_count+1'b1;
                if(diag_boot_count==62) begin
                    diag_local_sys<=DIAG_LOCAL_PATTERN || (!ELEVATOR_DEMO_MODE && !diag_key_sync[1] && diag_sw_sync[1]);
                    diag_fifo_sys<=!DIAG_LOCAL_PATTERN && !ELEVATOR_DEMO_MODE && !diag_key_sync[1] && diag_sw_sync[1] && diag_fifo_sw_sync[1];
                end
            end
        end
    wire diag_local_pix,diag_local_mem;
    sync_2ff u_diag_pix(.clk(pixel_clk),.rst_n(pix_reset_n),
        .async_in(diag_local_sys),.sync_out(diag_local_pix));
    sync_2ff u_diag_mem(.clk(mem_clk),.rst_n(mem_reset_n),
        .async_in(diag_local_sys),.sync_out(diag_local_mem));

    wire diag_fifo_pix,diag_fifo_mem;
    sync_2ff u_diag_fifo_pix(.clk(pixel_clk),.rst_n(pix_reset_n),
        .async_in(diag_fifo_sys),.sync_out(diag_fifo_pix));
    sync_2ff u_diag_fifo_mem(.clk(mem_clk),.rst_n(mem_reset_n),
        .async_in(diag_fifo_sys),.sync_out(diag_fifo_mem));

    //--------------------------------------------------------------------------
    // 3. SDRAM控制器状态与跨域握手信号
    //    原厂加密控制器只给出 初始化完成/忙/刷新中/读有效 这几个状态，
    //    它们属于 mem_clk 域，需要同步回系统域参与启动判断。
    //--------------------------------------------------------------------------
    wire sdram_init,sdram_busy,sdram_refresh,rd_valid;
    wire [31:0] rd_data;
    wire init_sys,cdc_idle,cdc_idle_sys,cdc_full,cdc_overflow;
    sync_2ff u_init_sys(.clk(clk),.rst_n(sys_reset_n),.async_in(sdram_init),.sync_out(init_sys));
    sync_2ff u_idle_sys(.clk(clk),.rst_n(sys_reset_n),.async_in(cdc_idle),.sync_out(cdc_idle_sys));

    //--------------------------------------------------------------------------
    // 4. 存储装载链：SD卡 → FAT32 → BMP解码 → 写SDRAM
    //    media_storage_ingest_top 内部包含 sd_media_service、media_ingest_frontend
    //    （含FAT32扫描、BMP24解码、2×2缩小、帧完成提交）和写入数据源。
    //    start 由下面的启动状态机给出；done/error_stage/error_code 回报结果。
    //--------------------------------------------------------------------------
    wire ingest_busy,ingest_done,card_ready;
    wire [2:0] ingest_stage;
    wire [7:0] ingest_error,ingest_detail;
    wire [4:0] resource_valid,image_complete,image_scale;
    wire elevator_alert_pix,elevator_alert_fallback,elevator_alert_pix_state;
    wire [2:0] elevator_alert_page;
    wire source_wr;
    wire [20:0] source_addr;
    wire [3:0] source_mask;
    wire [31:0] source_data;
    reg ingest_start,player_enable;
    reg [2:0] boot_state;
    reg [7:0] drain_count;
    wire cache_done_sys,cache_start_mem,cache_failed_sys;
    reg cache_start;
    reg cache_ready;
    wire write_drained,write_drained_sys;
    wire video_request,video_urgent,video_grant,write_request,write_grant;
    wire cache_request,cache_grant,cache_write_request;
    wire [1:0] memory_owner;
    wire video_return,cache_return;
    wire mem_app_read,mem_app_write;
    sync_2ff u_write_drained(.clk(clk),.rst_n(sys_reset_n),
        .async_in(write_drained),.sync_out(write_drained_sys));
    wire audio_req,audio_busy,audio_done,audio_valid;
    wire [31:0] audio_lba;
    wire [7:0] audio_byte,audio_error;
    wire [8:0] audio_byte_index;
    media_storage_ingest_top #(.SPI_CLK_DIV(2),.INIT_STARTUP_DELAY_CYCLES(5000000),.ALLOW_2X_SOURCE(1),.EARLY_DISPLAY(1),
        .PRIORITIZE_EMERGENCY(ELEVATOR_DEMO_MODE)) u_storage(
        .clk(clk),.rst_n(sys_reset_n),.start(ingest_start && !diag_local_sys),.busy(ingest_busy),.done(ingest_done),
        .error_stage(ingest_stage),.error_code(ingest_error),.error_detail(ingest_detail),
        .card_ready(card_ready),.card_high_capacity(),.resource_valid(resource_valid),
        .image_complete(),.image_ready(image_complete),.image_scale_2x(image_scale),
        // 写入排空判据：CDC 空闲 + 已排空 + 源域当前没有新的写请求
        .write_drain_idle(cdc_idle_sys && write_drained_sys && !source_wr),
        .controller_init_done(init_sys && !cdc_full),.controller_busy(1'b0),.refresh_active(1'b0),
        .app_wr_en(source_wr),.app_wr_addr(source_addr),.app_wr_mask(source_mask),.app_wr_data(source_data),
        .sd_cs_n(sd_ncs),.sd_sclk(sd_dclk),.sd_mosi(sd_mosi),.sd_miso(sd_miso),
        // 音频与图片共用一条SD服务：boot_state==4 之后 SD 卡交给音频用
        .audio_owner(boot_state==4),.audio_req(audio_req),.audio_lba(audio_lba),
        .audio_busy(audio_busy),.audio_done(audio_done),.audio_valid(audio_valid),
        .audio_byte(audio_byte),.audio_error(audio_error),.audio_byte_index(audio_byte_index));

    //--------------------------------------------------------------------------
    // 5. 写跨时钟域：50MHz(系统域) 写 → 40MHz(内存域) 写
    //    SHARED_MEMORY=1 表示与视频读取共享同一个SDRAM控制器，
    //    因此要把 controller_busy/refresh_active 传进来等待总线空闲，
    //    并用 burst_grant 参与下面的仲裁。
    //--------------------------------------------------------------------------
    wire cdc_wr;
    wire [20:0] cdc_addr;
    wire [3:0] cdc_mask;
    wire [31:0] cdc_data;
    media_sdram_write_cdc #(.SHARED_MEMORY(1)) u_write_cdc(.src_clk(clk),.src_rst_n(sys_reset_n),
        .src_wr_en(source_wr),.src_wr_addr(source_addr),.src_wr_mask(source_mask),.src_wr_data(source_data),
        .src_full(cdc_full),.src_overflow(cdc_overflow),.dst_clk(mem_clk),.dst_rst_n(mem_reset_n),
        .dst_app_wr_en(cdc_wr),.dst_app_wr_addr(cdc_addr),.dst_app_wr_mask(cdc_mask),
        .dst_app_wr_data(cdc_data),.dst_idle(cdc_idle),
        .controller_busy(sdram_busy),.refresh_active(sdram_refresh),
        .burst_grant(write_grant),.burst_request(write_request));

    //--------------------------------------------------------------------------
    // 6. 上电启动状态机（系统域，50MHz）
    //    0 等SDRAM初始化 → 1 装载四张图 → 2 等写入排空 → 3 构建缩略图缓存 → 4 播放
    //    进入播放有两个条件：至少一张图完整校验通过(image_complete!=0)，
    //    且写入CDC没有溢出。首图校验并排空后即可显示，其余图片继续后台装载。
    //--------------------------------------------------------------------------
    always @(posedge clk or negedge sys_reset_n) begin
        if(!sys_reset_n) begin ingest_start<=0;player_enable<=0;boot_state<=0;drain_count<=0;cache_start<=0;cache_ready<=0;end
        else begin
            ingest_start<=0;cache_start<=0;
            // Verified images are published only after file/FAT checking and
            // write draining. The first can display while later files load.
            if(image_complete!=0 && !cdc_overflow) player_enable<=1;
            case(boot_state)
                0: if(init_sys && diag_boot_count==63 && !diag_local_sys) begin ingest_start<=1;boot_state<=1;end
                1: if(ingest_done) begin boot_state<=2;drain_count<=0;end
                // 连续256拍确认CDC空闲且源域无写请求，才认为写入真正排空
                2: if(cdc_idle_sys && write_drained_sys && !source_wr) begin
                    if(drain_count==255) begin cache_start<=1;boot_state<=3;end
                    else drain_count<=drain_count+1'b1;
                end else drain_count<=0;
                3: if(cache_done_sys) begin cache_ready<=!cache_failed_sys;boot_state<=4;end
                default: ;
            endcase
        end
    end

    //--------------------------------------------------------------------------
    // 7. 缩略图缓存构建（内存域，40MHz）
    //    启动期把四张图按4:1采样合成到SDRAM第5页(地址1228800起)，
    //    只做一次；cache_start 是系统域单拍脉冲，用 toggle 同步到内存域。
    //--------------------------------------------------------------------------
    pulse_toggle_sync u_cache_start(.src_clk(clk),.src_rst_n(sys_reset_n),.src_pulse(cache_start),
        .dst_clk(mem_clk),.dst_rst_n(mem_reset_n),.dst_pulse(cache_start_mem));
    wire cache_busy,cache_done,cache_rd,cache_wr;
    wire [7:0] cache_error;
    sync_2ff u_cache_fault(.clk(clk),.rst_n(sys_reset_n),.async_in(cache_error!=0),.sync_out(cache_failed_sys));
    wire [20:0] cache_rd_addr,cache_wr_addr;
    wire [31:0] cache_wr_data;
    wire [3:0] complete_mem;
    genvar cm;
    generate for(cm=0;cm<4;cm=cm+1) begin:g_cache_complete
        sync_2ff u_sync(.clk(mem_clk),.rst_n(mem_reset_n),.async_in(image_complete[cm]),.sync_out(complete_mem[cm]));
    end endgenerate
    // image_complete 在 cache_start 握手之前已稳定，仍使用目的域寄存值。
    thumbnail_cache_builder #(.SHARED_MEMORY(1)) u_cache(.clk(mem_clk),.rst_n(mem_reset_n),.start(cache_start_mem),
        .image_complete(complete_mem),.busy(cache_busy),.done(cache_done),.error(cache_error),
        .app_rd_en(cache_rd),.app_rd_addr(cache_rd_addr),.rd_valid(rd_valid && cache_return),.rd_data(rd_data),
        .app_wr_en(cache_wr),.app_wr_addr(cache_wr_addr),.app_wr_data(cache_wr_data),
        .controller_busy(sdram_busy),.refresh_active(sdram_refresh),
        .burst_grant(cache_grant),.burst_request(cache_request),.burst_write(cache_write_request));
    pulse_toggle_sync u_cache_done(.src_clk(mem_clk),.src_rst_n(mem_reset_n),.src_pulse(cache_done),
        .dst_clk(clk),.dst_rst_n(sys_reset_n),.dst_pulse(cache_done_sys));
    wire player_mem;
    sync_2ff u_player_mem(.clk(mem_clk),.rst_n(mem_reset_n),.async_in(player_enable),.sync_out(player_mem));

    //--------------------------------------------------------------------------
    // 8. SDRAM访问仲裁（内存域）
    //    三路竞争同一个SDRAM控制器：视频读(owner=1)、写入CDC(owner=2)、
    //    缩略图缓存(owner=3)。仲裁器给出 owner 和 grant，下面的读写使能与
    //    地址/数据多路选择都按 owner 选择，保证同一时刻只有一路在访问。
    //--------------------------------------------------------------------------
    wire video_rd;
    wire [20:0] video_rd_addr;
    media_sdram_arbiter u_memory_arbiter(.clk(mem_clk),.rst_n(mem_reset_n),
        .controller_busy(sdram_busy),.refresh_active(sdram_refresh),
        .video_request(video_request),.video_urgent(video_urgent),
        .write_request(write_request),.cache_request(cache_request),.cache_write(cache_write_request),
        .app_read(mem_app_read),.app_write(mem_app_write),.rd_valid(rd_valid),
        .video_grant(video_grant),.write_grant(write_grant),.cache_grant(cache_grant),
        .owner(memory_owner),.video_return(video_return),.cache_return(cache_return),.write_drained(write_drained));
    // 诊断本地图案时切断应用侧读写，让SDRAM只做初始化和刷新
    assign mem_app_write=!diag_local_mem && ((memory_owner==3 && cache_wr) || (memory_owner==2 && cdc_wr));
    assign mem_app_read=!diag_local_mem && ((memory_owner==3 && cache_rd) || (memory_owner==1 && video_rd));

    //--------------------------------------------------------------------------
    // 9. 原厂加密SDRAM控制器实例
    //    地址单位是32位字，容量2M字；读写通道由 owner 多路选择。
    //    Clk_sft 是移相时钟，只用于内部采样，不参与逻辑时钟树。
    //--------------------------------------------------------------------------
    sdram U3(.Clk(mem_clk),.Clk_sft(mem_clk_shift),.Rst(~mem_reset_n),
        .Sdr_init_done(sdram_init),.Sdr_init_ref_vld(sdram_refresh),.Sdr_busy(sdram_busy),
        .App_wr_en(mem_app_write),.App_wr_addr(memory_owner==3?cache_wr_addr:cdc_addr),
        .App_wr_dm(memory_owner==3?4'd0:cdc_mask),.App_wr_din(memory_owner==3?cache_wr_data:cdc_data),
        .App_rd_en(mem_app_read),.App_rd_addr(memory_owner==3?cache_rd_addr:video_rd_addr),
        .Sdr_rd_en(rd_valid),.Sdr_rd_dout(rd_data));

    //--------------------------------------------------------------------------
    // 10. 按键、菜单、拨码与参数持久化（系统域）
    //     dual_key_chord_router：K2/K3 短按、K3长按1秒、K2+K3同时按3秒保存；
    //     param_menu_controller：K4 短按改音量、长按1秒改周期；
    //     sw[1]=1 时拨码进入参数调节，sw[2] 选亮度或对比度；
    //     player_config_persistence：把周期/音量/自动模式存进U33用户Flash。
    //     注意：本版 DEFAULT_VOLUME=0 且 RESTORE_VOLUME_ON_BOOT=0，
    //     即上电和K1复位后音量一定为0，但周期与自动模式仍从Flash恢复。
    //--------------------------------------------------------------------------
    wire next_sys,auto_sys,previous_sys,save_event;
    wire cfg_ready,cfg_busy,cfg_apply,cfg_load_done,cfg_save_done,cfg_fatal;
    wire [7:0] cfg_error,volume,mode;
    wire [31:0] period_ms,period_cycles;
    wire menu_update,menu_event;
    wire [31:0] menu_period;
    wire [7:0] menu_volume;
    wire [1:0] menu_kind;
    wire [3:0] menu_level;
    dual_key_chord_router #(.HOLD_CYCLES(150000000)) u_keys(.clk(clk),.rst_n(sys_reset_n),
        .save_enabled(cfg_ready),.key2_n(key1),.key3_n(key3),.key2_event(next_sys),
        .key3_event(auto_sys),.key3_long_event(previous_sys),.save_event(save_event),
        .save_locked(),.key2_stable_n(),.key3_stable_n());
    param_menu_controller u_menu(.clk(clk),.rst_n(sys_reset_n),.key4_n(key2),.service_ready(cfg_ready || cfg_fatal),
        .live_volume(volume),.live_period_ms(period_ms),.cfg_update_valid(menu_update),
        .cfg_period_ms(menu_period),.cfg_volume(menu_volume),.menu_event(menu_event),
        .menu_kind(menu_kind),.menu_level(menu_level));
    wire auto_enabled;
    wire auto_status_sys;
    sync_2ff u_auto_sys(.clk(clk),.rst_n(sys_reset_n),.async_in(auto_enabled),.sync_out(auto_status_sys));
    reg [3:0] sw_sync1,sw_sync2;
    reg [7:0] brightness,contrast;
    always @(posedge clk or negedge sys_reset_n)
        if(!sys_reset_n) begin sw_sync1<=0;sw_sync2<=0;brightness<=255;contrast<=128;end
        else begin
            sw_sync1<=sw;sw_sync2<=sw_sync1;   // 拨码两级同步
            // sw[1]=1 进入参数调节：sw[2]=1 调对比度，否则调亮度；K2加16、K3短按减16
            if(sw_sync2[1]) begin
                if(sw_sync2[2]) begin
                    if(next_sys) contrast<=contrast>239?255:contrast+16;
                    else if(auto_sys) contrast<=contrast<16?0:contrast-16;
                end else begin
                    if(next_sys) brightness<=brightness>239?255:brightness+16;
                    else if(auto_sys) brightness<=brightness<16?0:brightness-16;
                end
            end
        end
    wire view_sys,view_mode;
    sync_2ff u_view_sys(.clk(pixel_clk),.rst_n(pix_reset_n),.async_in(view_mode),.sync_out(view_sys));
    // 参数调节模式下 K3 短按改的是"自动/手动"开关，而不是减亮度
    wire mode_update=auto_sys && !sw_sync2[1] && !view_sys;
    player_config_persistence #(.DEFAULT_VOLUME(8'd0),.RESTORE_VOLUME_ON_BOOT(0)) u_config(.clk(clk),.rst_n(sys_reset_n),
        .cfg_update_valid((menu_update && !view_sys) || mode_update),.cfg_period_ms(menu_update?menu_period:period_ms),
        .cfg_volume(menu_update?menu_volume:volume),.cfg_mode(mode_update?{7'd0,~mode[0]}:mode),.save_request(save_event),
        .service_ready(cfg_ready),.busy(cfg_busy),.load_done(cfg_load_done),.save_done(cfg_save_done),
        .apply_valid(cfg_apply),.config_rejected(),.fatal_error(cfg_fatal),.error_code(cfg_error),
        .request_dropped(),.stored_config_valid(),.active_version(),.live_period_ms(period_ms),
        .live_period_cycles(period_cycles),.live_volume(volume),.live_mode(mode),
        .jedec_id(),.status1(),.status2(),.status3(),.flash_miso(flash_miso),
        .flash_cs_n(flash_cs_n),.flash_sclk(flash_sclk),.flash_mosi(flash_mosi),
        .flash_wp_n(flash_wp_n),.flash_hold_n(flash_hold_n));

    //--------------------------------------------------------------------------
    // 11. 系统域 → 像素域的单拍事件
    //     按键/菜单事件在50MHz产生，显示逻辑在25MHz消费，
    //     用 pulse_toggle_sync 转成像素域单拍脉冲。
    //     sw[1]=1 时按键用于调参数，所以不产生切图事件。
    //--------------------------------------------------------------------------
    wire frame_start,next_pix,auto_pix,previous_pix,confirm_pix;
    pulse_toggle_sync u_next(.src_clk(clk),.src_rst_n(sys_reset_n),.src_pulse(next_sys && !sw_sync2[1]),
        .dst_clk(pixel_clk),.dst_rst_n(pix_reset_n),.dst_pulse(next_pix));
    pulse_toggle_sync u_auto(.src_clk(clk),.src_rst_n(sys_reset_n),.src_pulse(auto_sys && !sw_sync2[1]),
        .dst_clk(pixel_clk),.dst_rst_n(pix_reset_n),.dst_pulse(auto_pix));
    pulse_toggle_sync u_previous(.src_clk(clk),.src_rst_n(sys_reset_n),.src_pulse(previous_sys && !sw_sync2[1]),
        .dst_clk(pixel_clk),.dst_rst_n(pix_reset_n),.dst_pulse(previous_pix));
    pulse_toggle_sync u_confirm(.src_clk(clk),.src_rst_n(sys_reset_n),.src_pulse(menu_event && view_sys),
        .dst_clk(pixel_clk),.dst_rst_n(pix_reset_n),.dst_pulse(confirm_pix));

    //--------------------------------------------------------------------------
    // 12. 多位参数的跨域提交
    //     拨码、模式、对比度、亮度、音量、周期打包成64位，用 frame_config_cdc
    //     在帧边界整体更新，避免参数在画面中间变化造成撕裂。
    //--------------------------------------------------------------------------
    wire [63:0] config_pix;
    frame_config_cdc #(.WIDTH(64),.RESET_VALUE({4'd0,4'd0,8'd128,8'd255,8'd0,32'd5000})) u_params(
        .src_clk(clk),.src_rst_n(sys_reset_n),.src_data({sw_sync2,3'd0,mode[0],contrast,brightness,volume,period_ms}),
        .dst_clk(pixel_clk),.dst_rst_n(pix_reset_n),.frame_start(frame_start),.dst_data(config_pix));
    wire [7:0] contrast_pix=config_pix[55:48],bright_pix=config_pix[47:40],volume_pix=config_pix[39:32];
    wire [3:0] switches_pix=config_pix[63:60];
    wire cache_ready_pix;
    sync_2ff u_cache_ready_pix(.clk(pixel_clk),.rst_n(pix_reset_n),
        .async_in(cache_ready),.sync_out(cache_ready_pix));
    // SW1(switches_pix[0]) 且缩略图缓存已就绪，才允许进入缩略图模式
    wire thumbnail_switch=switches_pix[0] && cache_ready_pix;

    //--------------------------------------------------------------------------
    // 13. 缩略图模式控制（像素域）
    //     缓存未就绪时 SW1 无效；模式切换沿、左右移动、确认选择都交给
    //     thumbnail_controller，它输出焦点格 focus_index 和已确认的 active_index。
    //--------------------------------------------------------------------------
    reg mode_seen;
    wire [1:0] focus_index,selected_index;
    wire [2:0] selected_media_index={1'b0,selected_index};
    wire thumb_transition,thumbnail_select;
    wire [4:0] complete_pix;
    genvar k;
    generate for(k=0;k<5;k=k+1) begin:g_complete
        sync_2ff u_sync(.clk(pixel_clk),.rst_n(pix_reset_n),.async_in(image_complete[k]),.sync_out(complete_pix[k]));
    end endgenerate
    always @(posedge pixel_clk or negedge pix_reset_n)
        if(!pix_reset_n) mode_seen<=0;else mode_seen<=thumbnail_switch;
    thumbnail_controller u_thumbnail(.clk(pixel_clk),.rst_n(pix_reset_n),
        .key_right(next_pix),.key_left(auto_pix),.key_confirm(confirm_pix),
        .key_mode((thumbnail_switch && !mode_seen) || (!thumbnail_switch && mode_seen && view_mode)),.image_complete(complete_pix[3:0]),.frame_start(frame_start),
        .view_mode(view_mode),.focus_index(focus_index),.active_index(selected_index),
        .transition_req(thumb_transition),.selection_committed(thumbnail_select));

    //--------------------------------------------------------------------------
    // 14. 显示视图状态（像素域）
    //     display_view=1 表示正在显示缩略图页；退出缩略图时要等选中的图片
    //     真正被读取器接管(active_index==selected_index)才切回全屏，
    //     否则会闪回上一张旧图。所有这些判断都在 frame_start 帧边界上做。
    //--------------------------------------------------------------------------
    wire hs,vs,de;
    wire [23:0] video_rgb;
    wire [9:0] video_x,video_y;
    wire [2:0] active_index;
    wire [7:0] video_error,fade_alpha;
    wire fade_active;
    reg [31:0] last_period;
    always @(posedge pixel_clk or negedge pix_reset_n)
        if(!pix_reset_n) last_period<=5000;
        else last_period<=config_pix[31:0];
    reg display_view,last_cfg_mode,last_display_view,selection_wait;
    always @(posedge pixel_clk or negedge pix_reset_n)
        if(!pix_reset_n) begin display_view<=0;last_cfg_mode<=0;last_display_view<=0;selection_wait<=0;end
        else begin
            last_cfg_mode<=config_pix[56];last_display_view<=display_view;
            if(thumbnail_select) selection_wait<=1;
            // 快选目标通过控制器握手提交之前保持缩略图，不能闪回旧图。
            if(frame_start) begin
                if(view_mode) display_view<=1;
                else if(!selection_wait || active_index==selected_index) begin display_view<=0;selection_wait<=0;end
            end
        end

    //--------------------------------------------------------------------------
    // 15. 视频主链（像素域）
    //     media_video_pipeline 内部按顺序完成：
    //       从SDRAM读帧(FIFO预取) → 亮度/对比度 → 16帧淡入淡出转场 → 时序产生
    //     本模块输出 HS/VS/DE、RGB、像素坐标和当前图片号。
    //     周期参数是毫秒，这里换算成25MHz周期数(*25000)后再交给自动轮播计数。
    //     player_enable 的判据：诊断FIFO模式直接放行；正常模式下要等本张图
    //     完整校验(complete_pix[active_index])且不在本地图案诊断中。
    //--------------------------------------------------------------------------
    wire [1:0] media_fault_src={ingest_error!=0,cdc_overflow};
    wire [1:0] media_fault_pix_bus;
    frame_config_cdc #(.WIDTH(2),.RESET_VALUE(2'd0)) u_media_fault_commit(
        .src_clk(clk),.src_rst_n(sys_reset_n),.src_data(media_fault_src),
        .dst_clk(pixel_clk),.dst_rst_n(pix_reset_n),.frame_start(frame_start),
        .dst_data(media_fault_pix_bus));
    wire media_fault_pix=media_fault_pix_bus[1] || media_fault_pix_bus[0];
    wire [2:0] elevator_state_code;
    elevator_demo_controller u_elevator_demo(
        .clk(pixel_clk), .rst_n(pix_reset_n), .frame_start(frame_start),
        .startup_ready(complete_pix[3:0] != 4'd0),
        .media_fault(media_fault_pix),
        .alert_request(elevator_alert_pix),
        .alert_page_available(complete_pix[4]),
        .alert_active(elevator_alert_pix_state),
        .alert_fallback(elevator_alert_fallback),
        .alert_page_index(elevator_alert_page), .state_code(elevator_state_code));
    // 控制逻辑同像素域运行，周期从毫秒换算为25MHz周期；手动/自动统一帧边界提交。
    media_video_pipeline #(.RUNTIME_DIAG(1),.SHARED_MEMORY(1),.FADE_FRAMES(16),.ENABLE_COLOR_ADJUST(1),.DEFAULT_PERIOD_CYCLES(125000000),
        .MIN_PERIOD_CYCLES(25000000),.MAX_PERIOD_CYCLES(1500000000)) u_video(
        .diag_fifo_pix(diag_fifo_pix),.diag_fifo_mem(diag_fifo_mem),
        .ctrl_clk(pixel_clk),.ctrl_rst_n(pix_reset_n),.next_event(next_pix && !display_view),
        .previous_event(previous_pix && !display_view),.select_valid(thumbnail_select),
        .select_index(selected_media_index),.view_mode(display_view),.mode_transition(display_view!=last_display_view),.focus_index(focus_index),
        .transition_alpha(fade_alpha),.transition_active(fade_active),.video_y(video_y),
        .toggle_auto_event(1'b0),.period_cfg_valid(last_period!=config_pix[31:0]),
        .period_cfg_cycles(config_pix[31:0]*32'd25000),.auto_cfg_valid(display_view || last_display_view!=display_view || last_cfg_mode!=config_pix[56]),.auto_cfg_enabled(config_pix[56] && !display_view),
        .image_complete(complete_pix),.emergency_active(elevator_alert_pix_state),.emergency_index(elevator_alert_page),
         .player_enable(diag_fifo_pix || (player_enable && !diag_local_pix && (display_view || complete_pix[active_index]))),.mem_clk(mem_clk),.mem_rst_n(mem_reset_n),
        .controller_init_done(sdram_init && player_mem),.controller_busy(sdram_busy),.refresh_active(sdram_refresh),
        .app_rd_en(video_rd),.app_rd_addr(video_rd_addr),.sdram_rd_valid(rd_valid && video_return && !diag_local_mem),.sdram_rd_data(rd_data),
        .burst_grant(video_grant),.burst_request(video_request),.read_urgent(video_urgent),
        .brightness(bright_pix),.contrast(contrast_pix),.pix_clk(pixel_clk),.pix_rst_n(pix_reset_n),.video_clk(),.video_hs(hs),.video_vs(vs),
        .video_de(de),.video_rgb(video_rgb),.video_x(video_x),.active_index(active_index),.pending_index(),
        .auto_enabled(auto_enabled),.frame_start(frame_start),.reader_busy(),.reader_underflow(),.video_error(video_error));

    //--------------------------------------------------------------------------
    // 16. 叠加层第一级：缩略图焦点框
    //     只画左上320×240里的四格；缩略图模式下给当前焦点格加黄色边框。
    //--------------------------------------------------------------------------
    wire de_adjust=de;
    wire [23:0] adjusted_rgb=video_rgb;
    wire hs_adjust=hs,vs_adjust=vs;
    wire [9:0] x_adjust=video_x,y_adjust=video_y;
    wire thumb_de,focus_border;
    thumbnail_layout u_layout(.in_de(de_adjust),.pixel_x({2'd0,x_adjust}),.pixel_y({2'd0,y_adjust}),
        .focus_index(focus_index),.image_complete(complete_pix[3:0]),.thumb_de(thumb_de),.source_index(),
        .source_x(),.source_y(),.focus_border(focus_border));
    // PIC5 尚未装载时，告警仍保留醒目的逻辑生成页，避免切换到黑屏。
    wire [23:0] alert_fallback_rgb=((x_adjust[5]^y_adjust[5]) ? 24'hb00000 : 24'h5a0000);
    // In elevator demonstration mode the display must remain informative while
    // TF/SDRAM is still starting or the media chain reports a fault.  The media
    // timing generator continues to run even when player_enable is low, so a
    // small FPGA-generated pattern can be shown without BRAM or a full frame
    // buffer.  Normal media mode keeps the existing black/diagnostic behavior.
    wire elevator_startup_page = ELEVATOR_DEMO_MODE &&
        ((elevator_state_code==3'd0) || (elevator_state_code==3'd4));
    wire [23:0] startup_page_rgb =
        ((x_adjust[7:5] ^ y_adjust[7:5]) ? 24'h102a43 : 24'h071521) ^
        ((x_adjust[5] && !y_adjust[8]) ? 24'h001018 : 24'h000000);
    wire [23:0] focus_rgb=elevator_alert_fallback ? alert_fallback_rgb :
        elevator_startup_page ? startup_page_rgb :
        ((display_view && focus_border)?24'hffff00:adjusted_rgb);

    //--------------------------------------------------------------------------
    // 17. 错误码汇总与跨域提交
    //     优先级：CDC溢出(86) > 缩略图缓存失败(85) > 装载错误(80~84) >
    //             音频错误(9x) > 参数Flash错误。
    //     错误码和细分码都要从系统域搬到像素域显示，同样走帧边界提交。
    //--------------------------------------------------------------------------
    wire [23:0] text_rgb,final_rgb;
    wire [7:0] system_error=cdc_overflow?8'h86:cache_failed_sys?8'h85:
        ingest_error!=0?ingest_error:audio_error!=0?{4'h9,audio_error[3:0]}:cfg_error;
    wire [7:0] system_error_pix;
    frame_config_cdc #(.WIDTH(8)) u_error_commit(.src_clk(clk),.src_rst_n(sys_reset_n),
        .src_data(system_error),.dst_clk(pixel_clk),.dst_rst_n(pix_reset_n),
        .frame_start(frame_start),.dst_data(system_error_pix));
    wire [7:0] error_pix=video_error!=0 ? video_error : system_error_pix;
    wire [7:0] detail_pix;
    frame_config_cdc #(.WIDTH(8)) u_error_detail_commit(.src_clk(clk),.src_rst_n(sys_reset_n),
        .src_data(ingest_detail),.dst_clk(pixel_clk),.dst_rst_n(pix_reset_n),
        .frame_start(frame_start),.dst_data(detail_pix));

    //--------------------------------------------------------------------------
    // 18. 串口与字幕（系统域解析，像素域显示）
    //     uart_rx_byte 收字节 → subtitle_uart_controller 解析 SUB= 命令；
    //     命令结果先存系统域 live_text/live_length/live_subtitle，
    //     再用 frame_config_cdc 整体提交到像素域，避免文字在画面中间改动。
    //     字幕内容不写Flash（SUB=SAVE 返回ERR），参数保存用K2+K3。
    //--------------------------------------------------------------------------
    wire [7:0] rx_data;
    wire rx_valid,rx_error,subtitle_commit,subtitle_enable;
    wire [95:0] subtitle_text;
    wire [5:0] subtitle_length;
    wire reply_valid,reply_ready,reply_last,subtitle_save;
    wire [7:0] reply_data;
    wire elev_update_valid,elev_alert_update_valid,alert_command_valid,alert_command_value,elev_alert_value;
    wire [7:0] elev_floor_value;
    wire elev_floor_basement;
    wire [1:0] elev_direction,elev_door;
    reg elev_alert_sys,elev_status_valid_sys,elev_floor_basement_sys;
    reg [7:0] elev_floor_sys;
    reg [3:0] elev_floor_tens_sys,elev_floor_ones_sys;
    reg [1:0] elev_direction_sys,elev_door_sys;
    reg elev_signal_lost_sys;
    reg [25:0] elev_timeout_counter;
    wire elev_alert_request_sys=elev_alert_sys || (ELEVATOR_DEMO_MODE && sw_sync2[3]);
    wire [15:0] elev_status_src={elev_alert_request_sys,elev_signal_lost_sys,
        elev_floor_basement_sys,elev_direction_sys,elev_door_sys,
        elev_floor_tens_sys,elev_floor_ones_sys,elev_status_valid_sys};
    wire [15:0] elev_status_pix;
    frame_config_cdc #(.WIDTH(16),.RESET_VALUE(16'hc001)) u_elevator_status_commit(
        .src_clk(clk),.src_rst_n(sys_reset_n),.src_data(elev_status_src),
        .dst_clk(pixel_clk),.dst_rst_n(pix_reset_n),.frame_start(frame_start),.dst_data(elev_status_pix));
    assign elevator_alert_pix=elev_status_pix[15];
    wire elevator_signal_lost_pix=elev_status_pix[14];
    wire elevator_floor_basement_pix=elev_status_pix[13];
    wire [1:0] elevator_direction_pix=elev_status_pix[12:11];
    wire [1:0] elevator_door_pix=elev_status_pix[10:9];
    wire [3:0] elevator_floor_tens_pix=elev_status_pix[8:5];
    wire [3:0] elevator_floor_ones_pix=elev_status_pix[4:1];
    wire elevator_status_valid_pix=elev_status_pix[0];
    wire elevator_alert_page_available=complete_pix[4];
    uart_rx_byte u_rx(.clk(clk),.rst_n(sys_reset_n),.rx(uart_rx),.data(rx_data),.valid(rx_valid),.framing_error(rx_error));
    reg [95:0] live_text;
    reg [5:0] live_length;
    reg live_subtitle;
    always @(posedge clk or negedge sys_reset_n)
        if(!sys_reset_n) begin live_text<=0;live_length<=0;live_subtitle<=0;end
        else if(subtitle_commit) begin live_text<=subtitle_text;live_length<=subtitle_length;live_subtitle<=subtitle_enable;end
    always @(posedge clk or negedge sys_reset_n) begin
        if(!sys_reset_n) begin
            elev_alert_sys<=1'b0; elev_status_valid_sys<=1'b0;
            elev_floor_basement_sys<=1'b0; elev_floor_sys<=8'd0;
            elev_floor_tens_sys<=4'd0; elev_floor_ones_sys<=4'd0;
            elev_direction_sys<=2'd0; elev_door_sys<=2'd0;
            elev_signal_lost_sys<=1'b1; elev_timeout_counter<=26'd0;
        end else begin
            if (elev_update_valid) begin
                elev_alert_sys<=elev_alert_value;
                elev_status_valid_sys<=1'b1;
                elev_floor_basement_sys<=elev_floor_basement;
                elev_floor_sys<=elev_floor_value;
                elev_floor_tens_sys<=elev_floor_value/10;
                elev_floor_ones_sys<=elev_floor_value%10;
                elev_direction_sys<=elev_direction;
                elev_door_sys<=elev_door;
                elev_signal_lost_sys<=1'b0;
                elev_timeout_counter<=26'd0;
            end else if (elev_timeout_counter==26'd49_999_999) begin
                elev_signal_lost_sys<=1'b1;
            end else begin
                elev_timeout_counter<=elev_timeout_counter+1'b1;
            end
            if (elev_alert_update_valid) elev_alert_sys<=elev_alert_value;
            if (alert_command_valid) elev_alert_sys<=alert_command_value;
        end
    end
    subtitle_uart_controller u_subtitle_uart(.clk(clk),.rst_n(sys_reset_n),.rx_data(rx_data),.rx_valid(rx_valid),
        .rx_framing_error(rx_error),.service_ready(1'b1),.save_done(1'b0),.save_failed(subtitle_save),
        .request_dropped(1'b0),.live_text(live_text),.live_length(live_length),.live_enable(live_subtitle),
        .cfg_update_valid(subtitle_commit),.cfg_text(subtitle_text),.cfg_length(subtitle_length),.cfg_enable(subtitle_enable),
        .elev_update_valid(elev_update_valid),.elev_floor_value(elev_floor_value),.elev_floor_basement(elev_floor_basement),
        .elev_direction(elev_direction),.elev_door(elev_door),.elev_alert_value(elev_alert_value),
        .elev_alert_update_valid(elev_alert_update_valid),.alert_command_valid(alert_command_valid),.alert_command_value(alert_command_value),
        .save_request(subtitle_save),.reply_valid(reply_valid),.reply_data(reply_data),.reply_last(reply_last),.reply_ready(reply_ready));
    wire [102:0] subtitle_pix;
    frame_config_cdc #(.WIDTH(103),.RESET_VALUE(103'd0)) u_subtitle_frame_commit(
        .src_clk(clk),.src_rst_n(sys_reset_n),.src_data({live_subtitle,live_length,live_text}),
        .dst_clk(pixel_clk),.dst_rst_n(pix_reset_n),.frame_start(frame_start),.dst_data(subtitle_pix));

    //--------------------------------------------------------------------------
    // 19. 叠加层第二级：OSD文字（状态/参数/计时/错误码 + 字幕）
    //     输入是已经过焦点框的像素，输出带文字阴影的RGB。
    //--------------------------------------------------------------------------
    promax_text_overlay u_text(.clk(pixel_clk),.rst_n(pix_reset_n),.vsync(vs_adjust),.de(de_adjust),
        .rgb_in(focus_rgb),.pixel_x(x_adjust),.pixel_y(y_adjust),.enable(1'b1),.subtitle_enable(subtitle_pix[102]),
        .subtitle_text(subtitle_pix[95:0]),.subtitle_length(subtitle_pix[101:96]),.brightness(bright_pix),
        .contrast(contrast_pix),.volume(volume_pix),.period_ms(config_pix[31:0]),.auto_enabled(auto_enabled),
        .source_scale_2x(image_scale[active_index]),.active_index(active_index),
        .loading(complete_pix[3:0]!=4'hf || !cache_ready_pix),.error_code(error_pix),.error_detail(detail_pix),
        .elevator_status_valid(elevator_status_valid_pix),.elevator_signal_lost(elevator_signal_lost_pix),
        .elevator_floor_basement(elevator_floor_basement_pix),.elevator_floor_tens(elevator_floor_tens_pix),
        .elevator_floor_ones(elevator_floor_ones_pix),.elevator_direction(elevator_direction_pix),
        .elevator_door(elevator_door_pix),.elevator_alert(elevator_alert_pix_state),
        .rgb_out(text_rgb),.overlay_active());

    //--------------------------------------------------------------------------
    // 20. 流水线级：文字查找与波形合成之间
    //     波形模块要用到坐标和HS/VS/DE，所以这里把整组信号（RGB、坐标、同步、
    //     诊断RGB）一起打一拍，保证波形看到的坐标和它处理的像素严格对齐。
    //--------------------------------------------------------------------------
    wire pcm_tap_valid;
    wire signed [15:0] pcm_tap_left;
    // Pipeline the entire bundle between text lookup and waveform composition.
    reg [23:0] text_stage_rgb,diag_stage_rgb;
    reg [23:0] diag_rgb;
    reg [9:0] text_stage_x,text_stage_y;
    reg text_stage_hs,text_stage_vs,text_stage_de;
    always @(posedge pixel_clk or negedge pix_reset_n)
        if(!pix_reset_n) begin
            text_stage_rgb<=0;diag_stage_rgb<=0;text_stage_x<=0;text_stage_y<=0;
            text_stage_hs<=1;text_stage_vs<=1;text_stage_de<=0;
        end else begin
            text_stage_rgb<=text_rgb;diag_stage_rgb<=diag_fifo_pix?video_rgb:diag_rgb;
            text_stage_x<=x_adjust;text_stage_y<=y_adjust;text_stage_hs<=hs_adjust;text_stage_vs<=vs_adjust;text_stage_de<=de_adjust;
        end

    //--------------------------------------------------------------------------
    // 21. 叠加层第三级：底部音轨面板（波形、包络、音量柱）
    //     PIPELINE_OUTPUT=1 表示内部再寄存一拍输出，所以下面还有一级流水线。
    //--------------------------------------------------------------------------
    promax_audio_waveform #(.PIPELINE_OUTPUT(1)) u_wave(.clk(pixel_clk),.rst_n(pix_reset_n),.vsync(text_stage_vs),.de(text_stage_de),
        .rgb_in(text_stage_rgb),.pixel_x(text_stage_x),.enable(1'b1),.pcm_tap_valid(pcm_tap_valid),
        .pcm_tap_left(pcm_tap_left),.rgb_out(final_rgb),.waveform_active());

    //--------------------------------------------------------------------------
    // 22. WAV/PCM播放器（写侧系统域，读侧像素域）
    //     play_enable 条件：启动完成(boot_state==4) + 两个PCM参数都非0。
    //     两个参数为0时本模块不工作，声音由下面的合成音调提供。
    //     播放时它通过 sd_req/sd_lba 向SD服务要扇区，读回的字节经BRAM跨到
    //     像素域输出48kHz样本；sample_ready 是像素域的背压。
    //--------------------------------------------------------------------------
    wire sample_tick,wav_valid,wav_ready,wav_active;
    wire signed [15:0] wav_sample;
    wav_stream_player u_wav(.wr_clk(clk),.wr_rst_n(sys_reset_n),
        .play_enable(player_enable && boot_state==4 && PCM_START_LBA!=0 && PCM_TOTAL_SECTORS!=0),
        .start_lba(PCM_START_LBA),.total_sectors(PCM_TOTAL_SECTORS),.sd_req(audio_req),.sd_lba(audio_lba),
        .sd_busy(audio_busy),.sd_valid(audio_valid),.sd_byte(audio_byte),.sd_byte_index(audio_byte_index),
        .sd_done(audio_done),.sd_error(audio_error),.rd_clk(pixel_clk),.rd_rst_n(pix_reset_n),
        .sample_tick(sample_tick),.sample_out(wav_sample),.sample_valid(wav_valid),.sample_ready(wav_ready),
        .sample_counter(),.stream_active(wav_active),.stream_end(),.buffer_low());

    //--------------------------------------------------------------------------
    // 23. 淡入淡出增益（像素域）
    //     转场用的 alpha 在像素域产生，音频也在像素域，所以这里把视频转场
    //     进度换算成音频增益，让画面淡出淡入时声音同步变化。
    //--------------------------------------------------------------------------
    wire [7:0] fade_gain;
    sync_fade_gain u_gain(.pix_clk(pixel_clk),.pix_rst_n(pix_reset_n),.frame_start(frame_start),
        .alpha_pix(fade_alpha),.fade_active(fade_active),.aud_clk(pixel_clk),.aud_rst_n(pix_reset_n),.gain_aud(fade_gain));

    //--------------------------------------------------------------------------
    // 24. 本地诊断图案（组合产生，只用于排查）
    //     上半屏8色条 → 中间120行灰阶 → 下面120行逐位彩色渐变+棋盘格。
    //     它绕过颜色调节、转场和全部叠加层，不使用读取器出来的像素。
    //--------------------------------------------------------------------------
    // 与最终视频同拍的坐标，直接进入既有 HDMI 编码/串行链路。
    // 上半屏 8 色条；第三个 120 行灰阶；最后 120 行逐位彩色渐变+棋盘格。
    // 诊断绕过颜色调节、转场和全部叠加层，完全不使用 reader_rgb。
    always @* begin
        if(y_adjust<240) begin
            if(x_adjust<80) diag_rgb=24'hffffff;
            else if(x_adjust<160) diag_rgb=24'hffff00;
            else if(x_adjust<240) diag_rgb=24'h00ffff;
            else if(x_adjust<320) diag_rgb=24'h00ff00;
            else if(x_adjust<400) diag_rgb=24'hff00ff;
            else if(x_adjust<480) diag_rgb=24'hff0000;
            else if(x_adjust<560) diag_rgb=24'h0000ff;
            else diag_rgb=24'h000000;
        end else if(y_adjust<360)
            diag_rgb={x_adjust[7:0],x_adjust[7:0],x_adjust[7:0]};
        else if(x_adjust<512)
            diag_rgb={x_adjust[7:0],y_adjust[7:0],x_adjust[7:0]^y_adjust[7:0]};
        else
            diag_rgb=(x_adjust[3]^y_adjust[3])?24'hffffff:24'h000000;
    end

    //--------------------------------------------------------------------------
    // 25. 波形输出后的最后一级流水线
    //     波形几何在透明混合前已寄存，这里把伴随信号（诊断RGB、Y、同步）
    //     再延迟一拍，保证它们与最终RGB同拍进入HDMI编码。
    //--------------------------------------------------------------------------
    // Waveform geometry is registered before the transparent color blend.
    // Delay every companion signal (including diagnostics and Y) by the same cycle.
    reg [9:0] wave_stage_x,wave_stage_y;
    reg wave_stage_hs,wave_stage_vs,wave_stage_de;
    reg [23:0] wave_diag_rgb;
    always @(posedge pixel_clk or negedge pix_reset_n)
        if(!pix_reset_n) begin
            wave_stage_x<=0;wave_stage_y<=0;wave_stage_hs<=1;wave_stage_vs<=1;wave_stage_de<=0;wave_diag_rgb<=0;
        end else begin
            wave_stage_x<=text_stage_x;wave_stage_y<=text_stage_y;
            wave_stage_hs<=text_stage_hs;wave_stage_vs<=text_stage_vs;wave_stage_de<=text_stage_de;wave_diag_rgb<=diag_stage_rgb;
        end
    // 诊断模式下用本地图案替换真实像素，其余情况用波形/文字叠加后的画面
    wire [23:0] hdmi_input_rgb=diag_local_pix?wave_diag_rgb:final_rgb;

    //--------------------------------------------------------------------------
    // 26. HDMI音频桥 + 物理层
    //     media_hdmi_audio_bridge 在视频消隐期插入 Data Island（音频采样包、
    //     ACR、InfoFrame），输出三路TMDS 10位符号；hdmi_phy_wrapper 用125MHz
    //     串化成差分对输出。DDC总线保持释放，分辨率固定VIC=1(640×480)。
    //--------------------------------------------------------------------------
    wire [9:0] ch0,ch1,ch2;
    media_hdmi_audio_bridge u_audio(.pixel_clk(pixel_clk),.pixel_rst_n(pix_reset_n),
        .video_hsync(wave_stage_hs),.video_vsync(wave_stage_vs),.video_de(wave_stage_de),.video_x(wave_stage_x),.video_rgb(hdmi_input_rgb),
        .media_id(active_index),.volume(volume_pix),.wav_valid(wav_valid),.wav_active(wav_active),
        .force_test(switches_pix[3]),.wav_sample(wav_sample),.fade_gain(fade_gain),.wav_ready(wav_ready),
        .sample_tick(sample_tick),.channel0_symbol(ch0),.channel1_symbol(ch1),.channel2_symbol(ch2),
        .sequence_error(),.tone_overflow(),.pcm_contract_error(),.blip_active(),
        .pcm_tap_valid(pcm_tap_valid),.pcm_tap_left(pcm_tap_left));
    hdmi_phy_wrapper #(.DEVICE("EG")) u_hdmi2phy_wrapper(.I_pixel_clk(pixel_clk),.I_serial_clk(pixel_clk_5x),
        .I_rst(~serial_reset_n),.I_tmds_channel_0(ch0),.I_tmds_channel_1(ch1),.I_tmds_channel_2(ch2),
        .I_tmds_channel_clk(10'b1111100000),.O_tmds_ch0_p(HDMI_D0_P),.O_tmds_ch1_p(HDMI_D1_P),
        .O_tmds_ch2_p(HDMI_D2_P),.O_tmds_clk_p(HDMI_CLK_P));
    // Route B 使用固定 VIC=1，不主动读取EDID；DDC总线保持释放。
    assign HDMI_DDC_SCL=1'b1;
    assign HDMI_DDC_SDA=1'bz;

    //--------------------------------------------------------------------------
    // 27. 人机输出：数码管 + UART状态回报
    //     图片号/模式在像素域，先搬回系统域再送去显示和串口。
    //     周期毫秒转"秒"用多拍减法实现，避免32位除法形成长组合路径。
    //--------------------------------------------------------------------------
    wire [1:0] index_sys;
    frame_config_cdc #(.WIDTH(2)) u_index_report(.src_clk(pixel_clk),.src_rst_n(pix_reset_n),.src_data(active_index),
        .dst_clk(clk),.dst_rst_n(sys_reset_n),.frame_start(1'b1),.dst_data(index_sys));
    // 周期换算采用多拍减法，避免32位除法直接串到数码管IO。
    reg [15:0] seconds_remainder;
    reg [5:0] seconds_count,period_seconds;
    reg seconds_busy;
    always @(posedge clk or negedge sys_reset_n)
        if(!sys_reset_n) begin seconds_remainder<=0;seconds_count<=0;period_seconds<=5;seconds_busy<=0;end
        else if(!seconds_busy) begin
            seconds_remainder<=period_ms[15:0];seconds_count<=0;seconds_busy<=1;
        end else if(seconds_remainder>=1000 && seconds_count<63) begin
            seconds_remainder<=seconds_remainder-16'd1000;seconds_count<=seconds_count+1'b1;
        end else begin period_seconds<=seconds_count;seconds_busy<=0;end
    seg7_panel u_panel(.clk(clk),.rst_n(sys_reset_n),.enable(1'b1),.media_id(index_sys),
        .volume(volume),.period_sec(period_seconds),.pic_event(next_sys),.vol_event(menu_event && menu_kind==0),
        .prd_event(menu_event && menu_kind==1),.seg_n(seg_data),.dig_n(seg_sel));
    uart_status_reporter u_report(.clk(clk),.rst_n(sys_reset_n),.enable(1'b1),.media_id(index_sys),
        .volume(volume),.period_ms(period_ms),.auto_enabled(auto_status_sys),.switch_event(next_sys),
        .menu_event(menu_event),.menu_kind(menu_kind),.error_code(system_error),
        .bright_event(sw_sync2[1] && (next_sys || auto_sys)),.bright_value(brightness),
        .reply_valid(reply_valid),.reply_data(reply_data),.reply_last(reply_last),.reply_ready(reply_ready),.uart_tx(uart_tx));
endmodule
