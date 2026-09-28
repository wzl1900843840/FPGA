from pathlib import Path
R=Path(__file__).resolve().parents[1]/'src/user_source/rtl'
p=R/'media_player_control.v';t=p.read_text(encoding='utf-8-sig')
t=t.replace('input  wire        next_event,','''input  wire        next_event,
    input  wire        previous_event,
    input  wire        select_valid,
    input  wire [1:0]  select_index,''')
t=t.replace('candidate = current + step[1:0];','candidate = previous_event ? current - step[1:0] : current + step[1:0];')
t=t.replace('if (next_event) begin','''if (select_valid && !request_busy && image_complete[select_index]) begin
                pending_index <= select_index;
                request_toggle <= ~request_toggle;
                auto_counter <= 0;
            end else if (next_event || previous_event) begin''')
# 参数更新拍不允许后续自动计数分支覆盖计数器清零。
t=t.replace('end else if (auto_enabled) begin','end else if (period_cfg_valid || auto_cfg_valid || toggle_auto_event) begin\n                auto_counter <= 0;\n            end else if (auto_enabled) begin')
p.write_text(t,encoding='utf-8')
p=R/'media_video_pipeline.v';t=p.read_text(encoding='utf-8-sig')
t=t.replace('input  wire        next_event,','''input  wire        next_event,
    input  wire        previous_event,
    input  wire        select_valid,
    input  wire [1:0]  select_index,
    input  wire        view_mode,
    input  wire [1:0]  focus_index,
    output wire [7:0]  transition_alpha,
    output wire        transition_active,
    output wire [9:0]  video_y,''')
t=t.replace('reg [9:0] video_x_q;', 'reg [9:0] video_x_q;\n    reg [9:0] video_y_q;\n    assign video_y=video_y_q;')
t=t.replace("video_x_q <= 10'd0;", "begin video_x_q <= 10'd0; video_y_q<=0; end")
t=t.replace('video_x_q <= active_x[9:0];','begin video_x_q <= active_x[9:0];\n                video_y_q <= raw_y >= V_FP+V_SYNC+V_BP ? raw_y-(V_FP+V_SYNC+V_BP) : 0; end')
t=t.replace('wire [7:0] fade_alpha;','wire [7:0] fade_alpha;\n    assign transition_alpha=fade_alpha;\n    assign transition_active=(fade_alpha!=255) || wipe_active;')
t=t.replace('.next_event(fade_next_event), .toggle_auto_event(toggle_auto_event),', '''.next_event(fade_next_event), .previous_event(previous_event),
        .select_valid(select_valid), .select_index(select_index),
        .toggle_auto_event(toggle_auto_event),''')
t=t.replace('    media_frame_reader #(','''    // 缩略图合成缓存位于四个原图 bank 之后，仍沿用同一个 burst reader。
    wire [20:0] reader_address;
    wire thumb_mem;
    sync_2ff u_thumb_mem(.clk(mem_clk),.rst_n(mem_rst_n),.async_in(view_mode),.sync_out(thumb_mem));
    assign app_rd_addr=reader_address + (thumb_mem ? IMAGE_WORDS*4 : 0);
    media_frame_reader #(''')
t=t.replace('.app_rd_en(app_rd_en), .app_rd_addr(app_rd_addr),','.app_rd_en(app_rd_en), .app_rd_addr(reader_address),')
t=t.replace('.active_index(active_index),\n        .pixel_consume',".active_index(view_mode ? 2'd0 : active_index),\n        .pixel_consume")
t=t.replace('wire [7:0] eff_alpha = ({8\'d0, fade_alpha} * (brightness + 8\'d1)) >> 8;', '''wire [16:0] alpha_product = {1'b0,fade_alpha} * ({1'b0,brightness}+9'd1);
            wire [7:0] eff_alpha = brightness==255 ? fade_alpha : alpha_product[15:8];''')
t=t.replace('{fade_mul_r[15:8], fade_mul_g[15:8], fade_mul_b[15:8]};','eff_alpha==255 ? selected_rgb :\n                {fade_mul_r[15:8], fade_mul_g[15:8], fade_mul_b[15:8]};')
# 视频时序必须持续；player_enable 只门控 RGB 及取数，不能使 HDMI active-video 消失。
t=t.replace('.de_in(raw_de && player_enable_pix)', '.de_in(raw_de)')
p.write_text(t,encoding='utf-8')
