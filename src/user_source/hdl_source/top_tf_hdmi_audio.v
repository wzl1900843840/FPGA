`timescale 1ns/1ps
// HX4S20C 单镜像媒体播放器。板上 K1复位/K2下一张/K3自动/K4参数。
// SW1缩略图模式，SW2参数调节模式，SW3选择对比度，SW4强制1kHz测试音。
// 默认使用普通FAT32图片卡与合成音调。制备匹配PCM镜像后才设置物理音频范围。
// WAV先用PC转换为48kHz/16bit/mono裸PCM；连续物理扇区范围由下列参数明确指定。
module top #(
    parameter [31:0] PCM_START_LBA=0,
    parameter [31:0] PCM_TOTAL_SECTORS=0,
    parameter integer DIAG_LOCAL_PATTERN=0
)(
    input wire clk,rst_n,key1,key2,key3,
    input wire [3:0] sw,
    input wire uart_rx,
    output wire uart_tx,
    output wire [7:0] seg_sel,seg_data,
    output wire HDMI_CLK_P,HDMI_D2_P,HDMI_D1_P,HDMI_D0_P,
    output wire HDMI_DDC_SCL,inout wire HDMI_DDC_SDA,
    output wire sd_ncs,sd_dclk,sd_mosi,input wire sd_miso,
    output wire flash_cs_n,flash_sclk,flash_mosi,flash_wp_n,flash_hold_n,
    input wire flash_miso
);
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

    // 单变量实板诊断：按住 K4(key2)，SW4=1，再释放 K1 复位。
    // 复位释放后仅采样一次，随后可松开 K4；正常复位自动退出。
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
            if(diag_boot_count!=63) begin
                diag_boot_count<=diag_boot_count+1'b1;
                if(diag_boot_count==62) begin
                    diag_local_sys<=DIAG_LOCAL_PATTERN || (!diag_key_sync[1] && diag_sw_sync[1]);
                    diag_fifo_sys<=!DIAG_LOCAL_PATTERN && !diag_key_sync[1] && diag_sw_sync[1] && diag_fifo_sw_sync[1];
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

    wire sdram_init,sdram_busy,sdram_refresh,rd_valid;
    wire [31:0] rd_data;
    wire init_sys,cdc_idle,cdc_idle_sys,cdc_full,cdc_overflow;
    sync_2ff u_init_sys(.clk(clk),.rst_n(sys_reset_n),.async_in(sdram_init),.sync_out(init_sys));
    sync_2ff u_idle_sys(.clk(clk),.rst_n(sys_reset_n),.async_in(cdc_idle),.sync_out(cdc_idle_sys));
    wire ingest_busy,ingest_done,card_ready;
    wire [2:0] ingest_stage;
    wire [7:0] ingest_error,ingest_detail;
    wire [3:0] resource_valid,image_complete,image_scale;
    wire source_wr;
    wire [20:0] source_addr;
    wire [3:0] source_mask;
    wire [31:0] source_data;
    reg ingest_start,player_enable;
    reg [2:0] boot_state;
    reg [7:0] drain_count;
    wire cache_done_sys,cache_start_mem,cache_failed_sys;
    reg cache_start;
    wire audio_req,audio_busy,audio_done,audio_valid;
    wire [31:0] audio_lba;
    wire [7:0] audio_byte,audio_error;
    wire [8:0] audio_byte_index;
    media_storage_ingest_top #(.SPI_CLK_DIV(4),.INIT_STARTUP_DELAY_CYCLES(5000000),.ALLOW_2X_SOURCE(1)) u_storage(
        .clk(clk),.rst_n(sys_reset_n),.start(ingest_start && !diag_local_sys),.busy(ingest_busy),.done(ingest_done),
        .error_stage(ingest_stage),.error_code(ingest_error),.error_detail(ingest_detail),
        .card_ready(card_ready),.card_high_capacity(),.resource_valid(resource_valid),
        .image_complete(image_complete),.image_scale_2x(image_scale),
        .controller_init_done(init_sys && !cdc_full),.controller_busy(1'b0),.refresh_active(1'b0),
        .app_wr_en(source_wr),.app_wr_addr(source_addr),.app_wr_mask(source_mask),.app_wr_data(source_data),
        .sd_cs_n(sd_ncs),.sd_sclk(sd_dclk),.sd_mosi(sd_mosi),.sd_miso(sd_miso),
        .audio_owner(player_enable),.audio_req(audio_req),.audio_lba(audio_lba),
        .audio_busy(audio_busy),.audio_done(audio_done),.audio_valid(audio_valid),
        .audio_byte(audio_byte),.audio_error(audio_error),.audio_byte_index(audio_byte_index));
    wire cdc_wr;
    wire [20:0] cdc_addr;
    wire [3:0] cdc_mask;
    wire [31:0] cdc_data;
    media_sdram_write_cdc u_write_cdc(.src_clk(clk),.src_rst_n(sys_reset_n),
        .src_wr_en(source_wr),.src_wr_addr(source_addr),.src_wr_mask(source_mask),.src_wr_data(source_data),
        .src_full(cdc_full),.src_overflow(cdc_overflow),.dst_clk(mem_clk),.dst_rst_n(mem_reset_n),
        .dst_app_wr_en(cdc_wr),.dst_app_wr_addr(cdc_addr),.dst_app_wr_mask(cdc_mask),
        .dst_app_wr_data(cdc_data),.dst_idle(cdc_idle),
        .controller_busy(sdram_busy),.refresh_active(sdram_refresh));
    always @(posedge clk or negedge sys_reset_n) begin
        if(!sys_reset_n) begin ingest_start<=0;player_enable<=0;boot_state<=0;drain_count<=0;cache_start<=0;end
        else begin
            ingest_start<=0;cache_start<=0;
            case(boot_state)
                0: if(init_sys && diag_boot_count==63 && !diag_local_sys) begin ingest_start<=1;boot_state<=1;end
                1: if(ingest_done) begin boot_state<=2;drain_count<=0;end
                2: if(cdc_idle_sys && !source_wr) begin
                    if(drain_count==255) begin cache_start<=1;boot_state<=3;end
                    else drain_count<=drain_count+1'b1;
                end else drain_count<=0;
                3: if(cache_done_sys) begin player_enable<=image_complete!=0 && !cdc_overflow && !cache_failed_sys;boot_state<=4;end
                default: ;
            endcase
        end
    end
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
    thumbnail_cache_builder u_cache(.clk(mem_clk),.rst_n(mem_reset_n),.start(cache_start_mem),
        .image_complete(complete_mem),.busy(cache_busy),.done(cache_done),.error(cache_error),
        .app_rd_en(cache_rd),.app_rd_addr(cache_rd_addr),.rd_valid(rd_valid),.rd_data(rd_data),
        .app_wr_en(cache_wr),.app_wr_addr(cache_wr_addr),.app_wr_data(cache_wr_data),
        .controller_busy(sdram_busy),.refresh_active(sdram_refresh));
    pulse_toggle_sync u_cache_done(.src_clk(mem_clk),.src_rst_n(mem_reset_n),.src_pulse(cache_done),
        .dst_clk(clk),.dst_rst_n(sys_reset_n),.dst_pulse(cache_done_sys));
    wire player_mem;
    sync_2ff u_player_mem(.clk(mem_clk),.rst_n(mem_reset_n),.async_in(player_enable),.sync_out(player_mem));
    wire video_rd;
    wire [20:0] video_rd_addr;
    sdram U3(.Clk(mem_clk),.Clk_sft(mem_clk_shift),.Rst(~mem_reset_n),
        .Sdr_init_done(sdram_init),.Sdr_init_ref_vld(sdram_refresh),.Sdr_busy(sdram_busy),
        .App_wr_en(!diag_local_mem && (cache_busy?cache_wr:cdc_wr)),.App_wr_addr(cache_busy?cache_wr_addr:cdc_addr),
        .App_wr_dm(cache_busy?4'd0:cdc_mask),.App_wr_din(cache_busy?cache_wr_data:cdc_data),
        .App_rd_en(!diag_local_mem && (player_mem?video_rd:cache_rd)),.App_rd_addr(player_mem?video_rd_addr:cache_rd_addr),
        .Sdr_rd_en(rd_valid),.Sdr_rd_dout(rd_data));

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
            sw_sync1<=sw;sw_sync2<=sw_sync1;
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
    sync_2ff u_view_sys(.clk(clk),.rst_n(sys_reset_n),.async_in(view_mode),.sync_out(view_sys));
    wire mode_update=auto_sys && !sw_sync2[1] && !view_sys;
    player_config_persistence u_config(.clk(clk),.rst_n(sys_reset_n),
        .cfg_update_valid((menu_update && !view_sys) || mode_update),.cfg_period_ms(menu_update?menu_period:period_ms),
        .cfg_volume(menu_update?menu_volume:volume),.cfg_mode(mode_update?{7'd0,~mode[0]}:mode),.save_request(save_event),
        .service_ready(cfg_ready),.busy(cfg_busy),.load_done(cfg_load_done),.save_done(cfg_save_done),
        .apply_valid(cfg_apply),.config_rejected(),.fatal_error(cfg_fatal),.error_code(cfg_error),
        .request_dropped(),.stored_config_valid(),.active_version(),.live_period_ms(period_ms),
        .live_period_cycles(period_cycles),.live_volume(volume),.live_mode(mode),
        .jedec_id(),.status1(),.status2(),.status3(),.flash_miso(flash_miso),
        .flash_cs_n(flash_cs_n),.flash_sclk(flash_sclk),.flash_mosi(flash_mosi),
        .flash_wp_n(flash_wp_n),.flash_hold_n(flash_hold_n));

    wire frame_start,next_pix,auto_pix,previous_pix,confirm_pix;
    pulse_toggle_sync u_next(.src_clk(clk),.src_rst_n(sys_reset_n),.src_pulse(next_sys && !sw_sync2[1]),
        .dst_clk(pixel_clk),.dst_rst_n(pix_reset_n),.dst_pulse(next_pix));
    pulse_toggle_sync u_auto(.src_clk(clk),.src_rst_n(sys_reset_n),.src_pulse(auto_sys && !sw_sync2[1]),
        .dst_clk(pixel_clk),.dst_rst_n(pix_reset_n),.dst_pulse(auto_pix));
    pulse_toggle_sync u_previous(.src_clk(clk),.src_rst_n(sys_reset_n),.src_pulse(previous_sys && !sw_sync2[1]),
        .dst_clk(pixel_clk),.dst_rst_n(pix_reset_n),.dst_pulse(previous_pix));
    pulse_toggle_sync u_confirm(.src_clk(clk),.src_rst_n(sys_reset_n),.src_pulse(menu_event && view_sys),
        .dst_clk(pixel_clk),.dst_rst_n(pix_reset_n),.dst_pulse(confirm_pix));
    wire [63:0] config_pix;
    frame_config_cdc #(.WIDTH(64),.RESET_VALUE({4'd0,4'd0,8'd128,8'd255,8'd255,32'd5000})) u_params(
        .src_clk(clk),.src_rst_n(sys_reset_n),.src_data({sw_sync2,3'd0,mode[0],contrast,brightness,volume,period_ms}),
        .dst_clk(pixel_clk),.dst_rst_n(pix_reset_n),.frame_start(frame_start),.dst_data(config_pix));
    wire [7:0] contrast_pix=config_pix[55:48],bright_pix=config_pix[47:40],volume_pix=config_pix[39:32];
    wire [3:0] switches_pix=config_pix[63:60];
    reg mode_seen;
    wire [1:0] focus_index,selected_index;
    wire thumb_transition,thumbnail_select;
    wire [3:0] complete_pix;
    genvar k;
    generate for(k=0;k<4;k=k+1) begin:g_complete
        sync_2ff u_sync(.clk(pixel_clk),.rst_n(pix_reset_n),.async_in(image_complete[k]),.sync_out(complete_pix[k]));
    end endgenerate
    always @(posedge pixel_clk or negedge pix_reset_n)
        if(!pix_reset_n) mode_seen<=0;else mode_seen<=switches_pix[0];
    thumbnail_controller u_thumbnail(.clk(pixel_clk),.rst_n(pix_reset_n),
        .key_right(next_pix),.key_left(auto_pix),.key_confirm(confirm_pix),
        .key_mode((switches_pix[0] && !mode_seen) || (!switches_pix[0] && mode_seen && view_mode)),.image_complete(complete_pix),.frame_start(frame_start),
        .view_mode(view_mode),.focus_index(focus_index),.active_index(selected_index),.transition_req(thumb_transition),
        .selection_committed(thumbnail_select));
    wire hs,vs,de;
    wire [23:0] video_rgb;
    wire [9:0] video_x,video_y;
    wire [1:0] active_index;
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
    // 控制逻辑同像素域运行，周期从毫秒换算为25MHz周期；手动/自动统一帧边界提交。
    media_video_pipeline #(.RUNTIME_DIAG(1),.FADE_FRAMES(16),.ENABLE_COLOR_ADJUST(1),.DEFAULT_PERIOD_CYCLES(125000000),
        .MIN_PERIOD_CYCLES(25000000),.MAX_PERIOD_CYCLES(1500000000)) u_video(
        .diag_fifo_pix(diag_fifo_pix),.diag_fifo_mem(diag_fifo_mem),
        .ctrl_clk(pixel_clk),.ctrl_rst_n(pix_reset_n),.next_event(next_pix && !display_view),
        .previous_event(previous_pix && !display_view),.select_valid(thumbnail_select),
        .select_index(selected_index),.view_mode(display_view),.mode_transition(display_view!=last_display_view),.focus_index(focus_index),
        .transition_alpha(fade_alpha),.transition_active(fade_active),.video_y(video_y),
        .toggle_auto_event(1'b0),.period_cfg_valid(last_period!=config_pix[31:0]),
        .period_cfg_cycles(config_pix[31:0]*32'd25000),.auto_cfg_valid(display_view || last_display_view!=display_view || last_cfg_mode!=config_pix[56]),.auto_cfg_enabled(config_pix[56] && !display_view),
        .image_complete(complete_pix),.player_enable(diag_fifo_pix || (player_enable && !diag_local_pix)),.mem_clk(mem_clk),.mem_rst_n(mem_reset_n),
        .controller_init_done(sdram_init && player_mem),.controller_busy(sdram_busy),.refresh_active(sdram_refresh),
        .app_rd_en(video_rd),.app_rd_addr(video_rd_addr),.sdram_rd_valid(rd_valid && player_mem && !diag_local_mem),.sdram_rd_data(rd_data),
        .brightness(bright_pix),.contrast(contrast_pix),.pix_clk(pixel_clk),.pix_rst_n(pix_reset_n),.video_clk(),.video_hs(hs),.video_vs(vs),
        .video_de(de),.video_rgb(video_rgb),.video_x(video_x),.active_index(active_index),.pending_index(),
        .auto_enabled(auto_enabled),.frame_start(frame_start),.reader_busy(),.reader_underflow(),.video_error(video_error));

    wire de_adjust=de;
    wire [23:0] adjusted_rgb=video_rgb;
    wire hs_adjust=hs,vs_adjust=vs;
    wire [9:0] x_adjust=video_x,y_adjust=video_y;
    wire thumb_de,focus_border;
    thumbnail_layout u_layout(.in_de(de_adjust),.pixel_x({2'd0,x_adjust}),.pixel_y({2'd0,y_adjust}),
        .focus_index(focus_index),.image_complete(complete_pix),.thumb_de(thumb_de),.source_index(),
        .source_x(),.source_y(),.focus_border(focus_border));
    wire [23:0] focus_rgb=(display_view && focus_border)?24'hffff00:adjusted_rgb;
    wire [23:0] status_rgb,detail_rgb,timestamp_rgb,text_rgb,final_rgb;
    wire [7:0] system_error=cdc_overflow?8'h86:cache_failed_sys?8'h85:
        ingest_error!=0?ingest_error:audio_error!=0?{4'h9,audio_error[3:0]}:cfg_error;
    wire [7:0] display_error=video_error!=0?video_error:system_error;
    osd_overlay_24 u_status(.clk(pixel_clk),.rst_n(pix_reset_n),.vsync(vs_adjust),.de(de_adjust),
        .rgb_in(focus_rgb),.pixel_x(x_adjust),.active_index(active_index),.auto_enabled(auto_enabled),
        .error_code(display_error),.rgb_out(status_rgb),.de_out(),.osd_active());
    wire [7:0] detail_pix;
    frame_config_cdc #(.WIDTH(8)) u_error_detail_commit(.src_clk(clk),.src_rst_n(sys_reset_n),
        .src_data(ingest_detail),.dst_clk(pixel_clk),.dst_rst_n(pix_reset_n),
        .frame_start(frame_start),.dst_data(detail_pix));
    // 显示 D xx 细分码；80只能说明扫描失败，不能区分格式/文件名/扇区错误。
    osd_overlay_24 #(.OSD_X(48),.DETAIL_MODE(1)) u_error_detail(
        .clk(pixel_clk),.rst_n(pix_reset_n),.vsync(vs_adjust),.de(de_adjust),
        .rgb_in(status_rgb),.pixel_x(x_adjust),.active_index(2'd0),.auto_enabled(1'b0),
        .error_code(detail_pix),.rgb_out(detail_rgb),.de_out(),.osd_active());
    wire [7:0] rx_data;
    wire rx_valid,rx_error,subtitle_commit,subtitle_enable;
    wire [95:0] subtitle_text;
    wire [5:0] subtitle_length;
    wire reply_valid,reply_ready,reply_last,subtitle_save;
    wire [7:0] reply_data;
    uart_rx_byte u_rx(.clk(clk),.rst_n(sys_reset_n),.rx(uart_rx),.data(rx_data),.valid(rx_valid),.framing_error(rx_error));
    reg [95:0] live_text;
    reg [5:0] live_length;
    reg live_subtitle;
    always @(posedge clk or negedge sys_reset_n)
        if(!sys_reset_n) begin live_text<=96'h524559414c5020414944454d;live_length<=12;live_subtitle<=1;end
        else if(subtitle_commit) begin live_text<=subtitle_text;live_length<=subtitle_length;live_subtitle<=subtitle_enable;end
    subtitle_uart_controller u_subtitle_uart(.clk(clk),.rst_n(sys_reset_n),.rx_data(rx_data),.rx_valid(rx_valid),
        .rx_framing_error(rx_error),.service_ready(1'b1),.save_done(1'b0),.save_failed(subtitle_save),
        .request_dropped(1'b0),.live_text(live_text),.live_length(live_length),.live_enable(live_subtitle),
        .cfg_update_valid(subtitle_commit),.cfg_text(subtitle_text),.cfg_length(subtitle_length),.cfg_enable(subtitle_enable),
        .save_request(subtitle_save),.reply_valid(reply_valid),.reply_data(reply_data),.reply_last(reply_last),.reply_ready(reply_ready));
    wire [102:0] subtitle_pix;
    frame_config_cdc #(.WIDTH(103),.RESET_VALUE({1'b1,6'd12,96'h524559414c5020414944454d})) u_subtitle_frame_commit(
        .src_clk(clk),.src_rst_n(sys_reset_n),.src_data({live_subtitle,live_length,live_text}),
        .dst_clk(pixel_clk),.dst_rst_n(pix_reset_n),.frame_start(frame_start),.dst_data(subtitle_pix));
    timestamp_osd u_timestamp(.pix_clk(pixel_clk),.pix_rst_n(pix_reset_n),.enable(1'b1),
        .vsync(vs_adjust),.de(de_adjust),.pixel_x(x_adjust),.pixel_y({2'd0,y_adjust}),
        .rgb_in(detail_rgb),.rgb_out(timestamp_rgb),.ts_active(),.sys_rst_n(sys_reset_n));
    promax_text_overlay u_text(.clk(pixel_clk),.rst_n(pix_reset_n),.vsync(vs_adjust),.de(de_adjust),
        .rgb_in(timestamp_rgb),.pixel_x(x_adjust),.enable(1'b1),.subtitle_enable(subtitle_pix[102]),
        .subtitle_text(subtitle_pix[95:0]),.subtitle_length(subtitle_pix[101:96]),.brightness(bright_pix),
        .contrast(contrast_pix),.volume(volume_pix),.period_ms(config_pix[31:0]),.auto_enabled(auto_enabled),
        .source_scale_2x(image_scale[active_index]),.rgb_out(text_rgb),.overlay_active());
    wire pcm_tap_valid;
    wire signed [15:0] pcm_tap_left;
    promax_audio_waveform u_wave(.clk(pixel_clk),.rst_n(pix_reset_n),.vsync(vs_adjust),.de(de_adjust),
        .rgb_in(text_rgb),.pixel_x(x_adjust),.enable(1'b1),.pcm_tap_valid(pcm_tap_valid),
        .pcm_tap_left(pcm_tap_left),.rgb_out(final_rgb),.waveform_active());

    wire sample_tick,wav_valid,wav_ready,wav_active;
    wire signed [15:0] wav_sample;
    wav_stream_player u_wav(.wr_clk(clk),.wr_rst_n(sys_reset_n),
        .play_enable(player_enable && PCM_START_LBA!=0 && PCM_TOTAL_SECTORS!=0),
        .start_lba(PCM_START_LBA),.total_sectors(PCM_TOTAL_SECTORS),.sd_req(audio_req),.sd_lba(audio_lba),
        .sd_busy(audio_busy),.sd_valid(audio_valid),.sd_byte(audio_byte),.sd_byte_index(audio_byte_index),
        .sd_done(audio_done),.sd_error(audio_error),.rd_clk(pixel_clk),.rd_rst_n(pix_reset_n),
        .sample_tick(sample_tick),.sample_out(wav_sample),.sample_valid(wav_valid),.sample_ready(wav_ready),
        .sample_counter(),.stream_active(wav_active),.stream_end(),.buffer_low());
    wire [7:0] fade_gain;
    sync_fade_gain u_gain(.pix_clk(pixel_clk),.pix_rst_n(pix_reset_n),.frame_start(frame_start),
        .alpha_pix(fade_alpha),.fade_active(fade_active),.aud_clk(pixel_clk),.aud_rst_n(pix_reset_n),.gain_aud(fade_gain));
    // 与最终视频同拍的坐标，直接进入既有 HDMI 编码/串行链路。
    // 上半屏 8 色条；第三个 120 行灰阶；最后 120 行逐位彩色渐变+棋盘格。
    // 诊断绕过颜色调节、转场和全部叠加层，完全不使用 reader_rgb。
    reg [23:0] diag_rgb;
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
    wire [23:0] hdmi_input_rgb=diag_local_pix?(diag_fifo_pix?video_rgb:diag_rgb):final_rgb;
    wire [9:0] ch0,ch1,ch2;
    media_hdmi_audio_bridge u_audio(.pixel_clk(pixel_clk),.pixel_rst_n(pix_reset_n),
        .video_hsync(hs_adjust),.video_vsync(vs_adjust),.video_de(de_adjust),.video_x(x_adjust),.video_rgb(hdmi_input_rgb),
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
