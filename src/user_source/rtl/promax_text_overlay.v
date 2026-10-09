`timescale 1ns/1ps

// Photo-first OSD. Numeric conversion runs only on a field change; all
// visible values are committed in vertical blanking. Pixel work is font
// lookup and color selection, with no decimal division or DSP operations.
module promax_text_overlay #(
    parameter integer PARAM_X=96, PARAM_Y=40, STATUS_X=96, STATUS_Y=16,
    parameter integer SUBTITLE_Y=72, H_ACTIVE=640, TIMER_X=564
)(
    input wire clk,rst_n,vsync,de,
    input wire [23:0] rgb_in,
    input wire [9:0] pixel_x,pixel_y,
    input wire enable,subtitle_enable,
    input wire [95:0] subtitle_text,
    input wire [5:0] subtitle_length,
    input wire [7:0] contrast,brightness,volume,
    input wire [31:0] period_ms,
    input wire auto_enabled,source_scale_2x,
    input wire [1:0] active_index,
    input wire loading,
    input wire [7:0] error_code,error_detail,
    output wire [23:0] rgb_out,
    output wire overlay_active
);
    localparam integer CELL_W=12, CELL_H=16, PARAM_CHARS=32;
    localparam integer SUBTITLE_CELL_W=18, SCROLL_CYCLE=H_ACTIVE+128;
    reg vs_q;
    wire frame_start=vs_q && !vsync;
    reg [9:0] scroll_pos;
    reg [1:0] scroll_div,index_frame;
    reg auto_frame,loading_frame,scale_frame;
    reg [7:0] error_frame,detail_frame;
    reg [95:0] subtitle_frame;
    reg [5:0] subtitle_length_frame;
    reg subtitle_on_frame;

    wire [40:0] numeric_inputs={source_scale_2x,contrast,brightness,volume,period_ms[15:0]};
    reg [40:0] numeric_seen;
    reg convert_busy,numeric_scale_pending;
    reg [3:0] convert_step;
    reg [15:0] bin_c,bin_b,bin_v,bin_p;
    reg [11:0] bcd_c,bcd_b,bcd_v;
    reg [19:0] bcd_p;
    reg [55:0] numbers_pending,numbers_frame;
    // Double dabble: one bit per clock, constant-sized nibble adders.
    function [19:0] bcd_shift;
        input [19:0] digits;
        input bit_in;
        reg [19:0] adjusted;
        integer i;
        begin
            adjusted=digits;
            for(i=0;i<5;i=i+1)
                if(digits[i*4 +: 4]>=5) adjusted[i*4 +: 4]=digits[i*4 +: 4]+4'd3;
            bcd_shift={adjusted[18:0],bit_in};
        end
    endfunction
    wire [19:0] next_p=bcd_shift(bcd_p,bin_p[15]);
    wire [19:0] next_c=bcd_shift({8'd0,bcd_c},bin_c[15]);
    wire [19:0] next_b=bcd_shift({8'd0,bcd_b},bin_b[15]);
    wire [19:0] next_v=bcd_shift({8'd0,bcd_v},bin_v[15]);
    reg [24:0] timer_cycles;
    reg [3:0] mm_tens,mm_ones,ss_tens,ss_ones;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            vs_q<=1;scroll_pos<=0;scroll_div<=0;index_frame<=0;
            auto_frame<=0;loading_frame<=1;scale_frame<=0;error_frame<=0;detail_frame<=0;
            subtitle_frame<=0;subtitle_length_frame<=0;subtitle_on_frame<=0;
            numeric_seen<=41'h1ffffffffff;convert_busy<=0;convert_step<=0;
            numeric_scale_pending<=0;bin_c<=0;bin_b<=0;bin_v<=0;bin_p<=0;
            bcd_c<=0;bcd_b<=0;bcd_v<=0;bcd_p<=0;
            numbers_pending<={12'h128,12'h255,12'h000,20'h05000};
            numbers_frame<={12'h128,12'h255,12'h000,20'h05000};
            timer_cycles<=0;mm_tens<=0;mm_ones<=0;ss_tens<=0;ss_ones<=0;
        end else begin
            vs_q<=vsync;
            if(!convert_busy && numeric_inputs!=numeric_seen) begin
                numeric_seen<=numeric_inputs;convert_busy<=1;convert_step<=0;
                bin_c<={8'd0,contrast};bin_b<={8'd0,brightness};bin_v<={8'd0,volume};bin_p<=period_ms[15:0];
                bcd_c<=0;bcd_b<=0;bcd_v<=0;bcd_p<=0;
            end else if(convert_busy) begin
                bin_c<=bin_c<<1;bin_b<=bin_b<<1;bin_v<=bin_v<<1;bin_p<=bin_p<<1;
                bcd_c<=next_c[11:0];bcd_b<=next_b[11:0];bcd_v<=next_v[11:0];bcd_p<=next_p;
                if(convert_step==15) begin
                    numbers_pending<={next_c[11:0],next_b[11:0],next_v[11:0],next_p};
                    numeric_scale_pending<=numeric_seen[40];convert_busy<=0;
                end else convert_step<=convert_step+1'b1;
            end
            if(frame_start) begin
                numbers_frame<=numbers_pending;scale_frame<=numeric_scale_pending;
                index_frame<=active_index;auto_frame<=auto_enabled;loading_frame<=loading;
                error_frame<=error_code;detail_frame<=error_detail;
                subtitle_frame<=subtitle_text;subtitle_length_frame<=subtitle_length;subtitle_on_frame<=subtitle_enable;
                if(scroll_div==2) begin
                    scroll_div<=0;scroll_pos<=scroll_pos==SCROLL_CYCLE-1 ? 0 : scroll_pos+1'b1;
                end else scroll_div<=scroll_div+1'b1;
                // Existing 25 MHz / 800x525 clock: retain actual elapsed time.
                if(timer_cycles>=25000000-420000) begin
                    timer_cycles<=timer_cycles+420000-25000000;
                    if(ss_ones!=9) ss_ones<=ss_ones+1'b1;
                    else begin ss_ones<=0;
                        if(ss_tens!=5) ss_tens<=ss_tens+1'b1;
                        else begin ss_tens<=0;
                            if(mm_ones!=9) mm_ones<=mm_ones+1'b1;
                            else begin mm_ones<=0;mm_tens<=mm_tens==9 ? 0 : mm_tens+1'b1;end
                        end
                    end
                end else timer_cycles<=timer_cycles+420000;
            end
        end
    end
    function [7:0] hex_char;
        input [3:0] n;
        begin hex_char=n<10 ? "0"+n : "A"+(n-10);end
    endfunction
    function [7:0] status_char;
        input [5:0] n;
        begin
            status_char=" ";
            case(n)
                0:status_char="P";1:status_char="I";2:status_char="C";3:status_char="1"+index_frame;
                5:status_char=auto_frame ? "A" : "M";
                6:status_char=auto_frame ? "U" : "A";
                7:status_char=auto_frame ? "T" : "N";
                8:status_char=auto_frame ? "O" : "U";
                9:status_char=auto_frame ? " " : "A";10:status_char=auto_frame ? " " : "L";
                default:status_char=" ";
            endcase
            if(error_frame!=0) begin
                case(n)
                    12:status_char="E";13:status_char="R";14:status_char="R";
                    16:status_char=hex_char(error_frame[7:4]);17:status_char=hex_char(error_frame[3:0]);
                    19:status_char="D";20:status_char=hex_char(detail_frame[7:4]);21:status_char=hex_char(detail_frame[3:0]);
                    default:begin end
                endcase
            end else begin
                case(n)
                    12:status_char=loading_frame ? "L" : "R";
                    13:status_char=loading_frame ? "O" : "E";
                    14:status_char="A";
                    15:status_char="D";
                    16:status_char=loading_frame ? " " : "Y";
                    default:begin end
                endcase
            end
        end
    endfunction
    function [7:0] param_char;
        input [5:0] n;
        begin
            case(n)
                0:param_char="V";
                1:param_char="0"+numbers_frame[31:28];2:param_char="0"+numbers_frame[27:24];3:param_char="0"+numbers_frame[23:20];
                5:param_char="B";
                6:param_char="0"+numbers_frame[43:40];7:param_char="0"+numbers_frame[39:36];8:param_char="0"+numbers_frame[35:32];
                10:param_char="C";
                11:param_char="0"+numbers_frame[55:52];12:param_char="0"+numbers_frame[51:48];13:param_char="0"+numbers_frame[47:44];
                15:param_char="P";
                16:param_char="0"+numbers_frame[19:16];17:param_char="0"+numbers_frame[15:12];18:param_char=".";
                19:param_char="0"+numbers_frame[11:8];20:param_char="0"+numbers_frame[7:4];21:param_char="0"+numbers_frame[3:0];22:param_char="S";
                24:param_char=scale_frame ? "1" : "6";
                25:param_char=scale_frame ? "2" : "4";
                26:param_char=scale_frame ? "8" : "0";
                27:param_char=scale_frame ? "0" : "X";
                28:param_char=scale_frame ? "X" : "4";
                29:param_char=scale_frame ? "9" : "8";
                30:param_char=scale_frame ? "6" : "0";
                31:param_char=scale_frame ? "0" : " ";
                default:param_char=" ";
            endcase
        end
    endfunction
    localparam [255:0] CN_GLYPH_0 = 256'b0111110111111100010001000100010001000100010001000100010001000100010001001001010001111101000010000100010011111100010001001000010001000100100001000100010010000100011111001111110000000000000000000100100010001000010001000100010010000100010001000000000000000000;
    localparam [255:0] CN_GLYPH_1 = 256'b0000000001000000000100000100000000010000010000000001000001000000000100000100000000011111111111000001000000000000000100000000000000010000000000000001111111100000000100000010000000010000001000000001000000100000001000000010000000100000001000000100000000100000;
    localparam [255:0] CN_GLYPH_2 = 256'b0000001000000000000000010000000000111111111110000000000000000000000010000010000000000100010000001111111111111110000000000000000000011111111100000001000000010000000100000001000000011111111100000001000000010000000100000001000000011111111100000001000000010000;
    localparam [255:0] CN_GLYPH_3 = 256'b0000000000100000000000001111000000011111000000000001000000000000000100010000000000100001000000000010000100000000001111111111110000000001000000000000100100100000000010010001000000010001000010000010000100000100010000010000010000000101000000000000001000000000;
    localparam [255:0] CN_GLYPH_4 = 256'b0010000001111000001001111100000000100010010010000010000101010000111110111111110000100001010100000010001001001000001011000000011000110011111110001110001001001000001000100100100000100011111110000010001001001000001000100100100010100011111110000100001000001000;
    localparam [255:0] CN_GLYPH_5 = 256'b0010000001000000000100000100000000000000010000001111111010000000001000001111111000100001000010000011111010001000001001001000100000100100100010000010010001010000001001000101000000100100001000000100010001010000010101001000100010001001000001000000001000000010;
    localparam [255:0] CN_GLYPH_6 = 256'b0011111001111100001000100100010000100010010001000011111001111100000000010010000000000001000100001111111111111110000000101000000000001100011000000011000000011000110000000000011000111110011111000010001001000100001000100100010000111110011111000000000000000000;
    localparam [255:0] CN_GLYPH_7 = 256'b0000001000000000000000010000000000111111111111000010000000000100010000100000100000000010000000000000001000000000111111111111111000000100001000000000100000100000000110000100000000000110010000000000000110000000000000100110000000001100000100000111000000001000;
    localparam [255:0] CN_GLYPH_8 = 256'b0000000001000000011111000100000001000100011110000100010010001000010001010101000001111100001000000001000001010000000100001000100000010001000001100101110011111000010100001000100001010000100010000101000010001000010111001000100011100000111110000000000010001000;

    function [15:0] chinese_glyph_row;
        input [3:0] glyph_id;
        input [3:0] row;
        reg [255:0] glyph_bits;
        begin
            case (glyph_id)
                4'd0: glyph_bits = CN_GLYPH_0;
                4'd1: glyph_bits = CN_GLYPH_1;
                4'd2: glyph_bits = CN_GLYPH_2;
                4'd3: glyph_bits = CN_GLYPH_3;
                4'd4: glyph_bits = CN_GLYPH_4;
                4'd5: glyph_bits = CN_GLYPH_5;
                4'd6: glyph_bits = CN_GLYPH_6;
                4'd7: glyph_bits = CN_GLYPH_7;
                4'd8: glyph_bits = CN_GLYPH_8;
                default: glyph_bits = 256'b0;
            endcase
            chinese_glyph_row = glyph_bits[255-row*16 -: 16];
        end
    endfunction

    function [4:0] glyph_row;
        input [7:0] character;
        input [2:0] row;
        begin
            glyph_row = 5'b00000;
            case (character)
                "0": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10011;3:glyph_row=5'b10101;4:glyph_row=5'b11001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "1": case(row) 0:glyph_row=5'b00100;1:glyph_row=5'b01100;2:glyph_row=5'b00100;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "2": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b00001;3:glyph_row=5'b00010;4:glyph_row=5'b00100;5:glyph_row=5'b01000;6:glyph_row=5'b11111;default:glyph_row=0;endcase
                "3": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b00001;2:glyph_row=5'b00001;3:glyph_row=5'b01110;4:glyph_row=5'b00001;5:glyph_row=5'b00001;6:glyph_row=5'b11110;default:glyph_row=0;endcase
                "4": case(row) 0:glyph_row=5'b00010;1:glyph_row=5'b00110;2:glyph_row=5'b01010;3:glyph_row=5'b10010;4:glyph_row=5'b11111;5:glyph_row=5'b00010;6:glyph_row=5'b00010;default:glyph_row=0;endcase
                "5": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b00001;5:glyph_row=5'b00001;6:glyph_row=5'b11110;default:glyph_row=0;endcase
                "6": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "7": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b00001;2:glyph_row=5'b00010;3:glyph_row=5'b00100;4:glyph_row=5'b01000;5:glyph_row=5'b01000;6:glyph_row=5'b01000;default:glyph_row=0;endcase
                "8": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b01110;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "9": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b01111;4:glyph_row=5'b00001;5:glyph_row=5'b00001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "A": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11111;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "B": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11110;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b11110;default:glyph_row=0;endcase
                "C": case(row) 0:glyph_row=5'b01111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b10000;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b01111;default:glyph_row=0;endcase
                "D": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b11110;default:glyph_row=0;endcase
                "E": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b11111;default:glyph_row=0;endcase
                "F": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b10000;default:glyph_row=0;endcase
                "G": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10000;3:glyph_row=5'b10111;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "H": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11111;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "I": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b00100;2:glyph_row=5'b00100;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "J": case(row) 0:glyph_row=5'b00111;1:glyph_row=5'b00010;2:glyph_row=5'b00010;3:glyph_row=5'b00010;4:glyph_row=5'b10010;5:glyph_row=5'b10010;6:glyph_row=5'b01100;default:glyph_row=0;endcase
                "K": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10010;2:glyph_row=5'b10100;3:glyph_row=5'b11000;4:glyph_row=5'b10100;5:glyph_row=5'b10010;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "L": case(row) 0:glyph_row=5'b10000;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b10000;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b11111;default:glyph_row=0;endcase
                "M": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b11011;2:glyph_row=5'b10101;3:glyph_row=5'b10101;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "N": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b11001;2:glyph_row=5'b10101;3:glyph_row=5'b10011;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "O": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "P": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11110;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b10000;default:glyph_row=0;endcase
                "Q": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10101;5:glyph_row=5'b10010;6:glyph_row=5'b01101;default:glyph_row=0;endcase
                "R": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11110;4:glyph_row=5'b10100;5:glyph_row=5'b10010;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "S": case(row) 0:glyph_row=5'b01111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b01110;4:glyph_row=5'b00001;5:glyph_row=5'b00001;6:glyph_row=5'b11110;default:glyph_row=0;endcase
                "T": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b00100;2:glyph_row=5'b00100;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b00100;default:glyph_row=0;endcase
                "U": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "V": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10001;5:glyph_row=5'b01010;6:glyph_row=5'b00100;default:glyph_row=0;endcase
                "W": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10101;4:glyph_row=5'b10101;5:glyph_row=5'b10101;6:glyph_row=5'b01010;default:glyph_row=0;endcase
                "X": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b01010;3:glyph_row=5'b00100;4:glyph_row=5'b01010;5:glyph_row=5'b10001;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "Y": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b01010;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b00100;default:glyph_row=0;endcase
                "Z": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b00001;2:glyph_row=5'b00010;3:glyph_row=5'b00100;4:glyph_row=5'b01000;5:glyph_row=5'b10000;6:glyph_row=5'b11111;default:glyph_row=0;endcase
                ":": case(row) 1:glyph_row=5'b00100;2:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;default:glyph_row=0;endcase
                ".": case(row) 5:glyph_row=5'b00100;6:glyph_row=5'b00100;default:glyph_row=0;endcase
                ",": case(row) 5:glyph_row=5'b00100;6:glyph_row=5'b01000;default:glyph_row=0;endcase
                "!": case(row) 0:glyph_row=5'b00100;1:glyph_row=5'b00100;2:glyph_row=5'b00100;3:glyph_row=5'b00100;5:glyph_row=5'b00100;default:glyph_row=0;endcase
                "?": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b00010;3:glyph_row=5'b00100;5:glyph_row=5'b00100;default:glyph_row=0;endcase
                "-": case(row) 3:glyph_row=5'b11111;default:glyph_row=0;endcase
                "_": case(row) 6:glyph_row=5'b11111;default:glyph_row=0;endcase
                "/": case(row) 0:glyph_row=5'b00001;1:glyph_row=5'b00010;2:glyph_row=5'b00010;3:glyph_row=5'b00100;4:glyph_row=5'b01000;5:glyph_row=5'b01000;6:glyph_row=5'b10000;default:glyph_row=0;endcase
                default: glyph_row = 5'b00000;
            endcase
        end
    endfunction

    // One font-selection path for all blocks, including the subtitle's
    // existing fixed Chinese glyph IDs. The second lookup offsets by (1,1)
    // to draw a shadow only where a letter exists; backgrounds stay intact.
    function text_pixel;
        input [9:0] px,py;
        reg [9:0] lx,ly,sx;
        reg [5:0] cell_idx;
        reg [4:0] col;
        reg [7:0] ch;
        reg [4:0] row_bits;
        reg [15:0] cn_bits;
        reg found,sub;
        begin
            lx=0;ly=0;cell_idx=0;col=0;ch=" ";found=0;sub=0;text_pixel=0;
            row_bits=0;cn_bits=0;sx=px+scroll_pos;
            if(sx>=SCROLL_CYCLE) sx=sx-SCROLL_CYCLE;
            if(py>=STATUS_Y && py<STATUS_Y+CELL_H && px>=STATUS_X && px<STATUS_X+22*CELL_W) begin
                lx=px-STATUS_X;ly=py-STATUS_Y;cell_idx=lx/CELL_W;
                col=(lx-cell_idx*CELL_W)>>1;ch=status_char(cell_idx);found=1;
            end else if(py>=PARAM_Y && py<PARAM_Y+CELL_H && px>=PARAM_X && px<PARAM_X+PARAM_CHARS*CELL_W) begin
                lx=px-PARAM_X;ly=py-PARAM_Y;cell_idx=lx/CELL_W;
                col=(lx-cell_idx*CELL_W)>>1;ch=param_char(cell_idx);found=1;
            end else if(py>=STATUS_Y && py<STATUS_Y+CELL_H && px>=TIMER_X && px<TIMER_X+5*CELL_W) begin
                lx=px-TIMER_X;ly=py-STATUS_Y;cell_idx=lx/CELL_W;
                col=(lx-cell_idx*CELL_W)>>1;found=1;
                case(cell_idx)
                    0:ch="0"+mm_tens;1:ch="0"+mm_ones;2:ch=":";
                    3:ch="0"+ss_tens;4:ch="0"+ss_ones;default:ch=" ";
                endcase
            end else if(subtitle_on_frame && py>=SUBTITLE_Y && py<SUBTITLE_Y+18 && px>=8 && px<H_ACTIVE-8 && sx<subtitle_length_frame*SUBTITLE_CELL_W) begin
                cell_idx=sx/SUBTITLE_CELL_W;col=sx-cell_idx*SUBTITLE_CELL_W;ly=py-SUBTITLE_Y;
                ch=subtitle_frame[cell_idx*8 +: 8];found=1;sub=1;
            end
            if(found) begin
                if(sub && ch[7]) begin
                    if(col>=1 && col<17 && ly>=2 && ly<18) begin
                        cn_bits=chinese_glyph_row(ch[3:0],ly-2);
                        text_pixel=cn_bits[16-col];
                    end
                end else if(sub) begin
                    if(col>=4 && col<14 && ly>=2 && ly<16) begin
                        row_bits=glyph_row(ch,(ly-2)>>1);
                        text_pixel=row_bits[4-((col-4)>>1)];
                    end
                end else if(col<5 && ly<14) begin
                    row_bits=glyph_row(ch,ly>>1);text_pixel=row_bits[4-col];
                end
            end
        end
    endfunction
    wire ink=enable && de && text_pixel(pixel_x,pixel_y);
    // Clip the subtitle shadow at the same horizontal edge as its text.
    wire shadow=enable && de && pixel_x!=0 && pixel_y!=0 &&
        !(pixel_y>=SUBTITLE_Y && pixel_y<=SUBTITLE_Y+18 && (pixel_x<8 || pixel_x>=H_ACTIVE-8)) &&
        text_pixel(pixel_x-10'd1,pixel_y-10'd1);
    assign overlay_active=ink || shadow;
    assign rgb_out=ink ? 24'heef6fa : shadow ? 24'h162430 : rgb_in;
endmodule
