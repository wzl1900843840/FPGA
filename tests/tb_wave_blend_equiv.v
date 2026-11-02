`timescale 1ns/1ps
module tb_wave_blend_equiv;
reg clk=0,rst_n=0;
always #5 clk=~clk;
reg [23:0] rgb=0;
reg [9:0] x=0;
reg signed [15:0] sample=0;
wire [23:0] old_rgb,new_rgb;
wire old_active,new_active;
promax_audio_waveform_old #(.DECIMATE(1),.PIPELINE_OUTPUT(1),.EXTRA_GEOM_PIPELINE(1)) old_dut(
 .clk(clk),.rst_n(rst_n),.vsync(1'b1),.de(1'b1),.rgb_in(rgb),.pixel_x(x),
 .enable(1'b1),.pcm_tap_valid(1'b1),.pcm_tap_left(sample),
 .rgb_out(old_rgb),.waveform_active(old_active));
promax_audio_waveform #(.DECIMATE(1),.PIPELINE_OUTPUT(1),.EXTRA_GEOM_PIPELINE(1)) new_dut(
 .clk(clk),.rst_n(rst_n),.vsync(1'b1),.de(1'b1),.rgb_in(rgb),.pixel_x(x),
 .enable(1'b1),.pcm_tap_valid(1'b1),.pcm_tap_left(sample),
 .rgb_out(new_rgb),.waveform_active(new_active));
integer cycle;
initial begin
 force old_dut.line_y=12'd410;force new_dut.line_y=12'd410;
 #21;rst_n=1;
 for(cycle=0;cycle<6000;cycle=cycle+1)begin
  @(negedge clk);
  x=cycle%640;
  rgb={cycle[7:0],cycle[15:8]^8'h5a,cycle[7:0]^8'ha5};
  sample=(cycle*619)%65536;
  if(cycle==100)begin force old_dut.display_valid=1;force new_dut.display_valid=1;end
  if(cycle>105 && (old_rgb!==new_rgb || old_active!==new_active))
   $fatal(1,"blend equivalence cycle=%0d x=%0d new=%h old=%h",cycle,x,new_rgb,old_rgb);
 end
 $display("PASS wave blend equivalence: full waveform pixels and active flags match");$finish;
end
endmodule
