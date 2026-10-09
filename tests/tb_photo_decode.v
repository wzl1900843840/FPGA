`timescale 1ns/1ps
module tb_photo_decode;
    reg clk=0;always #5 clk=~clk;
    reg rst=0,start=0,valid=0,last=0;
    reg [7:0] byte_value=0;
    reg [31:0] offset=0;
    wire pv,commit,done,accepted,top_down;
    wire [23:0] rgb;
    wire [15:0] x,y;
    wire [7:0] error;
    bmp24_decoder dut(.clk(clk),.rst_n(rst),.file_start(start),.file_size(32'd921654),
        .file_valid(valid),.file_byte(byte_value),.file_byte_offset(offset),.file_end(last),
        .upstream_error(8'd0),.header_accepted(accepted),.pixel_valid(pv),.pixel_rgb(rgb),
        .pixel_x(x),.pixel_y(y),.frame_commit(commit),.bmp_done(done),.bmp_error(error),.top_down(top_down));
    reg [7:0] bytes[0:921653];
    reg [23:0] pixels[0:307199];
    reg [1023:0] bmp_file,pixel_file;
    integer i,count=0,commits=0;
    always @(negedge clk) begin
        if(pv) begin
            if(x>=640 || y>=480 || rgb!==pixels[y*640+x])$fatal(1,"BMP pixel mismatch (%d,%d) %h",x,y,rgb);
            count=count+1;
        end
        if(commit)commits=commits+1;
    end
    initial begin
        if(!$value$plusargs("BMP=%s",bmp_file) || !$value$plusargs("PIXELS=%s",pixel_file))$fatal(1,"fixtures required");
        $readmemh(bmp_file,bytes);$readmemh(pixel_file,pixels);
        #21;rst=1;@(negedge clk);start=1;@(negedge clk);start=0;
        for(i=0;i<921654;i=i+1) begin
            byte_value=bytes[i];offset=i;valid=1;@(negedge clk);valid=0;
            repeat(3)@(negedge clk);
        end
        repeat(10)@(negedge clk);last=1;@(negedge clk);last=0;repeat(10)@(negedge clk);
        if(error || count!=307200 || commits!=1 || top_down)$fatal(1,"BMP contract count=%d commits=%d error=%h",count,commits,error);
        $display("PASS photo decode: all 307200 actual pixels, header, BGR ordering, bottom-up direction, single commit");$finish;
    end
    initial begin #50000000;$fatal(1,"decode watchdog");end
endmodule
