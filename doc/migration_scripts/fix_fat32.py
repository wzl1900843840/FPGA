from pathlib import Path
R=Path(__file__).resolve().parents[1]/'src/user_source/rtl'
p=R/'fat32_volume_scanner.v';t=p.read_text(encoding='utf-8-sig')
t=t.replace('    reg [3:0] state;', '''    localparam ST_ROOT_FAT_REQ=4'd12, ST_ROOT_FAT_WAIT=4'd13, ST_ROOT_FAT_PARSE=4'd14;
    reg [7:0] root_sector_offset;
    reg [10:0] root_cluster_count;
    reg root_end;
    wire [31:0] next_root_cluster=le32({root_cluster[6:0],2'b00}) & 32'h0fffffff;
    reg [3:0] state;''')
t=t.replace("root_cluster <= 32'd0;", "root_cluster <= 32'd0; root_sector_offset<=0;root_cluster_count<=0;root_end<=0;")
t=t.replace('dir_name0 <= sector_byte;', "dir_name0 <= sector_byte;\n                        if(sector_byte==0) root_end<=1;")
t=t.replace("sector_byte == 8'h20 &&", "!root_end && (sector_byte & 8'h18)==0 &&")
t=t.replace('if (dir_entry_match) begin','if (dir_entry_match && {dir_cluster_high,dir_cluster_low}>=2 &&\n                            {dir_cluster_high,dir_cluster_low}<=max_cluster && {sector_byte,dir_file_size[23:0]}!=0) begin')
t=t.replace('state <= ST_READ0_REQ;', 'state <= ST_READ0_REQ; root_sector_offset<=0;root_cluster_count<=0;root_end<=0;')
t=t.replace('''                    data_start_lba <= partition_lba + reserved_sectors + fat_span;
                    data_sector_count <= total_sectors - reserved_sectors - fat_span;
                    state <= ST_BOOT_ROOT;''','''                    if(total_sectors<=reserved_sectors+fat_span) finish_with_error(ERR_UNSUPPORTED_BPB);
                    else begin
                        data_start_lba <= partition_lba + reserved_sectors + fat_span;
                        data_sector_count <= total_sectors - reserved_sectors - fat_span;
                        state <= ST_BOOT_ROOT;
                    end''')
t=t.replace("ST_ROOT_REQ: if (!sector_busy) begin\n                    resource_valid <= 4'd0;",'ST_ROOT_REQ: if (!sector_busy) begin')
t=t.replace('''                    else
                        finish_with_error(ERR_RESOURCE_MISSING);
                end
                ST_FINISH:''','''                    else if(root_end) finish_with_error(ERR_RESOURCE_MISSING);
                    else if(root_sector_offset+1<sectors_per_cluster) begin
                        root_sector_offset<=root_sector_offset+1'b1;
                        sector_lba<=root_lba+root_sector_offset+1'b1;
                        state<=ST_ROOT_REQ;
                    end else begin
                        sector_lba<=fat_start_lba+(root_cluster>>7);
                        state<=ST_ROOT_FAT_REQ;
                    end
                end
                ST_ROOT_FAT_REQ: if(!sector_busy) begin sector_req<=1;state<=ST_ROOT_FAT_WAIT;end
                ST_ROOT_FAT_WAIT: if(sector_done) begin
                    if(sector_error!=0) finish_with_error(ERR_SECTOR);
                    else state<=ST_ROOT_FAT_PARSE;
                end
                ST_ROOT_FAT_PARSE: begin
                    if(next_root_cluster>=32'h0ffffff8) finish_with_error(ERR_RESOURCE_MISSING);
                    else if(next_root_cluster<2 || next_root_cluster>max_cluster ||
                            next_root_cluster==root_cluster || root_cluster_count==1023)
                        finish_with_error(ERR_UNSUPPORTED_BPB);
                    else begin
                        root_cluster<=next_root_cluster;
                        root_cluster_count<=root_cluster_count+1'b1;root_sector_offset<=0;
                        root_lba<=data_start_lba+((next_root_cluster-2)<<sectors_per_cluster_shift);
                        sector_lba<=data_start_lba+((next_root_cluster-2)<<sectors_per_cluster_shift);
                        state<=ST_ROOT_REQ;
                    end
                end
                ST_FINISH:''')
p.write_text(t,encoding='utf-8')
# 缩略图坐标中间变量是组合临时量，必须每条路径赋值。
p=R/'thumbnail_layout.v';t=p.read_text(encoding='utf-8-sig').replace('    always @* begin','    always @* begin\n        window_x=0;window_y=0;local_x=0;local_y=0;');p.write_text(t,encoding='utf-8')
# 两个写分支合成到同一 RAM 端口，避免行缓冲展开成20480个FF。
p=R/'thumbnail_cache_builder.v';t=p.read_text(encoding='utf-8-sig')
t=t.replace('reg [31:0] row [0:639];','reg [31:0] row [0:639] /* fehdl force_ram=1, ram_style="bram" */;')
t=t.replace('                row[x]<=0;','')
t=t.replace('                if(received[1:0]==0) row[(side?160:0)+(received>>2)]<=rd_data;','')
t=t.replace('    assign busy=state!=IDLE;', '''    assign busy=state!=IDLE;
    wire row_write=state==CLEAR || ((state==READ || state==DRAIN) && rd_valid && received<640 && received[1:0]==0);
    wire [9:0] row_address=state==CLEAR ? x : (side?160:0)+(received>>2);
    always @(posedge clk) if(row_write) row[row_address]<=state==CLEAR ? 32'd0:rd_data;''')
p.write_text(t,encoding='utf-8')
