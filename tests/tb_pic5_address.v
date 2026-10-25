`timescale 1ns/1ps
// Small-parameter loader check for the fifth (emergency) bank.  Using four
// words keeps the test short while exercising the production bank_base()
// mapping: PIC5 must start immediately after the four daily banks.
module tb_pic5_address;
    localparam integer WORDS = 4;
    reg clk=0, rst=0, load_start=0, pixel_valid=0, source_top_down=1;
    reg frame_commit=0;
    reg [2:0] image_index=3'd4;
    reg [23:0] pixel_rgb=0;
    wire load_busy, load_done;
    wire [4:0] image_complete;
    wire [7:0] memory_error;
    wire app_wr_en;
    wire [20:0] app_wr_addr;
    wire [31:0] app_wr_data;
    integer writes=0;

    always #5 clk=~clk;

    media_frame_loader #(.IMAGE_WORDS(WORDS),.FIFO_DEPTH(4),.BURST_SIZE(4)) dut(
        .clk(clk),.rst_n(rst),.load_start(load_start),.image_index(image_index),
        .pixel_valid(pixel_valid),.pixel_rgb(pixel_rgb),.source_top_down(source_top_down),
        .frame_commit(frame_commit),.decode_error(8'd0),.load_busy(load_busy),
        .load_done(load_done),.image_complete(image_complete),.memory_error(memory_error),
        .controller_init_done(1'b1),.controller_busy(1'b0),.refresh_active(1'b0),
        .app_wr_en(app_wr_en),.app_wr_addr(app_wr_addr),.app_wr_mask(),.app_wr_data(app_wr_data));

    always @(posedge clk) if(app_wr_en) begin
        if(app_wr_addr !== 21'd16 + writes)
            $fatal(1,"PIC5 address %d expected %d",app_wr_addr,21'd16+writes);
        writes = writes + 1;
    end

    integer i;
    initial begin
        #12; rst=1;
        @(negedge clk); load_start=1;
        @(negedge clk); load_start=0;
        for(i=0;i<WORDS;i=i+1) begin
            pixel_rgb = 24'h550000 + i;
            pixel_valid=1;
            @(negedge clk);
        end
        pixel_valid=0; frame_commit=1;
        @(negedge clk); frame_commit=0;
        wait(load_done); #1;
        if(memory_error!==0 || image_complete!==5'b10000 || writes!=WORDS)
            $fatal(1,"PIC5 load failed err=%h complete=%b writes=%d",memory_error,image_complete,writes);
        $display("PASS PIC5 address: emergency bank starts at %0d and writes %0d words",WORDS*4,writes);
        $finish;
    end
    initial begin #100000; $fatal(1,"PIC5 watchdog busy=%b writes=%d",load_busy,writes); end
endmodule
