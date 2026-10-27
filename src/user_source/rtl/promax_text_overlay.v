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
    output wire overlay_active,
    input wire [15:0] rescue_event_id,
    input wire [1:0] rescue_comm_state
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
    reg alert_frame;
    reg [1:0] comm_frame;
    reg [15:0] event_frame;
    reg [6:0] clear_frames;
    always @(posedge clk or negedge rst_n)
        if(!rst_n) begin alert_frame<=0;comm_frame<=0;event_frame<=0;clear_frames<=0;end
        else if(frame_start) begin
            alert_frame<=(elevator_alert === 1'b1);
            comm_frame<=rescue_comm_state;event_frame<=rescue_event_id;
            if(elevator_alert === 1'b1) clear_frames<=0;
            else if(alert_frame) clear_frames<=120;
            else if(clear_frames!=0) clear_frames<=clear_frames-1'b1;
        end

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

    // BEGIN FIXED EMERGENCY GLYPHS (generated by tools/generate_emergency_glyphs.py)
    localparam [255:0] CN_GLYPH_9 = 256'h000000003ffc008000801080108010fc108010801080108010807ffe00000000; // 正
    localparam [255:0] CN_GLYPH_10 = 256'h00000000020002007ffe04000840104017fc30405040104010401ffe00000000; // 在
    localparam [255:0] CN_GLYPH_11 = 256'h00000000001c3df02420252c24b8242027fc24203c202420002001e000000000; // 呼
    localparam [255:0] CN_GLYPH_12 = 256'h0000000000043e44224422442244224422442244227c3e642204000400000000; // 叫
    localparam [255:0] CN_GLYPH_13 = 256'h0000204017fe084003fc704017fe120413fc120417fc1a04223c000000000000; // 请
    localparam [255:0] CN_GLYPH_14 = 256'h0000000000b000983ffe008018840cd800b003b00c8c30860080078000000000; // 求
    localparam [255:0] CN_GLYPH_15 = 256'h000000001ff800080008100810081ff8100810001002100210060ffc00000000; // 已
    localparam [255:0] CN_GLYPH_16 = 256'h00001040102013fc7d08109017fc18c077fc120811d01070778c000000000000; // 接
    localparam [255:0] CN_GLYPH_17 = 256'h000000000440048024fe25082508268824903c503460046004d8070600000000; // 收
    localparam [255:0] CN_GLYPH_18 = 256'h0000000023fc111808e003fc724413fc124413fc1244127c280047fe00000000; // 通
    localparam [255:0] CN_GLYPH_19 = 256'h0000000008601ffe100033fc700053fc100013fc1204120413fc120400000000; // 信
    localparam [255:0] CN_GLYPH_20 = 256'h00000000010001003ff8010001007ffc0380054009203110610c010000000000; // 未
    localparam [255:0] CN_GLYPH_21 = 256'h0000000000403ef8091013fc1d2435fc3524552415fc1d241324023c00000000; // 确
    localparam [255:0] CN_GLYPH_22 = 256'h0000000020401040084000407040104010a014a01ca019101208040400000000; // 认
    localparam [255:0] CN_GLYPH_23 = 256'h0000000008801ffc208000807ffe00001ff81008100810081ff8100800000000; // 告
    localparam [255:0] CN_GLYPH_24 = 256'h0000000009103ffe20e43e9c12981fe600803ffe00000ff808080ff800000000; // 警
    localparam [255:0] CN_GLYPH_25 = 256'h000010fc3c4428447ebc2b003e502afe2a903efe2a1062104e10000000000000; // 解
    localparam [255:0] CN_GLYPH_26 = 256'h000000003c60247028902b0c2ffa242027fe24203d282224242221e000000000; // 除
    localparam [255:0] CN_GLYPH_27 = 256'h000000000bfc1a041204120433fc7244504017fe10e011501248144600000000; // 保
    localparam [255:0] CN_GLYPH_28 = 256'h0000102011fc7c20102013fe1c08700813fe1008110810887078000000000000; // 持
    localparam [255:0] CN_GLYPH_29 = 256'h00000000004060a0319002c80c26000017fc3008263021e04060003000000000; // 冷
    localparam [255:0] CN_GLYPH_30 = 256'h0000000008407ff808903efc08247ffe22243e2422fc3e2422202ee000000000; // 静
    // END FIXED EMERGENCY GLYPHS

    function [15:0] chinese_glyph_row;
        input [4:0] glyph_id;
        input [3:0] row;
        begin
            // Sparse 9-bit row address, avoiding a 256-bit intermediate mux.
            case ({glyph_id,row})
                9'h0c2,9'h0cd: chinese_glyph_row=16'h0004;
                9'h0f3,9'h0f4: chinese_glyph_row=16'h0008;
                9'h0b2: chinese_glyph_row=16'h001c;
                9'h030,9'h0bc: chinese_glyph_row=16'h0020;
                9'h1dd: chinese_glyph_row=16'h0030;
                9'h010,9'h052,9'h080,9'h152,9'h165,9'h1d2: chinese_glyph_row=16'h0040;
                9'h093,9'h094,9'h0e5,9'h0ec,9'h175,9'h188: chinese_glyph_row=16'h0080;
                9'h08f: chinese_glyph_row=16'h0088;
                9'h0e3: chinese_glyph_row=16'h0098;
                9'h0e2,9'h0e8: chinese_glyph_row=16'h00b0;
                9'h031: chinese_glyph_row=16'h00f0;
                9'h021,9'h038,9'h071,9'h142,9'h143,9'h145,9'h146,9'h14d: chinese_glyph_row=16'h0100;
                9'h065: chinese_glyph_row=16'h0110;
                9'h064: chinese_glyph_row=16'h0120;
                9'h07c: chinese_glyph_row=16'h0180;
                9'h0bd: chinese_glyph_row=16'h01e0;
                9'h020,9'h03f,9'h070,9'h075,9'h076,9'h0a2,9'h0a3: chinese_glyph_row=16'h0200;
                9'h05f: chinese_glyph_row=16'h0202;
                9'h15d: chinese_glyph_row=16'h023c;
                9'h07d: chinese_glyph_row=16'h0260;
                9'h067: chinese_glyph_row=16'h0280;
                9'h1d5: chinese_glyph_row=16'h02c8;
                9'h148: chinese_glyph_row=16'h0380;
                9'h0e9: chinese_glyph_row=16'h03b0;
                9'h0d4,9'h125: chinese_glyph_row=16'h03fc;
                9'h0a5: chinese_glyph_row=16'h0400;
                9'h16d: chinese_glyph_row=16'h0404;
                9'h078: chinese_glyph_row=16'h0420;
                9'h025,9'h112: chinese_glyph_row=16'h0440;
                9'h11b: chinese_glyph_row=16'h0460;
                9'h113: chinese_glyph_row=16'h0480;
                9'h11c: chinese_glyph_row=16'h04d8;
                9'h03e: chinese_glyph_row=16'h0500;
                9'h149: chinese_glyph_row=16'h0540;
                9'h07b: chinese_glyph_row=16'h0640;
                9'h11d: chinese_glyph_row=16'h0706;
                9'h0ed: chinese_glyph_row=16'h0780;
                9'h18c: chinese_glyph_row=16'h0808;
                9'h024,9'h079: chinese_glyph_row=16'h0820;
                9'h1e6: chinese_glyph_row=16'h0824;
                9'h0a6,9'h0d3,9'h164,9'h1e2: chinese_glyph_row=16'h0840;
                9'h132: chinese_glyph_row=16'h0860;
                9'h172: chinese_glyph_row=16'h0880;
                9'h1e4: chinese_glyph_row=16'h0890;
                9'h124: chinese_glyph_row=16'h08e0;
                9'h03a,9'h154,9'h182: chinese_glyph_row=16'h0910;
                9'h039,9'h14a: chinese_glyph_row=16'h0920;
                9'h1b2: chinese_glyph_row=16'h0bfc;
                9'h07e: chinese_glyph_row=16'h0c10;
                9'h1d6: chinese_glyph_row=16'h0c26;
                9'h068: chinese_glyph_row=16'h0c60;
                9'h0ea: chinese_glyph_row=16'h0c8c;
                9'h0e7: chinese_glyph_row=16'h0cd8;
                9'h18b,9'h18d: chinese_glyph_row=16'h0ff8;
                9'h0fd: chinese_glyph_row=16'h0ffc;
                9'h016,9'h017,9'h018,9'h033,9'h0f9,9'h134,9'h138: chinese_glyph_row=16'h1000;
                9'h0fa,9'h0fb: chinese_glyph_row=16'h1002;
                9'h0fc: chinese_glyph_row=16'h1006;
                9'h0f5,9'h0f6,9'h0f8,9'h179,9'h17a,9'h17b,9'h17d,9'h1c9: chinese_glyph_row=16'h1008;
                9'h029,9'h02a,9'h02c,9'h02d,9'h02f: chinese_glyph_row=16'h1010;
                9'h01a,9'h01b,9'h01c,9'h102,9'h1c1,9'h1c4: chinese_glyph_row=16'h1020;
                9'h011,9'h012,9'h013,9'h014,9'h051,9'h0a7,9'h0ab,9'h0ac,9'h101,9'h163,9'h167: chinese_glyph_row=16'h1040;
                9'h086: chinese_glyph_row=16'h1050;
                9'h10b: chinese_glyph_row=16'h1070;
                9'h095,9'h096,9'h098,9'h099,9'h09a,9'h09b,9'h09c: chinese_glyph_row=16'h1080;
                9'h087,9'h1cb: chinese_glyph_row=16'h1088;
                9'h105: chinese_glyph_row=16'h1090;
                9'h168: chinese_glyph_row=16'h10a0;
                9'h1ba: chinese_glyph_row=16'h10e0;
                9'h097,9'h191: chinese_glyph_row=16'h10fc;
                9'h034: chinese_glyph_row=16'h1100;
                9'h088: chinese_glyph_row=16'h1106;
                9'h03b,9'h1ca: chinese_glyph_row=16'h1108;
                9'h123: chinese_glyph_row=16'h1118;
                9'h1bb: chinese_glyph_row=16'h1150;
                9'h10a: chinese_glyph_row=16'h11d0;
                9'h1c2: chinese_glyph_row=16'h11fc;
                9'h0d7,9'h0d9,9'h13a,9'h13b,9'h13d,9'h1b4,9'h1b5: chinese_glyph_row=16'h1204;
                9'h109,9'h16c: chinese_glyph_row=16'h1208;
                9'h128,9'h12a: chinese_glyph_row=16'h1244;
                9'h1bc: chinese_glyph_row=16'h1248;
                9'h12b: chinese_glyph_row=16'h127c;
                9'h186: chinese_glyph_row=16'h1298;
                9'h15c: chinese_glyph_row=16'h1324;
                9'h0d8,9'h103,9'h127,9'h129,9'h139,9'h13c,9'h155: chinese_glyph_row=16'h13fc;
                9'h1c5,9'h1c8: chinese_glyph_row=16'h13fe;
                9'h1bd: chinese_glyph_row=16'h1446;
                9'h169: chinese_glyph_row=16'h14a0;
                9'h15a: chinese_glyph_row=16'h15fc;
                9'h0a8,9'h0da,9'h106,9'h1d8: chinese_glyph_row=16'h17fc;
                9'h0d2,9'h0d6,9'h1b9: chinese_glyph_row=16'h17fe;
                9'h07a: chinese_glyph_row=16'h1840;
                9'h0e6: chinese_glyph_row=16'h1884;
                9'h107: chinese_glyph_row=16'h18c0;
                9'h16b: chinese_glyph_row=16'h1910;
                9'h0db,9'h1b3: chinese_glyph_row=16'h1a04;
                9'h1c6: chinese_glyph_row=16'h1c08;
                9'h16a: chinese_glyph_row=16'h1ca0;
                9'h156,9'h15b: chinese_glyph_row=16'h1d24;
                9'h032: chinese_glyph_row=16'h1f00;
                9'h019: chinese_glyph_row=16'h1fe0;
                9'h187: chinese_glyph_row=16'h1fe6;
                9'h028,9'h02b,9'h02e: chinese_glyph_row=16'h1ff0;
                9'h0f2,9'h0f7,9'h178,9'h17c: chinese_glyph_row=16'h1ff8;
                9'h015,9'h173: chinese_glyph_row=16'h1ffc;
                9'h0ad,9'h133: chinese_glyph_row=16'h1ffe;
                9'h073: chinese_glyph_row=16'h2004;
                9'h01d,9'h01e: chinese_glyph_row=16'h2020;
                9'h050,9'h0d1,9'h162: chinese_glyph_row=16'h2040;
                9'h040: chinese_glyph_row=16'h2078;
                9'h174: chinese_glyph_row=16'h2080;
                9'h184: chinese_glyph_row=16'h20e4;
                9'h054: chinese_glyph_row=16'h20fe;
                9'h035,9'h036: chinese_glyph_row=16'h2100;
                9'h03c: chinese_glyph_row=16'h2104;
                9'h055: chinese_glyph_row=16'h2108;
                9'h043,9'h045: chinese_glyph_row=16'h2150;
                9'h1ad,9'h1db: chinese_glyph_row=16'h21e0;
                9'h0cc: chinese_glyph_row=16'h2204;
                9'h1ec: chinese_glyph_row=16'h2220;
                9'h1ab,9'h1e8: chinese_glyph_row=16'h2224;
                9'h0dc: chinese_glyph_row=16'h223c;
                9'h061,9'h062,9'h06c,9'h06d,9'h0c4,9'h0c5,9'h0c6,9'h0c7,9'h0c8,9'h0c9: chinese_glyph_row=16'h2244;
                9'h042,9'h046,9'h04a,9'h04c,9'h04d: chinese_glyph_row=16'h2248;
                9'h0ca: chinese_glyph_row=16'h227c;
                9'h1ea: chinese_glyph_row=16'h22fc;
                9'h04b: chinese_glyph_row=16'h23f8;
                9'h122: chinese_glyph_row=16'h23fc;
                9'h05b,9'h0b4,9'h0b7,9'h0b9,9'h0bb,9'h1a7,9'h1a9: chinese_glyph_row=16'h2420;
                9'h1ac: chinese_glyph_row=16'h2422;
                9'h059,9'h05a: chinese_glyph_row=16'h2450;
                9'h1a3: chinese_glyph_row=16'h2470;
                9'h057,9'h058: chinese_glyph_row=16'h2488;
                9'h118: chinese_glyph_row=16'h2490;
                9'h0b6: chinese_glyph_row=16'h24b8;
                9'h114: chinese_glyph_row=16'h24fe;
                9'h115,9'h116: chinese_glyph_row=16'h2508;
                9'h0b5: chinese_glyph_row=16'h252c;
                9'h1da: chinese_glyph_row=16'h2630;
                9'h117: chinese_glyph_row=16'h2688;
                9'h041: chinese_glyph_row=16'h27c0;
                9'h0b8: chinese_glyph_row=16'h27fc;
                9'h1a8: chinese_glyph_row=16'h27fe;
                9'h12c: chinese_glyph_row=16'h2800;
                9'h193: chinese_glyph_row=16'h2844;
                9'h1a4: chinese_glyph_row=16'h2890;
                9'h19a: chinese_glyph_row=16'h2a10;
                9'h198: chinese_glyph_row=16'h2a90;
                9'h197: chinese_glyph_row=16'h2afe;
                9'h195: chinese_glyph_row=16'h2b00;
                9'h1a5: chinese_glyph_row=16'h2b0c;
                9'h047: chinese_glyph_row=16'h2c06;
                9'h1ed: chinese_glyph_row=16'h2ee0;
                9'h1a6: chinese_glyph_row=16'h2ffa;
                9'h1d9: chinese_glyph_row=16'h3008;
                9'h069: chinese_glyph_row=16'h3018;
                9'h0a9: chinese_glyph_row=16'h3040;
                9'h0eb: chinese_glyph_row=16'h3086;
                9'h14b: chinese_glyph_row=16'h3110;
                9'h1d4: chinese_glyph_row=16'h3190;
                9'h048: chinese_glyph_row=16'h33f8;
                9'h135,9'h1b6: chinese_glyph_row=16'h33fc;
                9'h11a: chinese_glyph_row=16'h3460;
                9'h158: chinese_glyph_row=16'h3524;
                9'h157: chinese_glyph_row=16'h35fc;
                9'h0ba: chinese_glyph_row=16'h3c20;
                9'h192: chinese_glyph_row=16'h3c44;
                9'h119: chinese_glyph_row=16'h3c50;
                9'h1a2: chinese_glyph_row=16'h3c60;
                9'h1aa: chinese_glyph_row=16'h3d28;
                9'h0b3: chinese_glyph_row=16'h3df0;
                9'h1e9,9'h1eb: chinese_glyph_row=16'h3e24;
                9'h0c3: chinese_glyph_row=16'h3e44;
                9'h196: chinese_glyph_row=16'h3e50;
                9'h0cb: chinese_glyph_row=16'h3e64;
                9'h060,9'h063,9'h06b,9'h06e: chinese_glyph_row=16'h3e7c;
                9'h056: chinese_glyph_row=16'h3e88;
                9'h185: chinese_glyph_row=16'h3e9c;
                9'h153: chinese_glyph_row=16'h3ef8;
                9'h1e5: chinese_glyph_row=16'h3efc;
                9'h199: chinese_glyph_row=16'h3efe;
                9'h022,9'h144: chinese_glyph_row=16'h3ff8;
                9'h037,9'h072,9'h092: chinese_glyph_row=16'h3ffc;
                9'h0e4,9'h183,9'h189: chinese_glyph_row=16'h3ffe;
                9'h01f: chinese_glyph_row=16'h4020;
                9'h1dc: chinese_glyph_row=16'h4060;
                9'h03d: chinese_glyph_row=16'h4104;
                9'h04f,9'h074: chinese_glyph_row=16'h4208;
                9'h001,9'h002,9'h003,9'h00d: chinese_glyph_row=16'h4444;
                9'h05c: chinese_glyph_row=16'h4450;
                9'h082: chinese_glyph_row=16'h4478;
                9'h007,9'h008,9'h009: chinese_glyph_row=16'h4484;
                9'h083: chinese_glyph_row=16'h4488;
                9'h004: chinese_glyph_row=16'h4494;
                9'h006: chinese_glyph_row=16'h44fc;
                9'h084: chinese_glyph_row=16'h4550;
                9'h12d: chinese_glyph_row=16'h47fe;
                9'h00c: chinese_glyph_row=16'h4888;
                9'h19c: chinese_glyph_row=16'h4e10;
                9'h0aa,9'h1b8: chinese_glyph_row=16'h5040;
                9'h08a,9'h08b,9'h08c: chinese_glyph_row=16'h5088;
                9'h137: chinese_glyph_row=16'h53fc;
                9'h05d: chinese_glyph_row=16'h5488;
                9'h159: chinese_glyph_row=16'h5524;
                9'h08d: chinese_glyph_row=16'h5c88;
                9'h089: chinese_glyph_row=16'h5cf8;
                9'h1d3: chinese_glyph_row=16'h60a0;
                9'h14c: chinese_glyph_row=16'h610c;
                9'h19b: chinese_glyph_row=16'h6210;
                9'h136: chinese_glyph_row=16'h7000;
                9'h07f,9'h1c7: chinese_glyph_row=16'h7008;
                9'h0d5,9'h166: chinese_glyph_row=16'h7040;
                9'h1cc: chinese_glyph_row=16'h7078;
                9'h126,9'h1b7: chinese_glyph_row=16'h7244;
                9'h10c: chinese_glyph_row=16'h778c;
                9'h108: chinese_glyph_row=16'h77fc;
                9'h085,9'h1c3: chinese_glyph_row=16'h7c20;
                9'h081: chinese_glyph_row=16'h7c40;
                9'h00a: chinese_glyph_row=16'h7cfc;
                9'h005,9'h104: chinese_glyph_row=16'h7d08;
                9'h000: chinese_glyph_row=16'h7dfc;
                9'h194: chinese_glyph_row=16'h7ebc;
                9'h1e3: chinese_glyph_row=16'h7ff8;
                9'h147: chinese_glyph_row=16'h7ffc;
                9'h09d,9'h0a4,9'h176,9'h1e7: chinese_glyph_row=16'h7ffe;
                9'h00e: chinese_glyph_row=16'h8444;
                9'h05e: chinese_glyph_row=16'h8904;
                9'h04e: chinese_glyph_row=16'ha3f8;
                9'h06a: chinese_glyph_row=16'hc006;
                9'h08e: chinese_glyph_row=16'he0f8;
                9'h049: chinese_glyph_row=16'he248;
                9'h044: chinese_glyph_row=16'hfbfc;
                9'h053: chinese_glyph_row=16'hfe80;
                9'h026,9'h066,9'h077: chinese_glyph_row=16'hfffe;
                default: chinese_glyph_row=0;
            endcase
        end
    endfunction

    // Fixed status strings only; indices 9..30 correspond to the generator.
    function [7:0] rescue_status_char;
        input [5:0] idx;
        begin
            rescue_status_char=" ";
            if(!alert_frame) case(idx)
                0:rescue_status_char=8'h97;1:rescue_status_char=8'h98;
                2:rescue_status_char=8'h8f;3:rescue_status_char=8'h99;4:rescue_status_char=8'h9a;
                default:;
            endcase
            else if(comm_frame==2) case(idx)
                0:rescue_status_char=8'h8d;1:rescue_status_char=8'h8e;
                2:rescue_status_char=8'h8f;3:rescue_status_char=8'h90;4:rescue_status_char=8'h91;
                default:;
            endcase
            else if(comm_frame==3) case(idx)
                0:rescue_status_char=8'h92;1:rescue_status_char=8'h93;
                2:rescue_status_char=8'h94;3:rescue_status_char=8'h95;4:rescue_status_char=8'h96;
                default:;
            endcase
            else case(idx)
                0:rescue_status_char=8'h89;1:rescue_status_char=8'h8a;
                2:rescue_status_char=8'h8b;3:rescue_status_char=8'h8c;
                default:;
            endcase
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
            if((alert_frame || clear_frames!=0) && px>=96 && px<240 && py>=104 && py<122) begin
                lx=px-96;cell_idx=lx/18;col=lx-cell_idx*18;ly=py-104;
                ch=rescue_status_char(cell_idx);found=1;sub=1;
            end else if(alert_frame && px>=96 && px<168 && py>=128 && py<146) begin
                lx=px-96;cell_idx=lx/18;col=lx-cell_idx*18;ly=py-128;
                ch=8'h80+5'd27+cell_idx;found=1;sub=1;
            end else if((alert_frame || clear_frames!=0) && px>=96 && px<180 && py>=152 && py<168) begin
                lx=px-96;cell_idx=lx/CELL_W;col=(lx-cell_idx*CELL_W)>>1;ly=py-152;
                case(cell_idx)
                    0:ch="I";1:ch="D";2:ch=":";
                    3:ch=hex_char(event_frame[15:12]);4:ch=hex_char(event_frame[11:8]);
                    5:ch=hex_char(event_frame[7:4]);6:ch=hex_char(event_frame[3:0]);default:ch=" ";
                endcase
                found=1;
            end else if(py>=4 && py<4+CELL_H && px>=FLOOR_X && px<FLOOR_X+9*CELL_W) begin
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
                        cn_bits=chinese_glyph_row(ch[4:0],ly-2);
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
