`timescale 1ns/1ps
module tb_alarm_hdmi;
reg clk=0,rst=0,alarm=0;always #20 clk=~clk;
wire hs,vs,de,tap,seqerr,toneerr,contracterr,tick;
wire[11:0]x,y;wire signed[15:0]sample;
video_timing_ctrl timing(.pclk(clk),.rst_n(rst),.hsync(hs),.vsync(vs),.de(de),.x(x),.y(y));
media_hdmi_audio_bridge d(.pixel_clk(clk),.pixel_rst_n(rst),.video_hsync(hs),.video_vsync(vs),
 .video_de(de),.video_x(x[9:0]),.video_rgb(24'h306070),.media_id(2'd1),.volume(8'd0),
 .wav_valid(1'b0),.wav_active(1'b0),.force_test(1'b0),.wav_sample(16'sd0),.fade_gain(8'd0),
 .alarm_active(alarm),.sample_tick(tick),.sequence_error(seqerr),.tone_overflow(toneerr),
 .pcm_contract_error(contracterr),.pcm_tap_valid(tap),.pcm_tap_left(sample));
integer taps=0,loud=0;
always @(posedge clk)if(rst)begin
 if(seqerr || toneerr || contracterr)$fatal(1,"HDMI alarm contract/sequence error");
 if(tap)begin
  taps=taps+1;if(sample!=0)loud=loud+1;
  if(sample>4096 || sample< -4096)$fatal(1,"HDMI alarm clipping");
 end
end
initial begin
 #61;rst=1;wait(taps==30);@(negedge clk);alarm=1;
 wait(taps==500);if(loud<350)$fatal(1,"default mute/fade suppressed alarm");
 @(negedge clk);alarm=0;wait(taps==650);if(d.alarm_playing)$fatal(1,"HDMI alarm did not stop");
 loud=0;wait(taps==800);if(loud!=0)$fatal(1,"normal boot mute not restored");
 $display("PASS alarm HDMI: real 48kHz/packet/symbol timing, default mute/fade bypass, amplitude limit, smooth clear and normal mute restore");$finish;
end
initial begin #30000000;$fatal(1,"alarm HDMI timeout");end
endmodule
