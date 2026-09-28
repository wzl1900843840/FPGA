from pathlib import Path
root=Path(__file__).resolve().parents[1];rtl=root/'src/user_source/rtl'
def edit(n,a,b):
 p=rtl/n;s=p.read_text(encoding='utf-8');assert a in s,(n,a);p.write_text(s.replace(a,b),encoding='utf-8')
edit('media_frame_loader.v','    always @(posedge clk or negedge rst_n) begin','''    // 独立同步读写过程，无异步清零数据寄存器，确保推断双口BRAM。
    wire transfer_ok=decode_error==0 && !(pixel_valid && pixels_received>=IMAGE_WORDS) && !(pixel_valid && !push_allowed);
    always @(posedge clk) begin
        if(push_allowed && transfer_ok) fifo_mem[wr_ptr]<={8'h00,pixel_rgb};
        if(pop_allowed && transfer_ok) app_wr_data<=fifo_mem[rd_ptr];
    end
    always @(posedge clk or negedge rst_n) begin''')
edit('media_frame_loader.v','            app_wr_data <= 32\'d0;','')
edit('media_frame_loader.v','                        fifo_mem[wr_ptr] <= {8\'h00, pixel_rgb};','')
edit('media_frame_loader.v','                        app_wr_data <= fifo_mem[rd_ptr];','')
edit('sd_sector_replay_buffer.v','    always @(posedge clk or negedge rst_n) begin','''    always @(posedge clk) begin
        if(state==ST_CAPTURE && reader_valid && current_byte_in_order) sector_mem[reader_byte_index]<=reader_byte;
        if(state==ST_REPLAY) sector_byte<=sector_mem[replay_index];
    end
    always @(posedge clk or negedge rst_n) begin''')
edit('sd_sector_replay_buffer.v','            sector_byte <= 8\'d0;','')
edit('sd_sector_replay_buffer.v','                        if (current_byte_in_order)\n                            sector_mem[reader_byte_index] <= reader_byte;\n                        else','                        if (!current_byte_in_order)')
edit('sd_sector_replay_buffer.v','                    sector_byte <= sector_mem[replay_index];','')
p=rtl/'timestamp_osd.v';s=p.read_text(encoding='utf-8');a=s.index('    // frame counter');b=s.index('    // pixel offset',a)
s=s[:a]+'''    // 25MHz / (800*525) = 59.5238Hz；以像素周期累加，不能用60帧冒充1秒。
    reg [24:0] frame_cycles;
    reg [3:0] mm_tens,mm_ones,ss_tens,ss_ones;
    reg vs_q;
    wire frame_start=vs_q && !vsync;
    always @(posedge pix_clk or negedge pix_rst_n)
        if(!pix_rst_n) begin
            frame_cycles<=0;mm_tens<=0;mm_ones<=0;ss_tens<=0;ss_ones<=0;vs_q<=1;
        end else begin
            vs_q<=vsync;
            if(frame_start) begin
                if(frame_cycles>=25000000-420000) begin
                    frame_cycles<=frame_cycles+420000-25000000;
                    if(ss_ones!=9) ss_ones<=ss_ones+1'b1;
                    else begin ss_ones<=0;
                        if(ss_tens!=5) ss_tens<=ss_tens+1'b1;
                        else begin ss_tens<=0;
                            if(mm_ones!=9) mm_ones<=mm_ones+1'b1;
                            else begin mm_ones<=0;mm_tens<=mm_tens==9?0:mm_tens+1'b1;end
                        end
                    end
                end else frame_cycles<=frame_cycles+420000;
            end
        end

'''+s[b:];p.write_text(s,encoding='utf-8')
edit('promax_text_overlay.v','    input  wire [7:0]  brightness,','    input wire [7:0] contrast,\n    input  wire [7:0]  brightness,')
edit('promax_text_overlay.v','PARAM_CHARS = 32','PARAM_CHARS = 36')
edit('promax_text_overlay.v','    reg [7:0] brightness_frame;','    reg [7:0] contrast_frame;\n    reg [7:0] brightness_frame;')
edit('promax_text_overlay.v',"            brightness_frame <= 8'd255;","            contrast_frame <= 8'd128;\n            brightness_frame <= 8'd255;")
edit('promax_text_overlay.v','                brightness_frame <= brightness;','                contrast_frame <= contrast;\n                brightness_frame <= brightness;')
p=rtl/'promax_text_overlay.v';s=p.read_text(encoding='utf-8');a=s.index('            case (brightness_frame)');b=s.index('            if (period_frame',a)
s=s[:a]+"            bright_percent = brightness_frame; // 显示实际0..255参数，避免非预设档位误报\n"+s[b:]
s=s.replace('                default: param_char = " ";','''                30:param_char="C";31:param_char="T";
                32:param_char=decimal_hundreds(contrast_frame);
                33:param_char=decimal_tens(contrast_frame);
                34:param_char=decimal_ones(contrast_frame);
                default: param_char = " ";''');p.write_text(s,encoding='utf-8')
edit('player_config_persistence.v',"                ST_ERROR: service_ready <= 1'b0;",'''                ST_ERROR: begin
                    // Flash型号/保护检查失败后仍允许RAM参数调节；禁止写操作。
                    service_ready<=1'b0;
                    if(cfg_update_valid && config_fields_valid(cfg_period_ms,cfg_mode))
                        apply_config(cfg_period_ms,cfg_volume,cfg_mode);
                end''')
p=root/'src/user_source/hdl_source/top_tf_hdmi_audio.v';s=p.read_text(encoding='utf-8')
s=s.replace('"MEDIA PLAYER"',"96'h"+b'MEDIA PLAYER'[::-1].hex())
s=s.replace('.service_ready(cfg_ready),\n        .live_volume','.service_ready(cfg_ready || cfg_fatal),\n        .live_volume')
s=s.replace('wire [23:0] status_rgb,text_rgb,final_rgb;','wire [23:0] status_rgb,timestamp_rgb,text_rgb,final_rgb;')
s=s.replace('    promax_text_overlay u_text','''    timestamp_osd u_timestamp(.pix_clk(pixel_clk),.pix_rst_n(pix_reset_n),.enable(1'b1),
        .vsync(vs_adjust),.de(de_adjust),.pixel_x(x_adjust),.pixel_y({2'd0,y_adjust}),
        .rgb_in(status_rgb),.rgb_out(timestamp_rgb),.ts_active(),.sys_rst_n(sys_reset_n));
    promax_text_overlay u_text''').replace('.rgb_in(status_rgb),.pixel_x','.rgb_in(timestamp_rgb),.pixel_x').replace('.volume(volume_pix),.period_ms','.contrast(contrast_pix),.volume(volume_pix),.period_ms')
p.write_text(s,encoding='utf-8')
