from pathlib import Path
root=Path(__file__).resolve().parents[1]
rtl=root/'src/user_source/rtl'
def edit(name,old,new):
 p=rtl/name;s=p.read_text(encoding='utf-8');assert old in s,(name,old);p.write_text(s.replace(old,new),encoding='utf-8')
edit('sd_spi_init.v','reg [21:0] startup_delay_cnt;','reg [31:0] startup_delay_cnt; // 50MHz下100ms需要23位；保留32位参数范围')
edit('sd_media_service.v','MAX_ACMD41_ATTEMPTS = 64','MAX_ACMD41_ATTEMPTS = 2048')
edit('thumbnail_cache_builder.v','    always @(posedge clk) if(row_write)', '    always @(posedge clk) if(state==WRITE) app_wr_data<=row[x];\n    always @(posedge clk) if(row_write)')
edit('thumbnail_cache_builder.v','app_wr_en<=0;app_wr_addr<=0;app_wr_data<=0;','app_wr_en<=0;app_wr_addr<=0;')
edit('thumbnail_cache_builder.v','app_wr_addr<=FRAME_WORDS*4+y*640+x;app_wr_data<=row[x];','app_wr_addr<=FRAME_WORDS*4+y*640+x;')
edit('media_video_pipeline.v','    assign transition_alpha=fade_alpha;','    wire wipe_active;\n    assign transition_alpha=fade_alpha;')
edit('media_video_pipeline.v','    wire wipe_active;\n    wire [4:0] wipe_ramp;','    wire [4:0] wipe_ramp;')
edit('media_hdmi_audio_bridge.v','    assign source_valid=mux_valid;\n    assign mux_ready=source_ready;\n    assign source_left=gain==255?mux_left:left_product>>>8;\n    assign source_right=gain==255?mux_right:right_product>>>8;','''    reg scaled_valid;
    reg signed [15:0] scaled_left,scaled_right;
    assign mux_ready=!scaled_valid || source_ready;
    assign source_valid=scaled_valid;
    assign source_left=scaled_left;
    assign source_right=scaled_right;
    // 接受样本时锁存增益结果，背压期间参数变化不能改变有效样本。
    always @(posedge pixel_clk or negedge pixel_rst_n)
        if(!pixel_rst_n) begin scaled_valid<=0;scaled_left<=0;scaled_right<=0;end
        else if(mux_ready) begin
            scaled_valid<=mux_valid;
            if(mux_valid) begin
                scaled_left<=gain==255?mux_left:left_product>>>8;
                scaled_right<=gain==255?mux_right:right_product>>>8;
            end
        end''')
edit('media_player_control.v','            end else if (next_event || previous_event) begin','''            end else if (!request_busy && image_complete!=0 && !image_complete[sys_current_index]) begin
                // PIC1缺失或损坏时，从已经完整加载的bank启动。
                issue_next_request();
            end else if (next_event || previous_event) begin''')
p=root/'src/user_source/hdl_source/top_tf_hdmi_audio.v';s=p.read_text(encoding='utf-8')
s=s.replace('96\'h4d4544494120504c41594552','"MEDIA PLAYER"')
s=s.replace('    seg7_panel u_panel','''    // 周期换算采用多拍减法，避免32位除法直接串到数码管IO。
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
    seg7_panel u_panel''').replace('.period_sec(period_ms/1000)','.period_sec(period_seconds)')
p.write_text(s,encoding='utf-8')
