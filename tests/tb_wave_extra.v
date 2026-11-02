`timescale 1ns/1ps
module tb_wave_extra;
reg clk=0,rst_n=0;
always #5 clk=~clk;
reg [23:0] rgb=0;
reg [9:0] x=0;
reg signed [15:0] sample=0;
wire [23:0] legacy_rgb,pipelined_rgb;
wire legacy_active,pipelined_active;
promax_audio_waveform #(.DECIMATE(1),.PIPELINE_OUTPUT(1)) legacy(
 .clk(clk),.rst_n(rst_n),.vsync(1'b1),.de(1'b1),.rgb_in(rgb),.pixel_x(x),
 .enable(1'b1),.pcm_tap_valid(1'b1),.pcm_tap_left(sample),
 .rgb_out(legacy_rgb),.waveform_active(legacy_active));
promax_audio_waveform #(.DECIMATE(1),.PIPELINE_OUTPUT(1),.EXTRA_GEOM_PIPELINE(1)) pipelined(
 .clk(clk),.rst_n(rst_n),.vsync(1'b1),.de(1'b1),.rgb_in(rgb),.pixel_x(x),
 .enable(1'b1),.pcm_tap_valid(1'b1),.pcm_tap_left(sample),
 .rgb_out(pipelined_rgb),.waveform_active(pipelined_active));
reg [23:0] expected_rgb=0;
reg expected_active=0;
integer cycle=0;
always @(posedge clk) begin
 expected_rgb<=legacy_rgb;
 expected_active<=legacy_active;
end
initial begin
 force legacy.line_y=12'd410;force pipelined.line_y=12'd410;
 #21;rst_n=1;
 for(cycle=0;cycle<1200;cycle=cycle+1)begin
  @(negedge clk);
  x=cycle%640;rgb={cycle[7:0],cycle[7:0]^8'h5a,cycle[7:0]^8'ha5};
  sample=(cycle*619)%65536;
  if(cycle==100)begin force legacy.display_valid=1;force pipelined.display_valid=1;end
  if(cycle>105 && (pipelined_rgb!==expected_rgb || pipelined_active!==expected_active))
   $fatal(1,"geometry pipeline mismatch cycle=%0d x=%0d new=%h old=%h",cycle,x,pipelined_rgb,expected_rgb);
 end
 $display("PASS wave extra: pipeline preserves every pixel and active flag with exactly one-cycle alignment");$finish;
end
endmodule
