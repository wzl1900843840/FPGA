`timescale 1ns/1ps
// Small PCM time-domain trace. Capture 64 signed samples into the inactive
// bank, publish only at a frame boundary, and draw one bright pixel per
// 8-pixel horizontal cell. No interpolation, envelope, meter, or RGB mixer.
module pcm_waveform_lite(
    input wire clk,rst_n,vsync,de,enable,pcm_tap_valid,
    input wire [23:0] rgb_in,
    input wire [9:0] pixel_x,pixel_y,
    input wire signed [15:0] pcm_tap_left,
    output reg [23:0] rgb_out,
    output wire waveform_active
);
    reg signed [5:0] samples[0:127] /* fehdl force_ram=1, ram_style="bram" */;
    reg signed [5:0] sample_q;
    reg [6:0] write_count;
    reg [2:0] decimate;
    reg write_bank,display_bank,display_valid,vs_q;
    wire frame_start=vs_q && !vsync;
    wire capture_write=pcm_tap_valid && decimate==3'd7 && write_count<7'd64;
    wire [5:0] read_index=pixel_x[8:3]-6'd8;
    always @(posedge clk) begin
        if(capture_write) samples[{write_bank,write_count[5:0]}]<=pcm_tap_left[15:10];
        sample_q<=samples[{display_bank,read_index}];
    end
    reg [23:0] photo_q;
    reg [9:0] x_q,y_q;
    reg de_q,enable_q,valid_q;
    wire signed [9:0] trace_y=$signed(10'd432)-
        $signed({{4{sample_q[5]}},sample_q});
    assign waveform_active=enable_q && de_q && valid_q &&
        x_q>=10'd64 && x_q<10'd576 && y_q>=10'd400 && y_q<10'd464 &&
        y_q==trace_y;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            write_count<=0;decimate<=0;write_bank<=0;display_bank<=1;
            display_valid<=0;vs_q<=1;
            photo_q<=0;x_q<=0;y_q<=0;de_q<=0;enable_q<=0;valid_q<=0;
            rgb_out<=0;
        end else begin
            vs_q<=vsync;
            if(pcm_tap_valid) decimate<=decimate+1'b1;
            if(capture_write) write_count<=write_count+1'b1;
            if(frame_start && write_count==7'd64) begin
                display_bank<=write_bank;write_bank<=~write_bank;
                write_count<=0;display_valid<=1;
            end
            photo_q<=rgb_in;x_q<=pixel_x;y_q<=pixel_y;
            de_q<=de;enable_q<=enable;valid_q<=display_valid;
            rgb_out<=waveform_active ? 24'h44f4fa : photo_q;
        end
    end
endmodule
