`timescale 1ns/1ps

// Photo-first OSD. Numeric conversion runs only on a field change; all
// visible values are committed in vertical blanking. Pixel work is font
// lookup and color selection, with no decimal division or DSP operations.
//
// 模块职责：照片优先界面的文字叠加层（状态行 / 参数行 / 计时 / 滚动字幕），
//           同时负责给文字画一像素深色阴影，保证浅色字在任何照片上都可读。
// 位置：上游是 media_video_pipeline 的 RGB 与坐标，以及顶层用 frame_config_cdc
//       在帧边界提交过来的参数；下游是 promax_audio_waveform，再往后进 HDMI 编码。
// 时钟域：25MHz 像素时钟，单域；所有跨域参数都在顶层已完成帧提交。
// 输入约定：pixel_x/pixel_y 是当前像素坐标，de 表示有效像素，vsync 用来定位帧边界；
//       loading/error_code/error_detail 来自装载链，用来显示 LOAD/READY 和 ERR xx Dxx。
// 输出约定：rgb_out 是叠加后的像素；overlay_active 表示本像素被文字或阴影占用。
//
// 三个关键设计：
//   1) 十进制转换只在"数值变化时"启动（numeric_inputs != numeric_seen），
//      用 double-dabble（每拍移一位、逐位加 3 修正）在 16 拍内算出 BCD，
//      所以像素路径上完全没有除法器，也不需要 DSP。
//   2) 所有要显示的数值/状态先存进 *_pending，等到 vsync 下降沿（帧边界）
//      才整体搬到 *_frame，一帧之内显示内容恒定，不会看到数字跳动到一半。
//   3) 字形是 5×7 点阵的硬编码查表（glyph_row），中文短句是 16×16 位图
//      （chinese_glyph_row）；阴影就是把同一查表按 (x−1, y−1) 再查一次，
//      只在"笔画存在"的位置画深色，背景像素保持原照片不变。
module promax_text_overlay #(
    parameter integer PARAM_X=96, PARAM_Y=40, STATUS_X=96, STATUS_Y=24,
    parameter integer SUBTITLE_Y=72, H_ACTIVE=640, TIMER_X=564
)(
    input wire clk,rst_n,vsync,de,
    input wire [23:0] rgb_in,
    input wire [9:0] pixel_x,pixel_y,
    input wire enable,show_info,subtitle_enable,
    input wire [95:0] subtitle_text,
    input wire [5:0] subtitle_length,
    input wire [7:0] contrast,brightness,volume,
    input wire [31:0] period_ms,
    input wire auto_enabled,source_scale_2x,
    input wire [2:0] active_index,
    input wire loading,
    input wire [7:0] error_code,error_detail,
    input wire elevator_status_valid,elevator_signal_lost,elevator_floor_basement,
    input wire [3:0] elevator_floor_tens,elevator_floor_ones,
    input wire [1:0] elevator_direction,elevator_door,
    input wire elevator_alert,
    output wire [23:0] rgb_out,
    output wire overlay_active
);
    // ===== 帧边界寄存与滚动状态 =====
    // vs_q 用于检测 vsync 下降沿；所有 *_frame 寄存器都在这个边沿更新，
    // 保证"一帧内看到的参数是同一个快照"。scroll_pos 是字幕横向滚动位置，
    // 每 3 帧才推进一步（scroll_div 计数），所以滚动速度与帧率无关地保持匀速。
    localparam integer CELL_W=12, CELL_H=16, PARAM_CHARS=32, FLOOR_X=96;
    localparam integer SUBTITLE_CELL_W=18, SCROLL_CYCLE=H_ACTIVE+128;
    reg vs_q;
    wire frame_start=vs_q && !vsync;
    reg [9:0] scroll_pos;
    reg [1:0] scroll_div;
    reg [2:0] index_frame;
    reg show_info_frame;
    reg auto_frame,loading_frame,scale_frame;
    reg [7:0] error_frame,detail_frame;
    reg [95:0] subtitle_frame;
    reg [5:0] subtitle_length_frame;
    reg subtitle_on_frame;

    // 需要显示的四个数值打包成 41bit 比较：只要其中任何一项变了就重新转换。
    // 转换结果先放 numbers_pending，帧边界再进 numbers_frame。
    wire [40:0] numeric_inputs={source_scale_2x,contrast,brightness,volume,period_ms[15:0]};
    reg [40:0] numeric_seen;
    reg convert_busy,numeric_scale_pending;
    reg [3:0] convert_step;
    reg [15:0] bin_c,bin_b,bin_v,bin_p;
    reg [11:0] bcd_c,bcd_b,bcd_v;
    reg [19:0] bcd_p;
    reg [55:0] numbers_pending,numbers_frame;
    // Double dabble: one bit per clock, constant-sized nibble adders.
    // 二进制转 BCD：每拍把二进制数左移一位，同时在每个十进制半字节里
    // "满 5 加 3"，16 拍后各半字节就是十进制位。只用 4bit 加法器，
    // 没有除法也没有乘法，所以适合放在像素时钟上做。
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
    // ===== 数值转换 + 帧边界提交 + 计时 =====
    // 这一块是整模块唯一的时序逻辑：负责"何时启动十进制转换"、
    // "帧边界搬快照"和"计时器进位"三件事。
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            vs_q<=1;scroll_pos<=0;scroll_div<=0;index_frame<=0;show_info_frame<=0;
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
                index_frame<=active_index;show_info_frame<=show_info;
                auto_frame<=auto_enabled;loading_frame<=loading;
                error_frame<=error_code;detail_frame<=error_detail;
                subtitle_frame<=subtitle_text;subtitle_length_frame<=subtitle_length;subtitle_on_frame<=subtitle_enable;
                if(scroll_div==2) begin
                    scroll_div<=0;scroll_pos<=scroll_pos==SCROLL_CYCLE-1 ? 0 : scroll_pos+1'b1;
                end else scroll_div<=scroll_div+1'b1;
                // Existing 25 MHz / 800x525 clock: retain actual elapsed time.
                // 计时器按真实帧时长累加：每帧加 420000 个像素时钟（800×525 = 420000），
                // 累到 25M（1 秒）就秒进位，所以显示的是实际经过时间而不是帧计数。
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
    // ===== 各字段的字符生成（纯查表/组合，无时序） =====
    // 状态行、参数行、计时行的每个字符位置都由下面几个函数决定；
    // 位置编号（n）对应字符格序号，空位一律输出空格。
    // 数值一律用十六进制显示（hex_char），例如错误码 ERR 86。
    function [7:0] hex_char;
        input [3:0] n;
        begin hex_char=n<10 ? "0"+n : "A"+(n-10);end
    endfunction
    // 状态行：前半是 "PIC1 MANUAL/AUTO"，后半是 "LOAD/READY"；
    // 一旦有错误码，后半段改显示 "ERR xx Dxx"（xx=错误码，Dxx=细分码）。
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
    function [7:0] elevator_char;
        input [3:0] n;
        begin
            case(n)
                0: elevator_char="F";
                1: elevator_char=elevator_status_valid && !elevator_signal_lost ?
                    (elevator_floor_basement ? "B" : ("0"+elevator_floor_tens)) : "-";
                2: elevator_char=elevator_status_valid && !elevator_signal_lost ?
                    ("0"+elevator_floor_ones) : "-";
                3: elevator_char=elevator_signal_lost ? "!" :
                    (elevator_direction==2'd1 ? "U" : elevator_direction==2'd2 ? "D" : "S");
                4: elevator_char=elevator_signal_lost ? "L" :
                    (elevator_door==2'd1 ? "O" : elevator_door==2'd2 ? "C" : "M");
                5: elevator_char=elevator_alert ? "!" : " ";
                6: elevator_char=elevator_alert ? "A" : " ";
                7: elevator_char=elevator_alert ? "L" : " ";
                8: elevator_char=elevator_alert ? "T" : " ";
                default: elevator_char=" ";
            endcase
        end
    endfunction
    // 参数行：V 音量(3位) B 亮度(3位) C 对比度(3位) P 周期(带小数点和单位 S)，
    // 末尾显示源图尺寸（640X480 或 1280X960）；数字都取自 numbers_frame 的 BCD 半字节，
    // 加 '0' 直接变 ASCII，所以像素路径上没有十进制运算。
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
    // ===== 中文短句字形：9 个 16×16 点阵，共 6 个汉字 =====
    // 每个 localparam 是 256bit 位图，按"第 0 行在高位、每行 16 位"排列；
    // chinese_glyph_row 按行号把对应 16 位切出来，正好对上点阵的行序。
    // 这是内置的固定短句（"照片音乐"），不做通用中文字库。
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

    // ===== ASCII 字形表：5×7 点阵，每行 5bit（高位在左） =====
    // 只收常用大写字母、数字和少量标点；未定义字符返回全 0（显示为空白）。
    // 字符格 12×16，字形按 2 倍横向放大、纵向两行取一行，所以 5×7 能填满格子。
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
    //
    // 统一的"这个像素是不是文字"判定：按坐标先判断落在哪个区块
    // （状态行 / 参数行 / 计时行 / 滚动字幕），再取出该位置的字符，
    // 最后查字形表得到该像素是否为笔画。四个区块互斥，靠 if-else 优先级决定。
    // 字幕分支里 sx=px+scroll_pos 就是横向滚动偏移，超出文本长度则不画。
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
            // 四个区块的坐标判定：lx/ly 是区块内局部坐标，cell_idx 是第几个字符格，
            // col 是字符格内的横向像素（右移 1 位即 2 倍横向放大）。
            if(py>=4 && py<4+CELL_H && px>=FLOOR_X && px<FLOOR_X+9*CELL_W) begin
                lx=px-FLOOR_X;ly=py-4;cell_idx=lx/CELL_W;
                col=(lx-cell_idx*CELL_W)>>1;ch=elevator_char(cell_idx);found=1;
            end else if((show_info_frame || error_frame!=0) && py>=STATUS_Y && py<STATUS_Y+CELL_H && px>=STATUS_X && px<STATUS_X+22*CELL_W) begin
                lx=px-STATUS_X;ly=py-STATUS_Y;cell_idx=lx/CELL_W;
                col=(lx-cell_idx*CELL_W)>>1;ch=status_char(cell_idx);found=1;
            end else if(show_info_frame && py>=PARAM_Y && py<PARAM_Y+CELL_H && px>=PARAM_X && px<PARAM_X+PARAM_CHARS*CELL_W) begin
                lx=px-PARAM_X;ly=py-PARAM_Y;cell_idx=lx/CELL_W;
                col=(lx-cell_idx*CELL_W)>>1;ch=param_char(cell_idx);found=1;
            end else if(show_info_frame && py>=STATUS_Y && py<STATUS_Y+CELL_H && px>=TIMER_X && px<TIMER_X+5*CELL_W) begin
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
                // 字幕（sub=1）分两种情况：ch[7]=1 是中文短句，用 16×16 点阵，
                // 只在格子内 (1..16, 2..17) 的窗口取位；否则按 ASCII 5×7 点阵，
                // 同样留出内边距，避免不同字号混排时基线错位。
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
    // ===== 最终叠加：笔画画浅色，阴影画深色，其余保持照片原样 =====
    // 阴影不是"整块底色"，而是把同一个字形按 (x−1,y−1) 再查一次：
    // 只有笔画存在的位置才落深色，所以照片不会被铺上一层底板。
    // 字幕阴影额外裁剪到与文字相同的左右边界内，防止在画面边缘露边。
    wire ink=enable && de && text_pixel(pixel_x,pixel_y);
    // Clip the subtitle shadow at the same horizontal edge as its text.
    wire shadow=enable && de && pixel_x!=0 && pixel_y!=0 &&
        !(pixel_y>=SUBTITLE_Y && pixel_y<=SUBTITLE_Y+18 && (pixel_x<8 || pixel_x>=H_ACTIVE-8)) &&
        text_pixel(pixel_x-10'd1,pixel_y-10'd1);
    assign overlay_active=ink || shadow;
    assign rgb_out=ink ? 24'heef6fa : shadow ? 24'h162430 : rgb_in;
endmodule
