`timescale 1ns/1ps
module tb_audio_mute;
    reg clk=0;always #20 clk=~clk;
    reg rst=0,force_test=0,wav_active=0,wav_valid=0,guard=1;
    reg [7:0] volume=0;
    wire hs,vs,de,tap,ready,tick,seqerr,toneerr,contracterr;
    wire [11:0] x,y;
    wire signed [15:0] sample;
    video_timing_ctrl timing(.pclk(clk),.rst_n(rst),.hsync(hs),.vsync(vs),.de(de),.x(x),.y(y));
    media_hdmi_audio_bridge dut(.pixel_clk(clk),.pixel_rst_n(rst),
        .video_hsync(hs),.video_vsync(vs),.video_de(de),.video_x(x[9:0]),.video_rgb(24'h306070),
        .media_id(2'd1),.volume(volume),.wav_valid(wav_valid),.wav_active(wav_active),
        .force_test(force_test),.wav_sample(-16'sd32768),.fade_gain(8'd255),
        .wav_ready(ready),.sample_tick(tick),.sequence_error(seqerr),.tone_overflow(toneerr),
        .pcm_contract_error(contracterr),.pcm_tap_valid(tap),.pcm_tap_left(sample));
    integer taps=0,nonzero=0,packets=0;
    always @(posedge clk) if(rst) begin
        if(tap) begin
            taps=taps+1;if(sample!=0)nonzero=nonzero+1;
            if(guard && (sample!==0 || dut.sample_right!==0))$fatal(1,"mute PCM output not zero");
        end
        if(seqerr || toneerr || contracterr)$fatal(1,"HDMI audio contract");
        if(dut.u_symbol_core.packet_ready)packets=packets+1;
    end
    always @(negedge clk) if(!rst) wav_valid=0;
        else if(wav_active) begin
            if(ready) wav_valid=0;
            if(tick) wav_valid=1;
        end
    task samples;input integer count;integer target;begin target=taps+count;wait(taps>=target);@(negedge clk);end endtask
    initial begin
        #51;rst=1;samples(120);force_test=1;samples(120);
        force_test=0;wav_active=1;samples(120);
        guard=0;volume=64;samples(120);
        if(nonzero<80)$fatal(1,"volume control locked at mute");
        volume=0;samples(32);guard=1;samples(120);
        rst=0;volume=0;repeat(5)@(negedge clk);rst=1;samples(120);
        if(packets<80)$fatal(1,"no audio packets");
        $display("PASS HDMI mute: tone, SW4 test tone, full-scale WAV, both channels, runtime unmute/remute, reset, valid/ready, packet/symbol regression");
        $finish;
    end
    initial begin #80000000;$fatal(1,"audio mute watchdog");end
endmodule
