from pathlib import Path
R=Path(__file__).resolve().parents[1]/'src/user_source/rtl'
p=R/'media_frame_loader.v';t=p.read_text(encoding='utf-8-sig')
t=t.replace('input  wire [23:0]           pixel_rgb,','input  wire [23:0]           pixel_rgb,\n    input wire source_top_down,')
t=t.replace('reg active;', 'reg [9:0] write_column;\n    reg [8:0] write_row;\n    reg active;')
t=t.replace("pixels_written <= 32'd0;", "pixels_written <= 32'd0;\n                write_column<=0;write_row<=0;")
t=t.replace('app_wr_addr <= bank_base(active_image) + pixels_written[ADDR_WIDTH-1:0];', '''app_wr_addr <= bank_base(active_image) +
                            (source_top_down ? write_row : 479-write_row)*640 + write_column;
                        if(write_column==639) begin write_column<=0;write_row<=write_row+1'b1;end
                        else write_column<=write_column+1'b1;''')
# 使用IMAGE_WORDS的小尺寸仿真也必须保持线性（仅完整生产帧翻转）。
t=t.replace('(source_top_down ? write_row : 479-write_row)*640 + write_column;', '''(IMAGE_WORDS==307200 ?
                            (source_top_down ? write_row : 479-write_row)*640 + write_column :
                            pixels_written[ADDR_WIDTH-1:0]);''')
p.write_text(t,encoding='utf-8')
p=R/'media_ingest_pipeline.v';t=p.read_text(encoding='utf-8-sig')
t=t.replace('wire source_scale_2x;', 'wire source_scale_2x;\n    wire source_top_down;\n    reg [1:0] retry_count;')
t=t.replace('.top_down(),', '.top_down(source_top_down),')
t=t.replace('.pixel_valid(pixel_valid), .pixel_rgb(pixel_rgb), .frame_commit(frame_commit),', '.pixel_valid(pixel_valid), .pixel_rgb(pixel_rgb), .source_top_down(source_top_down), .frame_commit(frame_commit),')
t=t.replace('current_image <= 2\'d0;', "current_image <= 2'd0; retry_count<=0;")
t=t.replace('if (scan_error != 0) begin','if (scan_error != 0 && !(scan_error==8\'h22 && resource_valid!=0)) begin')
t=t.replace('ST_FILE_START: begin\n                    file_start', '''ST_FILE_START: if(!resource_valid[current_image]) begin
                    if(current_image==3) begin done<=1;state<=ST_IDLE;end
                    else current_image<=current_image+1'b1;
                end else begin
                    file_start''')
t=t.replace("current_image <= current_image + 1'b1;", "current_image <= current_image + 1'b1; retry_count<=0;")
t=t.replace('''ST_FAIL_WAIT: if (!scan_busy && !file_busy && !load_busy) begin
                    done <= 1'b1;
                    state <= ST_IDLE;
                end''','''ST_FAIL_WAIT: if (!scan_busy && !file_busy && !load_busy) begin
                    // 文件读取排空后有限重试；坏图跳过，已完成 bank 不受影响。
                    if(ingest_error==ERR_SCAN) begin done<=1;state<=ST_IDLE;end
                    else if(retry_count<2) begin retry_count<=retry_count+1'b1;state<=ST_FILE_START;end
                    else if(current_image==3) begin done<=1;state<=ST_IDLE;end
                    else begin current_image<=current_image+1'b1;retry_count<=0;state<=ST_FILE_START;end
                end''')
p.write_text(t,encoding='utf-8')
