`timescale 1ns/1ps
module tb_wave_lite;
reg clk=0,rst_n=0,vsync=1,de=1,enable=1,pcm_tap_valid=0;
reg signed [15:0] pcm_tap_left=0;
reg [23:0] rgb_in=24'h123456;
reg [9:0] pixel_x=64,pixel_y=416;
wire [23:0] rgb_out;wire waveform_active;
always #5 clk=~clk;
pcm_waveform_lite dut(.clk(clk),.rst_n(rst_n),.vsync(vsync),.de(de),.enable(enable),
 .pcm_tap_valid(pcm_tap_valid),.pcm_tap_left(pcm_tap_left),.rgb_in(rgb_in),
 .pixel_x(pixel_x),.pixel_y(pixel_y),.rgb_out(rgb_out),.waveform_active(waveform_active));
task fill;input signed [15:0] sample;integer i;begin
 for(i=0;i<512;i=i+1)begin
  @(negedge clk);pcm_tap_valid=1;pcm_tap_left=sample;
  @(negedge clk);pcm_tap_valid=0;
 end
end endtask
task commit;begin
 @(negedge clk);vsync=0;repeat(3)@(negedge clk);vsync=1;
 repeat(3)@(negedge clk);
end endtask
task check;input [9:0] x,y;input [23:0] expected;begin
 @(negedge clk);pixel_x=x;pixel_y=y;
 repeat(4)@(negedge clk);
 if(rgb_out!==expected)$fatal(1,"pixel %d,%d got %h expected %h",x,y,rgb_out,expected);
end endtask
initial begin
 #21;rst_n=1;
 check(64,416,24'h123456);
 fill(16'sh4000);commit;
 check(64,416,24'h44f4fa);
 check(64,417,24'h123456);
 check(576,416,24'h123456);
 fill(-16'sh4000);
 check(64,416,24'h44f4fa);
 commit;
 check(64,448,24'h44f4fa);
 check(64,416,24'h123456);
 enable=0;check(64,448,24'h123456);
 $display("PASS lite PCM waveform: frame commit, both banks, exact trace and transparent passthrough");$finish;
end
initial begin #10000000;$fatal(1,"watchdog");end
endmodule
