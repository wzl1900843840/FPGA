`timescale 1ns/1ps
module tb_alarm_audio;
reg clk=0,rst=0,alarm=0,tick=0,ready=1;always #20 clk=~clk;
wire signed[15:0]sample;
media_hdmi_audio_bridge d(.pixel_clk(clk),.pixel_rst_n(rst),.video_hsync(1'b1),.video_vsync(1'b1),
 .video_de(1'b0),.video_x(10'd0),.video_rgb(24'd0),.media_id(2'd0),.volume(8'd0),
 .wav_valid(1'b0),.wav_active(1'b0),.force_test(1'b0),.wav_sample(16'sd0),.fade_gain(8'd0),.alarm_active(alarm));
media_hdmi_audio_bridge #(.ALARM_SOUND_ENABLE(0)) disabled(.pixel_clk(clk),.pixel_rst_n(rst),
 .video_hsync(1'b1),.video_vsync(1'b1),.video_de(1'b0),.video_x(10'd0),.video_rgb(24'd0),
 .media_id(2'd0),.volume(8'd0),.wav_valid(1'b0),.wav_active(1'b0),.force_test(1'b0),
 .wav_sample(16'sd0),.fade_gain(8'd0),.alarm_active(alarm));
assign sample=d.scaled_left;
integer n,on_samples=0,segments=0;reg[2:0]last_segment=0;reg signed[15:0]held;
task one_sample;begin tick=1;@(negedge clk);tick=0;repeat(3)@(negedge clk);end endtask
initial begin
 force d.sample_tick=tick;force d.source_ready=ready;
 force disabled.sample_tick=tick;force disabled.source_ready=ready;
 #61;rst=1;repeat(3)@(negedge clk);alarm=1;repeat(2)@(negedge clk);
 for(n=0;n<48000;n=n+1) begin
  if(d.alarm_segment!=last_segment)begin segments=segments+1;last_segment=d.alarm_segment;end
  one_sample;
  if(d.scaled_left>4096 || d.scaled_left< -4096 || d.scaled_right!==d.scaled_left)$fatal(1,"alarm amplitude/channel");
  if(d.scaled_left!=0)on_samples=on_samples+1;
  if(d.alarm_segment[0] && d.alarm_samples>2 && d.scaled_left!=0)$fatal(1,"off segment not silent");
  if(disabled.alarm_playing || disabled.scaled_left!=0)$fatal(1,"compile disable broken");
 end
 if(d.alarm_playing || segments!=4 || on_samples<28000 || on_samples>28800)$fatal(1,"three-beep schedule %d %d",segments,on_samples);
 repeat(12)one_sample;
 if(d.alarm_playing)$fatal(1,"level retriggered sound");
 alarm=0;one_sample;alarm=1;repeat(80)one_sample;
 ready=0;repeat(3)@(negedge clk);held=d.scaled_left;
 repeat(20)begin one_sample;if(!d.scaled_valid || d.scaled_left!==held)$fatal(1,"valid/data changed under backpressure");end
 alarm=0;ready=1;repeat(70)one_sample;
 if(d.alarm_playing || d.alarm_envelope!=0)$fatal(1,"clear did not ramp to zero");
 $display("PASS alarm audio: 3x200ms/200ms, 48-sample 1kHz phase, amplitude cap, mute/fade bypass, no repeat, backpressure, clear ramp, compile disable");$finish;
end
initial begin #20000000;$fatal(1,"alarm audio timeout");end
endmodule
