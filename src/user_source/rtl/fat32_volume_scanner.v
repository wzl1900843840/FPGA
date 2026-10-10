`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// FAT32 卷扫描器：在卡上找到 PIC1~PIC4 四个文件，并给出它们的簇链起点
//
// 干什么（一次扫描）：
//   1) 读 LBA0，看它是不是分区表(MBR)：是就取出第一个分区起始LBA；
//      不是就直接把 LBA0 当引导扇区（superfloppy 布局的卡，演示镜像就是这种）；
//   2) 解析引导扇区 BPB：每簇扇区数、保留扇区数、FAT个数/大小、根目录位置等，
//      并用这些算出 FAT 表起始LBA、数据区起始LBA、最大簇号；
//   3) 从根目录开始逐条读目录项（每条32字节），按文件名匹配 PIC1.BMP~PIC4.BMP，
//      记录各自的起始簇号和文件大小；
//   4) 根目录如果跨了多个扇区/簇，还要顺着 FAT 表找下一个簇继续扫。
//
// 关键设计：内部有一个 512 字节的 sector_buffer，把整个扇区先收下来再解析。
// 这样解析逻辑可以随便回头取任意偏移的字节，不用跟串行到来的字节流抢时序；
// le16/le32 两个函数就是从缓冲区里按小端序取出16/32位字段。
//
// 对外结果：resource_valid[3:0] 表示哪几张图找到了（注意：找到 ≠ 内容正确），
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
    output reg  [3:0]  resource_valid,
    output reg  [31:0] resource0_cluster,
    output reg  [31:0] resource1_cluster,
    output reg  [31:0] resource2_cluster,
    output reg  [31:0] resource3_cluster,
    output reg  [31:0] resource0_size,
    output reg  [31:0] resource1_size,
    output reg  [31:0] resource2_size,
    output reg  [31:0] resource3_size,
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
    reg [7:0] sector_buffer [0:511];
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
    reg [1:0] dir_resource_index;
    reg [15:0] dir_cluster_high;
    reg [15:0] dir_cluster_low;
    reg [31:0] dir_file_size;

    assign scan_busy = (state != ST_IDLE);

    // 整个扇区先缓存下来再解析，解析时可以任意回头取偏移，不受字节流时序限制
    function [15:0] le16;
        input integer offset;
        begin
            le16 = {sector_buffer[offset+1], sector_buffer[offset]};
        end
    endfunction

    function [31:0] le32;
        input integer offset;
        begin
            le32 = {sector_buffer[offset+3], sector_buffer[offset+2],
                    sector_buffer[offset+1], sector_buffer[offset]};
        end
    endfunction

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
    wire valid_bpb = {sector_buffer[12],sector_buffer[11]}==512 && valid_spc(sector_buffer[13]) &&
                     {sector_buffer[15],sector_buffer[14]}!=0 && (sector_buffer[16]==1 || sector_buffer[16]==2) &&
                     {sector_buffer[18],sector_buffer[17]}==0 && {sector_buffer[23],sector_buffer[22]}==0 && {sector_buffer[35],sector_buffer[34],sector_buffer[33],sector_buffer[32]}!=0 &&
                     {sector_buffer[39],sector_buffer[38],sector_buffer[37],sector_buffer[36]}!=0 && {sector_buffer[47],sector_buffer[46],sector_buffer[45],sector_buffer[44]}>=2;
    reg partition_found;
    reg [31:0] first_fat32_lba;
    integer partition_slot;
    always @* begin
        partition_found=0;first_fat32_lba=0;
        for(partition_slot=0;partition_slot<4;partition_slot=partition_slot+1)
            if(!partition_found &&
               (sector_buffer[450+16*partition_slot]==8'h0b || sector_buffer[450+16*partition_slot]==8'h0c) &&
               le32(454+16*partition_slot)!=0 && le32(458+16*partition_slot)!=0) begin
                partition_found=1;
                first_fat32_lba=le32(454+16*partition_slot);
            end
    end

    function [1:0] matching_resource;
        input integer base;
        begin
            if (sector_buffer[base+0] == "P" && sector_buffer[base+1] == "I" &&
                sector_buffer[base+2] == "C" && sector_buffer[base+3] == "1" &&
                sector_buffer[base+8] == "B" && sector_buffer[base+9] == "M" &&
                sector_buffer[base+10] == "P")
                matching_resource = 2'd0;
            else if (sector_buffer[base+0] == "P" && sector_buffer[base+1] == "I" &&
                     sector_buffer[base+2] == "C" && sector_buffer[base+3] == "2" &&
                     sector_buffer[base+8] == "B" && sector_buffer[base+9] == "M" &&
                     sector_buffer[base+10] == "P")
                matching_resource = 2'd1;
            else if (sector_buffer[base+0] == "P" && sector_buffer[base+1] == "I" &&
                     sector_buffer[base+2] == "C" && sector_buffer[base+3] == "3" &&
                     sector_buffer[base+8] == "B" && sector_buffer[base+9] == "M" &&
                     sector_buffer[base+10] == "P")
                matching_resource = 2'd2;
            else
                matching_resource = 2'd3;
        end
    endfunction

    task finish_with_error;
        input [7:0] code;
        begin
            fs_error <= code;
            state <= ST_FINISH;
        end
    endtask

    task accept_directory_entry;
        input integer base;
        reg [1:0] resource_index;
        reg [31:0] first_cluster;
        reg [31:0] file_size;
        begin
            resource_index = matching_resource(base);
            first_cluster = {sector_buffer[base+21], sector_buffer[base+20],
                             sector_buffer[base+27], sector_buffer[base+26]};
            file_size = le32(base+28);
            case (resource_index)
                2'd0: begin
                    resource0_cluster <= first_cluster;
                    resource0_size <= file_size;
                    resource_valid[0] <= 1'b1;
                end
                2'd1: begin
                    resource1_cluster <= first_cluster;
                    resource1_size <= file_size;
                    resource_valid[1] <= 1'b1;
                end
                2'd2: begin
                    resource2_cluster <= first_cluster;
                    resource2_size <= file_size;
                    resource_valid[2] <= 1'b1;
                end
                default: begin
                    resource3_cluster <= first_cluster;
                    resource3_size <= file_size;
                    resource_valid[3] <= 1'b1;
                end
            endcase
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            root_fat_entry<=0;
            scan_done <= 1'b0;
            fs_error <= ERR_NONE;
            partition_lba <= 32'd0;
            sectors_per_cluster <= 8'd0;
            fat_start_lba <= 32'd0;
            data_start_lba <= 32'd0;
            max_cluster <= 32'd0;
            resource_valid <= 4'd0;
            resource0_cluster <= 32'd0;
            resource1_cluster <= 32'd0;
            resource2_cluster <= 32'd0;
            resource3_cluster <= 32'd0;
            resource0_size <= 32'd0;
            resource1_size <= 32'd0;
            resource2_size <= 32'd0;
            resource3_size <= 32'd0;
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
            dir_resource_index <= 2'd3;
            dir_cluster_high <= 16'd0;
            dir_cluster_low <= 16'd0;
            dir_file_size <= 32'd0;
        end else begin
            scan_done <= 1'b0;
            sector_req <= 1'b0;
            // BPB仅需固定偏移；根目录/FAT流式提取，避免512字节多路异步读阵列。
            if (sector_valid && (state==ST_READ0_WAIT || state==ST_BOOT_WAIT))
                sector_buffer[sector_byte_index] <= sector_byte;
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
                            dir_name3 <= "4" && dir_name4 == " " &&
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
                                2'd0: begin
                                    resource0_cluster <= {dir_cluster_high, dir_cluster_low};
                                    resource0_size <= {sector_byte, dir_file_size[23:0]};
                                    resource_valid[0] <= 1'b1;
                                end
                                2'd1: begin
                                    resource1_cluster <= {dir_cluster_high, dir_cluster_low};
                                    resource1_size <= {sector_byte, dir_file_size[23:0]};
                                    resource_valid[1] <= 1'b1;
                                end
                                2'd2: begin
                                    resource2_cluster <= {dir_cluster_high, dir_cluster_low};
                                    resource2_size <= {sector_byte, dir_file_size[23:0]};
                                    resource_valid[2] <= 1'b1;
                                end
                                default: begin
                                    resource3_cluster <= {dir_cluster_high, dir_cluster_low};
                                    resource3_size <= {sector_byte, dir_file_size[23:0]};
                                    resource_valid[3] <= 1'b1;
                                end
                            endcase
                        end
                    end
                    default: begin end
                endcase
            end

            case (state)
                ST_IDLE: if (scan_start) begin
                    fs_error <= ERR_NONE;
                    partition_lba <= 32'd0;
                    resource_valid <= 4'd0;
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
                    else if (sector_buffer[510] != 8'h55 || sector_buffer[511] != 8'haa)
                        finish_with_error(ERR_BOOT_SIGNATURE);
                    else if (valid_bpb && (sector_buffer[0] == 8'heb || sector_buffer[0] == 8'he9)) begin
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
                    else if (sector_buffer[510] != 8'h55 || sector_buffer[511] != 8'haa)
                        finish_with_error(ERR_BOOT_SIGNATURE);
                    else
                        state <= ST_BOOT_PARSE;
                end
                ST_BOOT_PARSE: begin
                    if (!valid_bpb) begin
                        finish_with_error(ERR_UNSUPPORTED_BPB);
                    end else begin
                        sectors_per_cluster <= sector_buffer[13];
                        reserved_sectors <= le16(14);
                        fat_count <= sector_buffer[16];
                        total_sectors <= le32(32);
                        fat_sectors <= le32(36);
                        root_cluster <= le32(44);
                        sectors_per_cluster_shift <= spc_shift(sector_buffer[13]);
                        fat_span <= sector_buffer[16] == 2 ? (le32(36) << 1) : le32(36);
                        fat_start_lba <= partition_lba + le16(14);
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
                    if (resource_valid == 4'hf)
                        state <= ST_FINISH;
                    else if(root_end) finish_with_error(ERR_RESOURCE_MISSING);
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
