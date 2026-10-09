`timescale 1ns/1ps
// 四原图 bank 保持不变，剩余 SDRAM 中预合成一张 640x480 缩略图页。
// 每次读取源图一行的连续 640 字，抽取 x=0,4,...636，组成两个160x120窗口。
// 所有外部访问均为128字连续 burst；共享模式下由仲裁器调度后台构建。
module thumbnail_cache_builder #(
    parameter integer FRAME_WORDS=307200,
    parameter integer WAIT_CYCLES=256,
    parameter integer SHARED_MEMORY=0
)(
    input wire clk,rst_n,start,
    input wire [3:0] image_complete,
    output wire busy,
    output reg done,
    output reg [7:0] error,
    output reg app_rd_en,
    output reg [20:0] app_rd_addr,
    input wire rd_valid,
    input wire [31:0] rd_data,
    output reg app_wr_en,
    output reg [20:0] app_wr_addr,
    output reg [31:0] app_wr_data,
    input wire controller_busy,refresh_active,
    input wire burst_grant,
    output wire burst_request,burst_write
);
    reg [31:0] row [0:639] /* fehdl force_ram=1, ram_style="bram" */;
    reg [3:0] state;
    reg [9:0] x,received;
    reg [8:0] y;
    reg side;
    reg [8:0] gap;
    reg [19:0] watchdog;
    wire [1:0] bank={y>=120,side};
    wire [20:0] source_base=bank*FRAME_WORDS + ((y>=120?y-120:y)*4)*640;
    localparam IDLE=0,CLEAR=1,PREPARE=2,READ=3,DRAIN=4,WRITE=5,GAP=6,FINISH=7;
    assign busy=state!=IDLE;
    assign burst_write=state==WRITE;
    assign burst_request=(state==READ || state==WRITE) && x[6:0]==0 && gap==0;
    wire row_write=state==CLEAR || ((state==READ || state==DRAIN) && rd_valid && received<640 && received[1:0]==0);
    wire [9:0] row_address=state==CLEAR ? x : (side?160:0)+(received>>2);
    always @(posedge clk) if(state==WRITE) app_wr_data<=row[x];
    always @(posedge clk) if(row_write) row[row_address]<=state==CLEAR ? 32'd0:rd_data;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;done<=0;error<=0;x<=0;y<=0;side<=0;received<=0;gap<=0;watchdog<=0;
            app_rd_en<=0;app_rd_addr<=0;app_wr_en<=0;app_wr_addr<=0;
        end else begin
            done<=0;app_rd_en<=0;app_wr_en<=0;
            case(state)
            IDLE: if(start) begin state<=CLEAR;x<=0;y<=0;error<=0;end
            CLEAR: begin

                if(x==639) begin x<=0;side<=0;state<=PREPARE;end else x<=x+1'b1;
            end
            PREPARE: begin
                x<=0;received<=0;watchdog<=0;gap<=0;
                if(y>=240) state<=WRITE;
                else if(!image_complete[bank]) begin
                    if(side) state<=WRITE;else side<=1;
                end else state<=READ;
            end
            READ: begin
                // 每128字后留出控制器排队间隙，返回数据与发出请求分别计数。
                if(gap!=0) gap<=gap-1'b1;
                else if(x[6:0]!=0 || (!controller_busy && !refresh_active && (!SHARED_MEMORY || burst_grant))) begin
                    app_rd_en<=1;app_rd_addr<=source_base+x;
                    if(x==639) state<=DRAIN;
                    else begin x<=x+1'b1;if(x[6:0]==127) gap<=16;end
                end
            end
            DRAIN: begin
                if(received==640) begin
                    if(!side) begin side<=1;state<=PREPARE;end
                    else begin x<=0;gap<=WAIT_CYCLES;state<=GAP;end
                end else if(watchdog==20'hfffff) begin error<=8'h65;state<=FINISH;end
                else watchdog<=watchdog+1'b1;
            end
            WRITE: if(x[6:0]!=0 || (!controller_busy && !refresh_active && (!SHARED_MEMORY || burst_grant))) begin
                app_wr_en<=1;app_wr_addr<=FRAME_WORDS*4+y*640+x;
                if(x==639) begin x<=0;gap<=WAIT_CYCLES;state<=FINISH;end
                else begin
                    x<=x+1'b1;
                    if(x[6:0]==127) begin gap<=16;state<=GAP;end
                end
            end
            GAP: if(gap!=0) gap<=gap-1'b1;else state<=WRITE;
            FINISH: if(gap!=0) gap<=gap-1'b1;
                else if(y==479 || error!=0) begin done<=1;state<=IDLE;end
                else begin y<=y+1'b1;x<=0;state<=CLEAR;end
            default: state<=IDLE;
            endcase
            if((state==READ || state==DRAIN) && rd_valid && received<640) begin

                received<=received+1'b1;
            end
        end
    end
endmodule
