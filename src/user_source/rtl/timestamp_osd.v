`timescale 1ns/1ps

// R3'-B: timestamp OSD - MM:SS elapsed-time counter rendered in the top
// right corner. The topic's first example for extension 1 is "叠加动态文字
// （如时间戳或标语）" - we have the slogan but not the timestamp. This module
// counts frames at 60 Hz and renders a "MM:SS" overlay.
module timestamp_osd #(
    parameter integer OSD_X = 500,            // right-aligned-ish
    parameter integer OSD_Y = 8,              // top row, same as status OSD
    parameter integer CHAR_W = 8,             // 8x16 pixel characters
    parameter integer CHAR_H = 16
) (
    input  wire        pix_clk,
    input  wire        pix_rst_n,
    input  wire        enable,
    input  wire        vsync,
    input  wire        de,
    input  wire [9:0]  pixel_x,
    input  wire [11:0] pixel_y,
    input  wire [23:0] rgb_in,
    output wire [23:0] rgb_out,
    output wire        ts_active,
    // sys domain: reset the timer
    input  wire        sys_rst_n
);
    // 25MHz / (800*525) = 59.5238Hz；以像素周期累加，不能用60帧冒充1秒。
    reg [24:0] frame_cycles;
    reg [3:0] mm_tens,mm_ones,ss_tens,ss_ones;
    reg vs_q;
    wire frame_start=vs_q && !vsync;
    always @(posedge pix_clk or negedge pix_rst_n)
        if(!pix_rst_n) begin
            frame_cycles<=0;mm_tens<=0;mm_ones<=0;ss_tens<=0;ss_ones<=0;vs_q<=1;
        end else begin
            vs_q<=vsync;
            if(frame_start) begin
                if(frame_cycles>=25000000-420000) begin
                    frame_cycles<=frame_cycles+420000-25000000;
                    if(ss_ones!=9) ss_ones<=ss_ones+1'b1;
                    else begin ss_ones<=0;
                        if(ss_tens!=5) ss_tens<=ss_tens+1'b1;
                        else begin ss_tens<=0;
                            if(mm_ones!=9) mm_ones<=mm_ones+1'b1;
                            else begin mm_ones<=0;mm_tens<=mm_tens==9?0:mm_tens+1'b1;end
                        end
                    end
                end else frame_cycles<=frame_cycles+420000;
            end
        end

    // pixel offset within the character block
    wire [9:0] dx = pixel_x - OSD_X;
    wire [11:0] dy = pixel_y - OSD_Y;

    // active when in the 5-character region
    wire in_region = enable && de &&
                     pixel_x >= OSD_X && pixel_x < OSD_X + 5 * CHAR_W &&
                     pixel_y >= OSD_Y && pixel_y < OSD_Y + CHAR_H;

    assign ts_active = in_region;

    // 4x6 pixel font (doubled to 8x12 effective, leaves 4px padding)
    // Each digit is 4 wide x 6 tall, doubled vertically = 12 rows
    function font_pixel;
        input [3:0] digit;
        input [3:0] col;   // 0..3
        input [3:0] row;   // 0..5 (logical row before doubling)
        begin
            case (digit)
                4'd0: font_pixel = (row==0 && (col==1||col==2)) ||
                                   (row==1 && (col==0||col==3)) ||
                                   (row==2 && (col==0||col==3)) ||
                                   (row==3 && (col==0||col==3)) ||
                                   (row==4 && (col==0||col==3)) ||
                                   (row==5 && (col==1||col==2));
                4'd1: font_pixel = (col==2) ||
                                   (row==0 && col==1) ||
                                   (row==2 && (col==1||col==3)) ||
                                   (row==5 && (col==1||col==2||col==3));
                4'd2: font_pixel = (row==0 && (col==1||col==2)) ||
                                   (row==1 && col==3) ||
                                   (row==2 && (col==1||col==2)) ||
                                   (row==3 && col==1) ||
                                   (row==4 && col==0) ||
                                   (row==5 && (col==1||col==2||col==3));
                4'd3: font_pixel = (row==0 && (col==1||col==2)) ||
                                   (row==1 && col==3) ||
                                   (row==2 && (col==1||col==2)) ||
                                   (row==3 && col==3) ||
                                   (row==4 && col==3) ||
                                   (row==5 && (col==1||col==2));
                4'd4: font_pixel = (row==0 && (col==0||col==3)) ||
                                   (row==1 && (col==0||col==3)) ||
                                   (row==2 && (col==0||col==1||col==2||col==3)) ||
                                   (row==3 && col==3) ||
                                   (row==4 && col==3) ||
                                   (row==5 && col==3);
                4'd5: font_pixel = (row==0 && (col==0||col==1||col==2||col==3)) ||
                                   (row==1 && col==0) ||
                                   (row==2 && (col==0||col==1||col==2)) ||
                                   (row==3 && col==3) ||
                                   (row==4 && col==3) ||
                                   (row==5 && (col==1||col==2));
                4'd6: font_pixel = (row==0 && (col==1||col==2)) ||
                                   (row==1 && col==0) ||
                                   (row==2 && (col==0||col==1||col==2)) ||
                                   (row==3 && (col==0||col==3)) ||
                                   (row==4 && (col==0||col==3)) ||
                                   (row==5 && (col==1||col==2));
                4'd7: font_pixel = (row==0 && (col==0||col==1||col==2||col==3)) ||
                                   (row==1 && col==3) ||
                                   (row==2 && col==2) ||
                                   (row==3 && col==2) ||
                                   (row==4 && col==2) ||
                                   (row==5 && col==2);
                4'd8: font_pixel = (row==0 && (col==1||col==2)) ||
                                   (row==1 && (col==0||col==3)) ||
                                   (row==2 && (col==1||col==2)) ||
                                   (row==3 && (col==0||col==3)) ||
                                   (row==4 && (col==0||col==3)) ||
                                   (row==5 && (col==1||col==2));
                4'd9: font_pixel = (row==0 && (col==1||col==2)) ||
                                   (row==1 && (col==0||col==3)) ||
                                   (row==2 && (col==1||col==2||col==3)) ||
                                   (row==3 && col==3) ||
                                   (row==4 && col==3) ||
                                   (row==5 && (col==1||col==2));
                default: font_pixel = 1'b0;
            endcase
        end
    endfunction

    // colon character (between MM and SS)
    function colon_pixel;
        input [3:0] col;
        input [3:0] row;
        begin
            colon_pixel = (col >= 1 && col <= 2) &&
                          ((row >= 1 && row <= 2) || (row >= 3 && row <= 4));
        end
    endfunction

    // determine which digit this pixel belongs to and render
    reg ts_pixel;
    wire [3:0] fcol = dx % CHAR_W;
    wire [3:0] frow = (dy % CHAR_H) / 2;
    always @* begin
        ts_pixel = 1'b0;
        if (in_region && dx < 5 * CHAR_W && dy < CHAR_H) begin
            if (frow < 6) begin
                case (dx / CHAR_W)
                3'd0: ts_pixel = font_pixel(mm_tens, fcol, frow);
                3'd1: ts_pixel = font_pixel(mm_ones, fcol, frow);
                3'd2: ts_pixel = colon_pixel(fcol, frow);
                3'd3: ts_pixel = font_pixel(ss_tens, fcol, frow);
                3'd4: ts_pixel = font_pixel(ss_ones, fcol, frow);
                default: ts_pixel = 1'b0;
                endcase
            end
        end
    end

    // overlay: white-ish text with dark shadow for readability
    assign rgb_out = ts_pixel ? 24'hE0F0FF : rgb_in;
endmodule
