from pathlib import Path
R=Path(__file__).resolve().parents[1]/'src/user_source/rtl'
p=R/'media_hdmi_audio_bridge.v';t=p.read_text(encoding='utf-8-sig')
t=t.replace('input  wire [7:0]  volume,','''input  wire [7:0]  volume,
    input wire wav_valid,wav_active,force_test,
    input wire signed [15:0] wav_sample,
    input wire [7:0] fade_gain,
    output wire wav_ready,
    output wire sample_tick,''')
t=t.replace('    pcm_media_tone u_tone (','''    wire tone_valid,tone_ready;
    wire signed [15:0] tone_left,tone_right;
    reg [24:0] rate_accumulator;
    assign sample_tick=rate_accumulator>=25000000-48000;
    always @(posedge pixel_clk or negedge pixel_rst_n)
        if(!pixel_rst_n) rate_accumulator<=0;
        else if(sample_tick) rate_accumulator<=rate_accumulator+48000-25000000;
        else rate_accumulator<=rate_accumulator+48000;
    pcm_media_tone u_tone (''')
t=t.replace('.media_id(media_id), .volume(volume),','.media_id(media_id), .volume(8\'d255),')
t=t.replace('.sample_valid(source_valid), .sample_ready(source_ready),\n        .sample_left(source_left), .sample_right(source_right),', '''.sample_valid(tone_valid), .sample_ready(tone_ready),
        .sample_left(tone_left), .sample_right(tone_right),''')
idx=t.index('    m06_pcm_contract_adapter')
t=t[:idx]+'''    // 48kHz采样的1kHz测试方波，24样本半周期。未选中的合成器持续排空。
    reg [5:0] test_phase;
    reg test_valid;
    reg signed [15:0] test_sample;
    wire test_ready;
    always @(posedge pixel_clk or negedge pixel_rst_n)
        if(!pixel_rst_n) begin test_phase<=0;test_valid<=0;test_sample<=0;end
        else begin
            if(test_ready) test_valid<=0;
            if(sample_tick && (!test_valid || test_ready)) begin
                test_phase<=test_phase==47?0:test_phase+1'b1;
                test_sample<=test_phase<24?16'sd6000:-16'sd6000;test_valid<=1;
            end
        end
    wire selected_wav=wav_active && !force_test;
    wire mux_valid,mux_ready;
    wire signed [15:0] mux_left,mux_right;
    wire arp_ready;
    audio_source_mux u_source_mux(.clk(pixel_clk),.rst_n(pixel_rst_n),
        .wav_valid(wav_valid),.wav_ready(wav_ready),.wav_left(wav_sample),.wav_right(wav_sample),
        .wav_active(wav_active),.arp_valid(force_test?test_valid:tone_valid),.arp_ready(arp_ready),
        .arp_left(force_test?test_sample:tone_left),.arp_right(force_test?test_sample:tone_right),
        .force_arpeggio(force_test),.out_valid(mux_valid),.out_ready(mux_ready),
        .out_left(mux_left),.out_right(mux_right));
    assign tone_ready=selected_wav || force_test ? 1'b1:arp_ready;
    assign test_ready=force_test?arp_ready:1'b1;
    // 增益在进入valid/ready契约适配器前计算；样本未握手时保持上游数据。
    wire [16:0] gain_product=volume*({1'b0,fade_gain}+9'd1);
    wire [7:0] gain=fade_gain==255?volume:gain_product[15:8];
    wire signed [24:0] left_product=mux_left*$signed({1'b0,gain});
    wire signed [24:0] right_product=mux_right*$signed({1'b0,gain});
    assign source_valid=mux_valid;
    assign mux_ready=source_ready;
    assign source_left=gain==255?mux_left:left_product>>>8;
    assign source_right=gain==255?mux_right:right_product>>>8;

'''+t[idx:]
p.write_text(t,encoding='utf-8')
