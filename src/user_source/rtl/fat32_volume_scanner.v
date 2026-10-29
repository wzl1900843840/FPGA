`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// FAT32 卷扫描器：在卡上找到 PIC1~PIC5 五个文件，并给出它们的簇链起点。
// PIC5 是可选的紧急页面；PIC1~PIC4 仍是正常播放所需的资源。
//
// 干什么（一次扫描）：
//   1) 读 LBA0，看它是不是分区表(MBR)：是就取出第一个分区起始LBA；
//      不是就直接把 LBA0 当引导扇区（superfloppy 布局的卡，演示镜像就是这种）；
//   2) 解析引导扇区 BPB：每簇扇区数、保留扇区数、FAT个数/大小、根目录位置等，
//      并用这些算出 FAT 表起始LBA、数据区起始LBA、最大簇号；
//   3) 从根目录开始逐条读目录项（每条32字节），按文件名匹配 PIC1.BMP~PIC5.BMP，
//      记录各自的起始簇号和文件大小；
//   4) 根目录如果跨了多个扇区/簇，还要顺着 FAT 表找下一个簇继续扫。
//
// 关键设计：按固定偏移流式采集BPB字段和MBR候选，不保存整扇区。
// 分区项按卡上顺序处理，保留首个有效FAT32分区；目录与FAT也流式解析。
//
// 对外结果：resource_valid[4:0] 表示哪几张图找到了（注意：找到 ≠ 内容正确），
// resourceN_cluster/size 给后面的读取器用；fs_error 是错误码
// （10=读扇区失败，20=引导扇区签名不对，21=BPB不支持，22=没找到约定文件）。
// -----------------------------------------------------------------------------
module fat32_volume_scanner (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        scan_start,
    output wire        scan_busy,
    output reg         scan_done,
    output reg  [7:0]  fs_error,
    output reg  [31:0] partition_lba,
    output reg  [7:0]  sectors_per_cluster,
    output reg  [31:0] fat_start_lba,
    output reg  [31:0] data_start_lba,
    output reg  [31:0] max_cluster,
    output reg  [4:0]  resource_valid,
    output reg  [31:0] resource0_cluster,
    output reg  [31:0] resource1_cluster,
    output reg  [31:0] resource2_cluster,
    output reg  [31:0] resource3_cluster,
    output reg  [31:0] resource4_cluster,
    output reg  [31:0] resource0_size,
    output reg  [31:0] resource1_size,
    output reg  [31:0] resource2_size,
    output reg  [31:0] resource3_size,
    output reg  [31:0] resource4_size,
    output reg         sector_req,
    output reg  [31:0] sector_lba,
    input  wire        sector_busy,
    input  wire        sector_valid,
    input  wire [7:0]  sector_byte,
    input  wire [8:0]  sector_byte_index,
    input  wire        sector_done,
    input  wire [7:0]  sector_error
);

    // 错误码：10=读扇区失败 20=引导扇区签名错 21=BPB不支持 22=没找到PIC文件
    localparam ERR_NONE            = 8'h00;
    localparam ERR_SECTOR          = 8'h10;
    localparam ERR_BOOT_SIGNATURE  = 8'h20;
    localparam ERR_UNSUPPORTED_BPB = 8'h21;
    localparam ERR_RESOURCE_MISSING= 8'h22;

    // 状态机：先判断分区表/引导扇区，再解析BPB，最后扫根目录找文件
    localparam ST_IDLE       = 4'd0;
    localparam ST_READ0_REQ  = 4'd1;
    localparam ST_READ0_WAIT = 4'd2;
    localparam ST_BOOT_PARSE = 4'd3;
    localparam ST_BOOT_REQ   = 4'd4;
    localparam ST_BOOT_WAIT  = 4'd5;
    localparam ST_ROOT_REQ   = 4'd6;
    localparam ST_ROOT_WAIT  = 4'd7;
    localparam ST_DIR_SCAN   = 4'd8;
    localparam ST_FINISH     = 4'd9;
    localparam ST_BOOT_LAYOUT= 4'd10;
    localparam ST_BOOT_ROOT  = 4'd11;

    localparam ST_ROOT_FAT_REQ=4'd12, ST_ROOT_FAT_WAIT=4'd13, ST_ROOT_FAT_PARSE=4'd14;
    reg [7:0] root_sector_offset;
    reg [10:0] root_cluster_count;
    reg root_end;
    reg [31:0] root_cluster;
    reg [31:0] root_fat_entry;
    wire [8:0] root_fat_offset={root_cluster[6:0],2'b00};
    wire [31:0] next_root_cluster=root_fat_entry & 32'h0fffffff;
    reg [3:0] state;
    reg [7:0] boot_jump, bpb_spc, bpb_fats, signature_low, signature_high;
    reg [15:0] bpb_bytes, bpb_reserved, bpb_root_entries, bpb_fat16;
    reg [31:0] bpb_total, bpb_fat_size, bpb_root_cluster;
    reg partition_found, partition_type_valid, partition_size_nonzero;
    reg [31:0] first_fat32_lba, partition_candidate_lba;
    wire [8:0] partition_offset = sector_byte_index - 9'd446;
    reg [4:0] directory_entry_index;
    reg [31:0] total_sectors;
    reg [31:0] fat_sectors;
    reg [7:0] fat_count;
    reg [15:0] reserved_sectors;
    reg [31:0] root_lba;
    reg [31:0] data_sector_count;
    reg [31:0] fat_span;
    reg [2:0] sectors_per_cluster_shift;
    reg [7:0] dir_name0;
    reg [7:0] dir_name1;
    reg [7:0] dir_name2;
    reg [7:0] dir_name3;
    reg [7:0] dir_name4;
    reg [7:0] dir_name5;
    reg [7:0] dir_name6;
    reg [7:0] dir_name7;
    reg [7:0] dir_name8;
    reg [7:0] dir_name9;
    reg [7:0] dir_name10;
    reg       dir_entry_match;
    reg [2:0] dir_resource_index;
    reg [15:0] dir_cluster_high;
    reg [15:0] dir_cluster_low;
    reg [31:0] dir_file_size;

    assign scan_busy = (state != ST_IDLE);

    function valid_spc;
        input [7:0] value;
        begin
            valid_spc = value != 0 && ((value & (value - 1'b1)) == 0);
        end
    endfunction

    function [2:0] spc_shift;
        input [7:0] value;
        begin
            case (value)
                8'd2:   spc_shift = 3'd1;
                8'd4:   spc_shift = 3'd2;
                8'd8:   spc_shift = 3'd3;
                8'd16:  spc_shift = 3'd4;
                8'd32:  spc_shift = 3'd5;
                8'd64:  spc_shift = 3'd6;
                8'd128: spc_shift = 3'd7;
                default: spc_shift = 3'd0;
            endcase
        end
    endfunction

    // MBR也可能以EB/E9跳转开头，不能只用第一个字节区分裸BPB。
    wire valid_bpb = bpb_bytes==16'd512 && valid_spc(bpb_spc) &&
                     bpb_reserved!=0 && (bpb_fats==1 || bpb_fats==2) &&
                     bpb_root_entries==0 && bpb_fat16==0 && bpb_total!=0 &&
                     bpb_fat_size!=0 && bpb_root_cluster>=2;

    task finish_with_error;
        input [7:0] code;
        begin
            fs_error <= code;
            state <= ST_FINISH;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            root_fat_entry<=0;
            boot_jump<=0; bpb_spc<=0; bpb_fats<=0; signature_low<=0; signature_high<=0;
            bpb_bytes<=0; bpb_reserved<=0; bpb_root_entries<=0; bpb_fat16<=0;
            bpb_total<=0; bpb_fat_size<=0; bpb_root_cluster<=0;
            partition_found<=0; partition_type_valid<=0; partition_size_nonzero<=0;
            first_fat32_lba<=0; partition_candidate_lba<=0;
            scan_done <= 1'b0;
            fs_error <= ERR_NONE;
            partition_lba <= 32'd0;
            sectors_per_cluster <= 8'd0;
            fat_start_lba <= 32'd0;
            data_start_lba <= 32'd0;
            max_cluster <= 32'd0;
            resource_valid <= 5'd0;
            resource0_cluster <= 32'd0;
            resource1_cluster <= 32'd0;
            resource2_cluster <= 32'd0;
            resource3_cluster <= 32'd0;
            resource4_cluster <= 32'd0;
            resource0_size <= 32'd0;
            resource1_size <= 32'd0;
            resource2_size <= 32'd0;
            resource3_size <= 32'd0;
            resource4_size <= 32'd0;
            sector_req <= 1'b0;
            sector_lba <= 32'd0;
            directory_entry_index <= 5'd0;
            root_cluster <= 32'd0; root_sector_offset<=0;root_cluster_count<=0;root_end<=0;
            total_sectors <= 32'd0;
            fat_sectors <= 32'd0;
            fat_count <= 8'd0;
            reserved_sectors <= 16'd0;
            root_lba <= 32'd0;
            data_sector_count <= 32'd0;
            fat_span <= 32'd0;
            sectors_per_cluster_shift <= 3'd0;
            dir_name0 <= 8'd0;
            dir_name1 <= 8'd0;
            dir_name2 <= 8'd0;
            dir_name3 <= 8'd0;
            dir_name4 <= 8'd0;
            dir_name5 <= 8'd0;
            dir_name6 <= 8'd0;
            dir_name7 <= 8'd0;
            dir_name8 <= 8'd0;
            dir_name9 <= 8'd0;
            dir_name10 <= 8'd0;
            dir_entry_match <= 1'b0;
            dir_resource_index <= 3'd7;
            dir_cluster_high <= 16'd0;
            dir_cluster_low <= 16'd0;
            dir_file_size <= 32'd0;
        end else begin
            scan_done <= 1'b0;
            sector_req <= 1'b0;
            // Only required fixed BPB fields are stored.
            // sector_done follows the final valid byte, per sector service contract.
            if (sector_valid && (state==ST_READ0_WAIT || state==ST_BOOT_WAIT)) begin
                case (sector_byte_index)
                    9'd0: boot_jump <= sector_byte;
                    9'd11: bpb_bytes[7:0] <= sector_byte;
                    9'd12: bpb_bytes[15:8] <= sector_byte;
                    9'd13: bpb_spc <= sector_byte;
                    9'd14: bpb_reserved[7:0] <= sector_byte;
                    9'd15: bpb_reserved[15:8] <= sector_byte;
                    9'd16: bpb_fats <= sector_byte;
                    9'd17: bpb_root_entries[7:0] <= sector_byte;
                    9'd18: bpb_root_entries[15:8] <= sector_byte;
                    9'd22: bpb_fat16[7:0] <= sector_byte;
                    9'd23: bpb_fat16[15:8] <= sector_byte;
                    9'd32: bpb_total[7:0] <= sector_byte;
                    9'd33: bpb_total[15:8] <= sector_byte;
                    9'd34: bpb_total[23:16] <= sector_byte;
                    9'd35: bpb_total[31:24] <= sector_byte;
                    9'd36: bpb_fat_size[7:0] <= sector_byte;
                    9'd37: bpb_fat_size[15:8] <= sector_byte;
                    9'd38: bpb_fat_size[23:16] <= sector_byte;
                    9'd39: bpb_fat_size[31:24] <= sector_byte;
                    9'd44: bpb_root_cluster[7:0] <= sector_byte;
                    9'd45: bpb_root_cluster[15:8] <= sector_byte;
                    9'd46: bpb_root_cluster[23:16] <= sector_byte;
                    9'd47: bpb_root_cluster[31:24] <= sector_byte;
                    9'd510: signature_low <= sector_byte;
                    9'd511: signature_high <= sector_byte;
                    default: ;
                endcase
                if (state==ST_READ0_WAIT && sector_byte_index>=9'd446 && sector_byte_index<9'd510) begin
                    case (partition_offset[3:0])
                        4'd4: partition_type_valid <= sector_byte==8'h0b || sector_byte==8'h0c;
                        4'd8: partition_candidate_lba[7:0] <= sector_byte;
                        4'd9: partition_candidate_lba[15:8] <= sector_byte;
                        4'd10: partition_candidate_lba[23:16] <= sector_byte;
                        4'd11: partition_candidate_lba[31:24] <= sector_byte;
                        4'd12: partition_size_nonzero <= sector_byte!=0;
                        4'd13,4'd14: partition_size_nonzero <= partition_size_nonzero || sector_byte!=0;
                        4'd15: if (!partition_found && partition_type_valid &&
                                  partition_candidate_lba!=0 && (partition_size_nonzero || sector_byte!=0)) begin
                            partition_found<=1'b1; first_fat32_lba<=partition_candidate_lba;
                        end
                        default: ;
                    endcase
                end
            end
            if(sector_valid && state==ST_ROOT_FAT_WAIT) begin
                if(sector_byte_index==root_fat_offset) root_fat_entry[7:0]<=sector_byte;
                if(sector_byte_index==root_fat_offset+9'd1) root_fat_entry[15:8]<=sector_byte;
                if(sector_byte_index==root_fat_offset+9'd2) root_fat_entry[23:16]<=sector_byte;
                if(sector_byte_index==root_fat_offset+9'd3) root_fat_entry[31:24]<=sector_byte;
            end

            if (sector_valid && state == ST_ROOT_WAIT) begin
                case (sector_byte_index[4:0])
                    5'd0: begin
                        dir_name0 <= sector_byte;
                        if(sector_byte==0) root_end<=1;
                        dir_entry_match <= 1'b0;
                    end
                    5'd1:  dir_name1 <= sector_byte;
                    5'd2:  dir_name2 <= sector_byte;
                    5'd3:  dir_name3 <= sector_byte;
                    5'd4:  dir_name4 <= sector_byte;
                    5'd5:  dir_name5 <= sector_byte;
                    5'd6:  dir_name6 <= sector_byte;
                    5'd7:  dir_name7 <= sector_byte;
                    5'd8:  dir_name8 <= sector_byte;
                    5'd9:  dir_name9 <= sector_byte;
                    5'd10: dir_name10 <= sector_byte;
                    5'd11: begin
                        if (!root_end && (sector_byte & 8'h18)==0 &&
                            dir_name0 == "P" && dir_name1 == "I" &&
                            dir_name2 == "C" && dir_name3 >= "1" &&
                            dir_name3 <= "5" && dir_name4 == " " &&
                            dir_name5 == " " && dir_name6 == " " &&
                            dir_name7 == " " && dir_name8 == "B" &&
                            dir_name9 == "M" && dir_name10 == "P") begin
                            dir_entry_match <= 1'b1;
                            dir_resource_index <= dir_name3 - "1";
                        end
                    end
                    5'd20: dir_cluster_high[7:0] <= sector_byte;
                    5'd21: dir_cluster_high[15:8] <= sector_byte;
                    5'd26: dir_cluster_low[7:0] <= sector_byte;
                    5'd27: dir_cluster_low[15:8] <= sector_byte;
                    5'd28: dir_file_size[7:0] <= sector_byte;
                    5'd29: dir_file_size[15:8] <= sector_byte;
                    5'd30: dir_file_size[23:16] <= sector_byte;
                    5'd31: begin
                        dir_file_size[31:24] <= sector_byte;
                        if (dir_entry_match && {dir_cluster_high,dir_cluster_low}>=2 &&
                            {dir_cluster_high,dir_cluster_low}<=max_cluster && {sector_byte,dir_file_size[23:0]}!=0) begin
                            case (dir_resource_index)
                                3'd0: begin
                                    resource0_cluster <= {dir_cluster_high, dir_cluster_low};
                                    resource0_size <= {sector_byte, dir_file_size[23:0]};
                                    resource_valid[0] <= 1'b1;
                                end
                                3'd1: begin
                                    resource1_cluster <= {dir_cluster_high, dir_cluster_low};
                                    resource1_size <= {sector_byte, dir_file_size[23:0]};
                                    resource_valid[1] <= 1'b1;
                                end
                                3'd2: begin
                                    resource2_cluster <= {dir_cluster_high, dir_cluster_low};
                                    resource2_size <= {sector_byte, dir_file_size[23:0]};
                                    resource_valid[2] <= 1'b1;
                                end
                                3'd3: begin
                                    resource3_cluster <= {dir_cluster_high, dir_cluster_low};
                                    resource3_size <= {sector_byte, dir_file_size[23:0]};
                                    resource_valid[3] <= 1'b1;
                                end
                                3'd4: begin
                                    resource4_cluster <= {dir_cluster_high, dir_cluster_low};
                                    resource4_size <= {sector_byte, dir_file_size[23:0]};
                                    resource_valid[4] <= 1'b1;
                                end
                                default: begin end
                            endcase
                        end
                    end
                    default: begin end
                endcase
            end

            case (state)
                ST_IDLE: if (scan_start) begin
                    fs_error <= ERR_NONE;
                    partition_found<=0; first_fat32_lba<=0;
                    partition_lba <= 32'd0;
                    resource_valid <= 5'd0;
                    state <= ST_READ0_REQ; root_sector_offset<=0;root_cluster_count<=0;root_end<=0;
                end
                ST_READ0_REQ: if (!sector_busy) begin
                    sector_lba <= 32'd0;
                    sector_req <= 1'b1;
                    state <= ST_READ0_WAIT;
                end
                ST_READ0_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else if (signature_low != 8'h55 || signature_high != 8'haa)
                        finish_with_error(ERR_BOOT_SIGNATURE);
                    else if (valid_bpb && (boot_jump == 8'heb || boot_jump == 8'he9)) begin
                        partition_lba <= 32'd0;
                        state <= ST_BOOT_PARSE;
                    end else if (partition_found) begin
                        partition_lba <= first_fat32_lba;
                        sector_lba <= first_fat32_lba;
                        state <= ST_BOOT_REQ;
                    end else begin
                        finish_with_error(ERR_UNSUPPORTED_BPB);
                    end
                end
                ST_BOOT_REQ: if (!sector_busy) begin
                    sector_req <= 1'b1;
                    state <= ST_BOOT_WAIT;
                end
                ST_BOOT_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else if (signature_low != 8'h55 || signature_high != 8'haa)
                        finish_with_error(ERR_BOOT_SIGNATURE);
                    else
                        state <= ST_BOOT_PARSE;
                end
                ST_BOOT_PARSE: begin
                    if (!valid_bpb) begin
                        finish_with_error(ERR_UNSUPPORTED_BPB);
                    end else begin
                        sectors_per_cluster <= bpb_spc;
                        reserved_sectors <= bpb_reserved;
                        fat_count <= bpb_fats;
                        total_sectors <= bpb_total;
                        fat_sectors <= bpb_fat_size;
                        root_cluster <= bpb_root_cluster;
                        sectors_per_cluster_shift <= spc_shift(bpb_spc);
                        fat_span <= bpb_fats == 2 ? (bpb_fat_size << 1) : bpb_fat_size;
                        fat_start_lba <= partition_lba + bpb_reserved;
                        state <= ST_BOOT_LAYOUT;
                    end
                end
                ST_BOOT_LAYOUT: begin
                    if(total_sectors<=reserved_sectors+fat_span) finish_with_error(ERR_UNSUPPORTED_BPB);
                    else begin
                        data_start_lba <= partition_lba + reserved_sectors + fat_span;
                        data_sector_count <= total_sectors - reserved_sectors - fat_span;
                        state <= ST_BOOT_ROOT;
                    end
                end
                ST_BOOT_ROOT: begin
                    max_cluster <= (data_sector_count >> sectors_per_cluster_shift) + 1'b1;
                    root_lba <= data_start_lba
                                + ((root_cluster - 2) << sectors_per_cluster_shift);
                    sector_lba <= data_start_lba
                                  + ((root_cluster - 2) << sectors_per_cluster_shift);
                    state <= ST_ROOT_REQ;
                end
                ST_ROOT_REQ: if (!sector_busy) begin
                    dir_entry_match <= 1'b0;
                    sector_req <= 1'b1;
                    state <= ST_ROOT_WAIT;
                end
                ST_ROOT_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else begin
                        directory_entry_index <= 5'd0;
                        state <= ST_DIR_SCAN;
                    end
                end
                ST_DIR_SCAN: begin
                    // 优先继续扫描以捕获可选 PIC5；到目录尾时 PIC1~PIC4 找齐即可成功。
                    if (resource_valid == 5'h1f)
                        state <= ST_FINISH;
                    else if(root_end) begin
                        if (resource_valid[3:0] == 4'hf)
                            state <= ST_FINISH;
                        else
                            finish_with_error(ERR_RESOURCE_MISSING);
                    end
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
                ST_FINISH: begin
                    scan_done <= 1'b1;
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
