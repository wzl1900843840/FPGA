`timescale 1ns/1ps
module tb_resource_wave;
reg clk=0;always #5 clk=~clk;
reg rst=0,vs=1,de=0,en=1,valid=0;
reg [9:0] x=0;reg [23:0] bg=0;reg signed [15:0] sample=0;
wire [23:0] actual,expected;wire aa,ea;
promax_audio_waveform #(.DECIMATE(1),.PIPELINE_OUTPUT(1)) dut(.clk(clk),.rst_n(rst),.vsync(vs),.de(de),.rgb_in(bg),.pixel_x(x),.enable(en),.pcm_tap_valid(valid),.pcm_tap_left(sample),.rgb_out(actual),.waveform_active(aa));
promax_audio_waveform_baseline #(.DECIMATE(1),.PIPELINE_OUTPUT(1)) reference(.clk(clk),.rst_n(rst),.vsync(vs),.de(de),.rgb_in(bg),.pixel_x(x),.enable(en),.pcm_tap_valid(valid),.pcm_tap_left(sample),.rgb_out(expected),.waveform_active(ea));
integer frame,y,xx,count=0;
always @(posedge clk)begin #1;if(rst)begin
 if(actual!==expected||aa!==ea)$fatal(1,"wave mismatch frame%0d x%0d y%0d actual%h expected%h",frame,x,y,actual,expected);
 count=count+1;end end
initial begin
 #12;rst=1;
 for(frame=0;frame<8;frame=frame+1)begin
  @(negedge clk);vs=0;de=0;valid=0;repeat(4)@(negedge clk);vs=1;repeat(4)@(negedge clk);
  for(y=0;y<480;y=y+1)begin
   for(xx=0;xx<640;xx=xx+1)begin
    @(negedge clk);x=xx;de=1;bg={$random};
    en=frame!=6;valid=(xx<64&&y==0);
    case(frame)
     0:sample=$random;1:sample=xx[0]?-16'sd32768:16'sd32767;
     2,3,4,5:sample=0;default:sample=16'sd4096;
    endcase
   end
   @(negedge clk);de=0;valid=0;repeat(3)@(negedge clk);
  end
 end
 @(negedge clk);rst=0;repeat(3)@(negedge clk);rst=1;repeat(10)@(negedge clk);
 $display("PASS resource waveform: %0d cycles match baseline including all RGB pixels, bank swap, full-scale, silence decay and enable",count);$finish;
end
initial begin #30000000;$fatal(1,"wave miter watchdog");end
endmodule
