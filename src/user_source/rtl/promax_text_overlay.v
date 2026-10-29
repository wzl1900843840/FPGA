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
    parameter integer MENU_ENABLE=0, FONT_BRAM=0,
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
    input wire [1:0] rescue_comm_state,
    input wire [2:0] menu_field,input wire [1:0] menu_diag,
    input wire menu_confirm,menu_dirty,input wire [3:0] menu_feedback,
    input wire [7:0] memory_volume,input wire [63:0] diagnostic_data
);
    // ===== 帧边界寄存与滚动状态 =====
    // vs_q 用于检测 vsync 下降沿；所有 *_frame 寄存器都在这个边沿更新，
    // 保证"一帧内看到的参数是同一个快照"。scroll_pos 是字幕横向滚动位置，
    // 每 3 帧才推进一步（scroll_div 计数），所以滚动速度与帧率无关地保持匀速。
    localparam integer CELL_W=12, CELL_H=16, PARAM_CHARS=32, FLOOR_X=96;
    localparam integer SUBTITLE_CELL_W=18, SCROLL_CYCLE=H_ACTIVE+128;
    // 告警背景左侧面板底部留白，坐标基于解码后的 640x480 画布。
    // 两种输入图片分辨率共用该位置，不随 source_scale_2x 移动。
    localparam integer ALERT_TEXT_X=144, ALERT_STATUS_Y=340, ALERT_HINT_Y=364, ALERT_ID_Y=388;
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
    wire [7:0] numeric_memory=MENU_ENABLE?memory_volume:8'd128;
    wire [48:0] numeric_inputs={numeric_memory,source_scale_2x,contrast,brightness,volume,period_ms[15:0]};
    reg [48:0] numeric_seen;
    reg [15:0] bin_m;
    reg [11:0] bcd_m,memory_pending,memory_frame;
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
    wire [19:0] next_m=bcd_shift({8'd0,bcd_m},bin_m[15]);
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
            numeric_seen<=49'h1ffffffffffff;convert_busy<=0;convert_step<=0;
            bin_m<=0;bcd_m<=0;memory_pending<=12'h128;memory_frame<=12'h128;
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
                bin_m<={8'd0,numeric_memory};bcd_m<=0;
            end else if(convert_busy) begin
                bin_c<=bin_c<<1;bin_b<=bin_b<<1;bin_v<=bin_v<<1;bin_p<=bin_p<<1;
                bcd_c<=next_c[11:0];bcd_b<=next_b[11:0];bcd_v<=next_v[11:0];bcd_p<=next_p;
                bin_m<=bin_m<<1;bcd_m<=next_m[11:0];
                if(convert_step==15) begin
                    numbers_pending<={next_c[11:0],next_b[11:0],next_v[11:0],next_p};
                    memory_pending<=next_m[11:0];
                    numeric_scale_pending<=numeric_seen[40];convert_busy<=0;
                end else convert_step<=convert_step+1'b1;
            end
            if(frame_start) begin
                numbers_frame<=numbers_pending;scale_frame<=numeric_scale_pending;
                memory_frame<=memory_pending;
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

    // MENU CHINESE GLYPHS
    localparam [255:0] CN_GLYPH_31=256'h0000000001803ffe08080ff8080800003ffc200407e004220c22303c00000000; // 亮
    localparam [255:0] CN_GLYPH_32=256'h0000000000c01ffe12101ffc121013f0100017f8121021a021e04e1e00000000; // 度
    localparam [255:0] CN_GLYPH_33=256'h000000003e08020822fe120814880c480c480c280a0812082108407800000000; // 对
    localparam [255:0] CN_GLYPH_34=256'h0000000020802080208220843e9820b020c02080208222823c8230fc00000000; // 比
    localparam [255:0] CN_GLYPH_35=256'h0000000001803ffc082004407ffe00001ff810081ff810081ff8100800000000; // 音
    localparam [255:0] CN_GLYPH_36=256'h00001ff810081ff810087ffe11081ff811081ff801003ffc01007ffe00000000; // 量
    localparam [255:0] CN_GLYPH_37=256'h00000000042008703f48108c150224803f8804b006c03c84048404f800000000; // 轮
    localparam [255:0] CN_GLYPH_38=256'h0000101c13f47b2813fe10781da637fc522413fc122413fc7204000000000000; // 播
    localparam [255:0] CN_GLYPH_39=256'h000000003ffc2004208427f420842ff4200427e4242427e44404403c00000000; // 周
    localparam [255:0] CN_GLYPH_40=256'h00000000117c3fc411441f7c11441f441144117c3fc40a441184209c00000000; // 期
    localparam [255:0] CN_GLYPH_41=256'h00000000204010e0099002287c4611b013641188131018603180060000000000; // 诊
    localparam [255:0] CN_GLYPH_42=256'h00000000220632f82bc023403ffe264827482b4832c822883e88010800000000; // 断
    localparam [255:0] CN_GLYPH_43=256'h00000000110813fc7d0825f8250825f828201bfc186014b02338462400000000; // 媒
    localparam [255:0] CN_GLYPH_44=256'h000000000840184017fc10e030e071605150125013f814481844104000000000; // 体
    localparam [255:0] CN_GLYPH_45=256'h00003ffc00807ffe00801ff810881ff810881ff800803ffc00807ffe00000000; // 重
    localparam [255:0] CN_GLYPH_46=256'h0000000004583f4c04407ffe08407fc424483f38043007327cd2058c00000000; // 载
    localparam [255:0] CN_GLYPH_47=256'h00000000034004301ff803047ffe04e01b187ce607981c7003801c0000000000; // 参
    localparam [255:0] CN_GLYPH_48=256'h0000000024a017207f7e0c443ec465cc08287f2821101e381bcc618600000000; // 数
    localparam [255:0] CN_GLYPH_49=256'h0000000031f8190801080208760e100013f81208153018e033b00e0e00000000; // 设
    localparam [255:0] CN_GLYPH_50=256'h000000003ffc22443ffc01007ffe01001ff810081ff8100810087ffe00000000; // 置
    localparam [255:0] CN_GLYPH_51=256'h0000000002007ffe0400080013fc1018302057fe10201020102011e000000000; // 存
    localparam [255:0] CN_GLYPH_52=256'h00000000010001003ffc21042104210421043ffc210401000100010000000000; // 中
    localparam [255:0] CN_GLYPH_53=256'h00000000102010a0192035fe32205420102013fc10201020102017fe00000000; // 性
    localparam [255:0] CN_GLYPH_54=256'h000000000c20702010a811a47d2211203a2434285010502010c0170000000000; // 秒
    localparam [255:0] CN_GLYPH_55=256'h000000003ffc3b2408b47fec1e2469a43f24296c3fb429243f2421fc00000000; // 翻
    localparam [255:0] CN_GLYPH_56=256'h000000007ffc010001001ff81008108810881088118803600e18700c00000000; // 页
    localparam [255:0] CN_GLYPH_57=256'h000000000808083008c00b0008003ffe08800840082009180e06080000000000; // 长
    localparam [255:0] CN_GLYPH_58=256'h00001040102013fc7e041040188033fc5108131810f010d87704000000000000; // 按
    localparam [255:0] CN_GLYPH_59=256'h00000000118813fc7f2c12b413fc100013fc12041bfc620403fc020400000000; // 增
    localparam [255:0] CN_GLYPH_60=256'h000000000100010001007ffc0100010002800280044008603030600c00000000; // 大
    localparam [255:0] CN_GLYPH_61=256'h00000028402427fc142007e4142417e8265827d06a344874108c000000000000; // 减
    localparam [255:0] CN_GLYPH_62=256'h00000000008000800080089010881088208420864082008000800f8000000000; // 小
    localparam [255:0] CN_GLYPH_63=256'h000000007ffe01000100010001c001600118010c010001000100010000000000; // 下
    localparam [255:0] CN_GLYPH_64=256'h000000000000000000007ffe0000000000000000000000000000000000000000; // 一
    localparam [255:0] CN_GLYPH_65=256'h0000000001fe7c40104011fc11041124112411241d247174018c060600000000; // 项
    localparam [255:0] CN_GLYPH_66=256'h000000003f38292c3f2029fc3f2008203f2008507f5007c83488490400000000; // 默
    localparam [255:0] CN_GLYPH_67=256'h000033f81a0803f80208720813f812861258127013883a044ffe000000000000; // 退
    localparam [255:0] CN_GLYPH_68=256'h0000000001002104210421043ffc010421042104210421043ffc000400000000; // 出
    localparam [255:0] CN_GLYPH_69=256'h0000000023fc10040804000471fc11041100110011021502190221fc00000000; // 记
    localparam [255:0] CN_GLYPH_70=256'h0000100011fc100c18183630306050c0108211021302120211fc000000000000; // 忆
    localparam [255:0] CN_GLYPH_71=256'h0000102010507c8823fc340253c47a5413d41e5473d4124412dc000000000000; // 输
    localparam [255:0] CN_GLYPH_72=256'h00000000240e25f0250025003ffc21443d44256825382510466846c600000000; // 版
    localparam [255:0] CN_GLYPH_73=256'h00000000010001007ffc038005800d40192031184fec01000100010000000000; // 本
    localparam [255:0] CN_GLYPH_74=256'h00000000211011100bfc01107110111017fe111013101610680047fe00000000; // 进
    localparam [255:0] CN_GLYPH_75=256'h00000000040002000100018001800240024004200c301810300c600600000000; // 入
    localparam [255:0] CN_GLYPH_76=256'h00007f0022fc22843e8422883e48224822302fb0727002cc0386000000000000; // 取
    localparam [255:0] CN_GLYPH_77=256'h0000000022441348095023fc3204120403fc120413fc12042204223c00000000; // 消
    localparam [255:0] CN_GLYPH_78=256'h000000000e22712410a87ffe1102390239fe350251fe51021102111e00000000; // 稍
    localparam [255:0] CN_GLYPH_79=256'h0000000009f80808140817fe348075fc5520142015fe143010c8130600000000; // 候
    localparam [255:0] CN_GLYPH_80=256'h0000005800441ffe104010441f4811481130113221222f52408c000000000000; // 成
    localparam [255:0] CN_GLYPH_81=256'h000000407e40104013fc10441044104410441e8471840304063c000000000000; // 功
    localparam [255:0] CN_GLYPH_82=256'h00000000001c1fe003000c181fe0018006301ffc008204b0189c338600000000; // 系
    localparam [255:0] CN_GLYPH_83=256'h000000002080606047fc41809910f20847f87924c120192462248c3c00000000; // 统
    localparam [255:0] CN_GLYPH_84=256'h000000002040202020207bfe6500a1002100210021002100210021fc00000000; // 忙
    localparam [255:0] CN_GLYPH_85=256'h00000000003c1fc0100010001ffe1000100017f81408240827f8440800000000; // 后
    localparam [255:0] CN_GLYPH_86=256'h0000000020281024182003fe7020102017e0112015121d1211da270c00000000; // 试
    localparam [255:0] CN_GLYPH_87=256'h000000000c200af2122410383ffe7220527c13c4127c1244137c124400000000; // 储
    localparam [255:0] CN_GLYPH_88=256'h00000000082008207ffe084408c408443f282128211021383f6c208600000000; // 故
    localparam [255:0] CN_GLYPH_89=256'h000000003c6027fe28882bfe290429fc250425fc25243c2023fe202000000000; // 障
    localparam [255:0] CN_GLYPH_90=256'h00000000010000807ffe02400a58324c60023ff0082006c007c0783e00000000; // 变
    localparam [255:0] CN_GLYPH_91=256'h000000003ffc0100010002007ffe0200068004800c821882308260fc00000000; // 无
    localparam [255:0] CN_GLYPH_92=256'h000000003ffc00803ffc20840eb000003ffc01001ffc12441244127c00000000; // 需
    localparam [255:0] CN_GLYPH_93=256'h00003ffc200424040ff8080008000ff800087fe80008000801f0000000000000; // 写
    localparam [255:0] CN_GLYPH_94=256'h000000000ff808080ff808083ffe11001ffc11441f2811303fb801c600000000; // 最
    localparam [255:0] CN_GLYPH_95=256'h00000000080e1bf812201220322073fe5220122012501292135a122e00000000; // 低
    localparam [255:0] CN_GLYPH_96=256'h000000000100010001047d9805b00940096019201118210c41060f0000000000; // 水
    localparam [255:0] CN_GLYPH_97=256'h000000000840182017fe1000320473045108110810881090101017fe00000000; // 位
    localparam [255:0] CN_GLYPH_98=256'h0000040004000ffc1804108821880180018001c002600c30381c200400000000; // 欠
    localparam [255:0] CN_GLYPH_99=256'h000000000100410023fc1204044c0848184010a021b02310440c180600000000; // 次
    localparam [255:0] CN_GLYPH_100=256'h0000000001000100010001007ffe010001000100010001000100010000000000; // 十
    localparam [255:0] CN_GLYPH_101=256'h0000000001000080008000007ffe0000042008101808100c2004400200000000; // 六
    localparam [255:0] CN_GLYPH_102=256'h00000000140434243fa4642404247fe404243fa424a424842784043c00000000; // 制
    localparam [255:0] CN_GLYPH_103=256'h0000000018201f7e2ca043103ffc01007ffe00203ffe0c20062001e000000000; // 等
    localparam [255:0] CN_GLYPH_104=256'h00000000084013f82040484017fc3010301057fc101013101090107000000000; // 待
    localparam [255:0] CN_GLYPH_105=256'h00000000204013fc084007fc710410a4132010a017fc106014d83f0c00000000; // 读
    localparam [255:0] CN_GLYPH_106=256'h000000000100010001fc010001007ffe010001c00130010c0100010000000000; // 卡
    localparam [255:0] CN_GLYPH_107=256'h0000100013fc10047c04100415fc380450041004100413fc7004000000000000; // 扫
    localparam [255:0] CN_GLYPH_108=256'h0000109013fe7890100013fc1a44724413fc1244124413fc7204000000000000; // 描
    localparam [255:0] CN_GLYPH_109=256'h00000000081004607ffe01001ff810081ff810081ff810081ff8100800000000; // 首
    localparam [255:0] CN_GLYPH_110=256'h00003ffc220427f42c34336421c43e3c230420c42e0421e43ffc200400000000; // 图
    localparam [255:0] CN_GLYPH_111=256'h0000000001803ffc08103ffc200400f01f8001f01f0001fc3f0001fc00000000; // 毫
    localparam [255:0] CN_GLYPH_112=256'h000000000858084448406ffc2840084018a028a048b009100a080c0400000000; // 状
    localparam [255:0] CN_GLYPH_113=256'h00000000010001007ffe010006c01b30608e000025086494441207e000000000; // 态
    function [15:0] chinese_glyph_row;
        input [6:0] glyph_id;
        input [3:0] row;
        begin
            case ({glyph_id,row})
                11'h0c2,11'h0cd,11'h44d,11'h455: chinese_glyph_row=16'h0004;
                11'h0f3,11'h0f4,11'h5d8,11'h5da,11'h5db: chinese_glyph_row=16'h0008;
                11'h0b2,11'h522: chinese_glyph_row=16'h001c;
                11'h030,11'h0bc,11'h679: chinese_glyph_row=16'h0020;
                11'h3d1: chinese_glyph_row=16'h0028;
                11'h1dd: chinese_glyph_row=16'h0030;
                11'h552: chinese_glyph_row=16'h003c;
                11'h010,11'h052,11'h080,11'h152,11'h165,11'h1d2,11'h511: chinese_glyph_row=16'h0040;
                11'h502: chinese_glyph_row=16'h0044;
                11'h501: chinese_glyph_row=16'h0058;
                11'h093,11'h094,11'h0e5,11'h0ec,11'h175,11'h188,11'h2d2,11'h2d4,11'h2da,11'h2dc,11'h3e2,11'h3e3,11'h3e4,11'h3eb,11'h3ec,11'h5a3,11'h5c3,11'h653,11'h654: chinese_glyph_row=16'h0080;
                11'h52a: chinese_glyph_row=16'h0082;
                11'h08f: chinese_glyph_row=16'h0088;
                11'h0e3: chinese_glyph_row=16'h0098;
                11'h0e2,11'h0e8: chinese_glyph_row=16'h00b0;
                11'h202: chinese_glyph_row=16'h00c0;
                11'h031,11'h6f7: chinese_glyph_row=16'h00f0;
                11'h021,11'h038,11'h071,11'h142,11'h143,11'h145,11'h146,11'h14d,11'h24a,11'h24c,11'h325,11'h327,11'h342,11'h343,11'h34b,11'h34c,11'h34d,11'h383,11'h384,11'h3c2,11'h3c3,11'h3c4,11'h3c6,11'h3c7,11'h3f3,11'h3f4,11'h3f5,11'h3fa,11'h3fb,11'h3fc,11'h3fd,11'h442,11'h492,11'h493,11'h49b,11'h49c,11'h49d,11'h4b4,11'h5a2,11'h5b3,11'h5b4,11'h5c9,11'h602,11'h603,11'h632,11'h642,11'h643,11'h644,11'h645,11'h647,11'h648,11'h649,11'h64a,11'h64b,11'h64c,11'h64d,11'h652,11'h677,11'h6a2,11'h6a3,11'h6a5,11'h6a6,11'h6a8,11'h6ac,11'h6ad,11'h6d5,11'h712,11'h713,11'h715: chinese_glyph_row=16'h0100;
                11'h447,11'h604: chinese_glyph_row=16'h0104;
                11'h2ad,11'h314: chinese_glyph_row=16'h0108;
                11'h3f9,11'h6ab: chinese_glyph_row=16'h010c;
                11'h065,11'h4a5: chinese_glyph_row=16'h0110;
                11'h3f8: chinese_glyph_row=16'h0118;
                11'h064: chinese_glyph_row=16'h0120;
                11'h6aa: chinese_glyph_row=16'h0130;
                11'h3f7: chinese_glyph_row=16'h0160;
                11'h07c,11'h1f2,11'h232,11'h4b5,11'h4b6,11'h527,11'h627,11'h628,11'h6f2: chinese_glyph_row=16'h0180;
                11'h41c: chinese_glyph_row=16'h018c;
                11'h3f6,11'h629,11'h6a9: chinese_glyph_row=16'h01c0;
                11'h5ed: chinese_glyph_row=16'h01c6;
                11'h0bd,11'h67d: chinese_glyph_row=16'h01e0;
                11'h5dc,11'h6f9: chinese_glyph_row=16'h01f0;
                11'h6a4,11'h6fb,11'h6fd: chinese_glyph_row=16'h01fc;
                11'h412: chinese_glyph_row=16'h01fe;
                11'h020,11'h03f,11'h070,11'h075,11'h076,11'h0a2,11'h0a3,11'h332,11'h4b3,11'h5b5,11'h5b7: chinese_glyph_row=16'h0200;
                11'h05f: chinese_glyph_row=16'h0202;
                11'h3bd: chinese_glyph_row=16'h0204;
                11'h213,11'h315,11'h434: chinese_glyph_row=16'h0208;
                11'h295: chinese_glyph_row=16'h0228;
                11'h15d: chinese_glyph_row=16'h023c;
                11'h4b7,11'h4b8,11'h5a5: chinese_glyph_row=16'h0240;
                11'h07d,11'h62a: chinese_glyph_row=16'h0260;
                11'h067,11'h3c8,11'h3c9: chinese_glyph_row=16'h0280;
                11'h1d5: chinese_glyph_row=16'h02c8;
                11'h4cb: chinese_glyph_row=16'h02cc;
                11'h524: chinese_glyph_row=16'h0300;
                11'h2f5,11'h51b: chinese_glyph_row=16'h0304;
                11'h2f2: chinese_glyph_row=16'h0340;
                11'h38b: chinese_glyph_row=16'h0360;
                11'h148,11'h2fc,11'h495: chinese_glyph_row=16'h0380;
                11'h4cc: chinese_glyph_row=16'h0386;
                11'h0e9: chinese_glyph_row=16'h03b0;
                11'h433: chinese_glyph_row=16'h03f8;
                11'h0d4,11'h125,11'h3bc,11'h4d8: chinese_glyph_row=16'h03fc;
                11'h565: chinese_glyph_row=16'h03fe;
                11'h0a5,11'h334,11'h4b2,11'h621,11'h622: chinese_glyph_row=16'h0400;
                11'h16d: chinese_glyph_row=16'h0404;
                11'h078,11'h252,11'h4b9,11'h658: chinese_glyph_row=16'h0420;
                11'h1fb: chinese_glyph_row=16'h0422;
                11'h666,11'h668: chinese_glyph_row=16'h0424;
                11'h2ea,11'h2f3: chinese_glyph_row=16'h0430;
                11'h66d: chinese_glyph_row=16'h043c;
                11'h025,11'h112,11'h235,11'h2e4,11'h3ca: chinese_glyph_row=16'h0440;
                11'h636: chinese_glyph_row=16'h044c;
                11'h2e2: chinese_glyph_row=16'h0458;
                11'h11b,11'h6d3: chinese_glyph_row=16'h0460;
                11'h113,11'h5b9: chinese_glyph_row=16'h0480;
                11'h25c: chinese_glyph_row=16'h0484;
                11'h259,11'h52b: chinese_glyph_row=16'h04b0;
                11'h11c: chinese_glyph_row=16'h04d8;
                11'h2f7: chinese_glyph_row=16'h04e0;
                11'h25d: chinese_glyph_row=16'h04f8;
                11'h03e: chinese_glyph_row=16'h0500;
                11'h149: chinese_glyph_row=16'h0540;
                11'h496: chinese_glyph_row=16'h0580;
                11'h2ed: chinese_glyph_row=16'h058c;
                11'h606: chinese_glyph_row=16'h05b0;
                11'h29d: chinese_glyph_row=16'h0600;
                11'h41d: chinese_glyph_row=16'h0606;
                11'h67c: chinese_glyph_row=16'h0620;
                11'h528: chinese_glyph_row=16'h0630;
                11'h51c: chinese_glyph_row=16'h063c;
                11'h07b: chinese_glyph_row=16'h0640;
                11'h5b8: chinese_glyph_row=16'h0680;
                11'h25a,11'h5ab,11'h716: chinese_glyph_row=16'h06c0;
                11'h11d: chinese_glyph_row=16'h0706;
                11'h2eb: chinese_glyph_row=16'h0732;
                11'h0ed: chinese_glyph_row=16'h0780;
                11'h2fa: chinese_glyph_row=16'h0798;
                11'h5ac: chinese_glyph_row=16'h07c0;
                11'h42b: chinese_glyph_row=16'h07c8;
                11'h1fa,11'h71d: chinese_glyph_row=16'h07e0;
                11'h3d5: chinese_glyph_row=16'h07e4;
                11'h695: chinese_glyph_row=16'h07fc;
                11'h335,11'h396,11'h39d,11'h5d5,11'h5d6: chinese_glyph_row=16'h0800;
                11'h454: chinese_glyph_row=16'h0804;
                11'h18c,11'h1f4,11'h1f6,11'h392,11'h4f3,11'h5e3,11'h5e5: chinese_glyph_row=16'h0808;
                11'h5f2: chinese_glyph_row=16'h080e;
                11'h659,11'h6d2,11'h6f4: chinese_glyph_row=16'h0810;
                11'h024,11'h079,11'h234,11'h39a,11'h427,11'h582,11'h583,11'h5aa: chinese_glyph_row=16'h0820;
                11'h1e6: chinese_glyph_row=16'h0824;
                11'h308: chinese_glyph_row=16'h0828;
                11'h393: chinese_glyph_row=16'h0830;
                11'h0a6,11'h0d3,11'h164,11'h1e2,11'h2c2,11'h2e6,11'h399,11'h612,11'h682,11'h694,11'h707: chinese_glyph_row=16'h0840;
                11'h585,11'h587,11'h703: chinese_glyph_row=16'h0844;
                11'h637: chinese_glyph_row=16'h0848;
                11'h429: chinese_glyph_row=16'h0850;
                11'h702: chinese_glyph_row=16'h0858;
                11'h132,11'h3cb: chinese_glyph_row=16'h0860;
                11'h253: chinese_glyph_row=16'h0870;
                11'h172,11'h398: chinese_glyph_row=16'h0880;
                11'h1e4,11'h3e5: chinese_glyph_row=16'h0890;
                11'h374: chinese_glyph_row=16'h08b4;
                11'h394: chinese_glyph_row=16'h08c0;
                11'h586: chinese_glyph_row=16'h08c4;
                11'h124: chinese_glyph_row=16'h08e0;
                11'h03a,11'h154,11'h182,11'h70b: chinese_glyph_row=16'h0910;
                11'h39b: chinese_glyph_row=16'h0918;
                11'h039,11'h14a: chinese_glyph_row=16'h0920;
                11'h607: chinese_glyph_row=16'h0940;
                11'h4d4: chinese_glyph_row=16'h0950;
                11'h608: chinese_glyph_row=16'h0960;
                11'h294: chinese_glyph_row=16'h0990;
                11'h4f2: chinese_glyph_row=16'h09f8;
                11'h21a,11'h70c: chinese_glyph_row=16'h0a08;
                11'h28b: chinese_glyph_row=16'h0a44;
                11'h5a6: chinese_glyph_row=16'h0a58;
                11'h573: chinese_glyph_row=16'h0af2;
                11'h395: chinese_glyph_row=16'h0b00;
                11'h1b2,11'h4a4: chinese_glyph_row=16'h0bfc;
                11'h70d: chinese_glyph_row=16'h0c04;
                11'h07e: chinese_glyph_row=16'h0c10;
                11'h525: chinese_glyph_row=16'h0c18;
                11'h362,11'h572,11'h67b: chinese_glyph_row=16'h0c20;
                11'h1fc: chinese_glyph_row=16'h0c22;
                11'h1d6: chinese_glyph_row=16'h0c26;
                11'h219: chinese_glyph_row=16'h0c28;
                11'h4ba,11'h62b: chinese_glyph_row=16'h0c30;
                11'h305: chinese_glyph_row=16'h0c44;
                11'h217,11'h218: chinese_glyph_row=16'h0c48;
                11'h068: chinese_glyph_row=16'h0c60;
                11'h5ba: chinese_glyph_row=16'h0c82;
                11'h0ea: chinese_glyph_row=16'h0c8c;
                11'h0e7: chinese_glyph_row=16'h0cd8;
                11'h497: chinese_glyph_row=16'h0d40;
                11'h39c: chinese_glyph_row=16'h0e06;
                11'h31d: chinese_glyph_row=16'h0e0e;
                11'h38c: chinese_glyph_row=16'h0e18;
                11'h4e2: chinese_glyph_row=16'h0e22;
                11'h5c6: chinese_glyph_row=16'h0eb0;
                11'h60d: chinese_glyph_row=16'h0f00;
                11'h3ed: chinese_glyph_row=16'h0f80;
                11'h18b,11'h18d,11'h1f5,11'h5d4,11'h5d7,11'h5e2,11'h5e4: chinese_glyph_row=16'h0ff8;
                11'h0fd,11'h623: chinese_glyph_row=16'h0ffc;
                11'h016,11'h017,11'h018,11'h033,11'h0f9,11'h134,11'h138,11'h208,11'h317,11'h3b7,11'h461,11'h554,11'h555,11'h557,11'h558,11'h615,11'h6b1,11'h6c4: chinese_glyph_row=16'h1000;
                11'h0fa,11'h0fb: chinese_glyph_row=16'h1002;
                11'h453,11'h6b3,11'h6b5,11'h6b9,11'h6ba: chinese_glyph_row=16'h1004;
                11'h0fc: chinese_glyph_row=16'h1006;
                11'h0f5,11'h0f6,11'h0f8,11'h179,11'h17a,11'h17b,11'h17d,11'h1c9,11'h239,11'h23b,11'h23d,11'h242,11'h244,11'h329,11'h32b,11'h32c,11'h386,11'h6d7,11'h6d9,11'h6db,11'h6dd: chinese_glyph_row=16'h1008;
                11'h463,11'h65b: chinese_glyph_row=16'h100c;
                11'h029,11'h02a,11'h02c,11'h02d,11'h02f,11'h61c,11'h68a: chinese_glyph_row=16'h1010;
                11'h337: chinese_glyph_row=16'h1018;
                11'h261: chinese_glyph_row=16'h101c;
                11'h01a,11'h01b,11'h01c,11'h102,11'h1c1,11'h1c4,11'h33a,11'h33b,11'h33c,11'h352,11'h358,11'h35a,11'h35b,11'h35c,11'h3a2,11'h471,11'h567: chinese_glyph_row=16'h1020;
                11'h563: chinese_glyph_row=16'h1024;
                11'h575: chinese_glyph_row=16'h1038;
                11'h011,11'h012,11'h013,11'h014,11'h051,11'h0a7,11'h0ab,11'h0ac,11'h101,11'h163,11'h167,11'h2cd,11'h3a1,11'h3a5,11'h414,11'h504,11'h513: chinese_glyph_row=16'h1040;
                11'h505,11'h515,11'h516,11'h517,11'h518: chinese_glyph_row=16'h1044;
                11'h086,11'h472: chinese_glyph_row=16'h1050;
                11'h69b: chinese_glyph_row=16'h1060;
                11'h10b,11'h68d: chinese_glyph_row=16'h1070;
                11'h265: chinese_glyph_row=16'h1078;
                11'h095,11'h096,11'h098,11'h099,11'h09a,11'h09b,11'h09c: chinese_glyph_row=16'h1080;
                11'h468: chinese_glyph_row=16'h1082;
                11'h087,11'h1cb,11'h2d6,11'h2d8,11'h387,11'h388,11'h389,11'h3e6,11'h3e7,11'h61a,11'h625: chinese_glyph_row=16'h1088;
                11'h255,11'h3dc: chinese_glyph_row=16'h108c;
                11'h105,11'h61b,11'h68c,11'h6c1: chinese_glyph_row=16'h1090;
                11'h168,11'h353,11'h639,11'h699: chinese_glyph_row=16'h10a0;
                11'h697: chinese_glyph_row=16'h10a4;
                11'h364,11'h4e4: chinese_glyph_row=16'h10a8;
                11'h36c: chinese_glyph_row=16'h10c0;
                11'h4fc: chinese_glyph_row=16'h10c8;
                11'h3ab: chinese_glyph_row=16'h10d8;
                11'h1ba,11'h293,11'h2c5: chinese_glyph_row=16'h10e0;
                11'h3aa: chinese_glyph_row=16'h10f0;
                11'h097,11'h191: chinese_glyph_row=16'h10fc;
                11'h034,11'h458,11'h459,11'h5e7: chinese_glyph_row=16'h1100;
                11'h45a,11'h469,11'h4e6,11'h4ec: chinese_glyph_row=16'h1102;
                11'h416,11'h457: chinese_glyph_row=16'h1104;
                11'h088: chinese_glyph_row=16'h1106;
                11'h03b,11'h1ca,11'h246,11'h248,11'h2b2,11'h619: chinese_glyph_row=16'h1108;
                11'h4a3,11'h4a7,11'h4a9: chinese_glyph_row=16'h1110;
                11'h123,11'h60a: chinese_glyph_row=16'h1118;
                11'h4ed: chinese_glyph_row=16'h111e;
                11'h367,11'h569: chinese_glyph_row=16'h1120;
                11'h417,11'h418,11'h419: chinese_glyph_row=16'h1124;
                11'h508,11'h5eb: chinese_glyph_row=16'h1130;
                11'h509: chinese_glyph_row=16'h1132;
                11'h284,11'h286,11'h288,11'h5e9: chinese_glyph_row=16'h1144;
                11'h507: chinese_glyph_row=16'h1148;
                11'h1bb: chinese_glyph_row=16'h1150;
                11'h282,11'h289: chinese_glyph_row=16'h117c;
                11'h28c: chinese_glyph_row=16'h1184;
                11'h299,11'h38a,11'h3b2: chinese_glyph_row=16'h1188;
                11'h365: chinese_glyph_row=16'h11a4;
                11'h297: chinese_glyph_row=16'h11b0;
                11'h10a: chinese_glyph_row=16'h11d0;
                11'h56c: chinese_glyph_row=16'h11da;
                11'h33d: chinese_glyph_row=16'h11e0;
                11'h1c2,11'h415,11'h462,11'h46c: chinese_glyph_row=16'h11fc;
                11'h46b: chinese_glyph_row=16'h1202;
                11'h0d7,11'h0d9,11'h13a,11'h13b,11'h13d,11'h1b4,11'h1b5,11'h3b9,11'h4d7,11'h4d9,11'h4db,11'h635: chinese_glyph_row=16'h1204;
                11'h109,11'h16c,11'h215,11'h21b,11'h319: chinese_glyph_row=16'h1208;
                11'h204,11'h206,11'h20a: chinese_glyph_row=16'h1210;
                11'h5f4,11'h5f5,11'h5f9: chinese_glyph_row=16'h1220;
                11'h26a,11'h574: chinese_glyph_row=16'h1224;
                11'h5fd: chinese_glyph_row=16'h122e;
                11'h128,11'h12a,11'h47b,11'h57b,11'h57d,11'h5cb,11'h5cc,11'h6c9,11'h6ca: chinese_glyph_row=16'h1244;
                11'h1bc: chinese_glyph_row=16'h1248;
                11'h2c9,11'h5fa: chinese_glyph_row=16'h1250;
                11'h438: chinese_glyph_row=16'h1258;
                11'h439: chinese_glyph_row=16'h1270;
                11'h12b,11'h57a,11'h5cd: chinese_glyph_row=16'h127c;
                11'h437: chinese_glyph_row=16'h1286;
                11'h5fb: chinese_glyph_row=16'h1292;
                11'h186: chinese_glyph_row=16'h1298;
                11'h3b5: chinese_glyph_row=16'h12b4;
                11'h47c: chinese_glyph_row=16'h12dc;
                11'h46a: chinese_glyph_row=16'h1302;
                11'h4fd: chinese_glyph_row=16'h1306;
                11'h29a,11'h4aa,11'h68b: chinese_glyph_row=16'h1310;
                11'h3a9: chinese_glyph_row=16'h1318;
                11'h698: chinese_glyph_row=16'h1320;
                11'h15c: chinese_glyph_row=16'h1324;
                11'h4d3: chinese_glyph_row=16'h1348;
                11'h5fc: chinese_glyph_row=16'h135a;
                11'h298: chinese_glyph_row=16'h1364;
                11'h57c: chinese_glyph_row=16'h137c;
                11'h43a: chinese_glyph_row=16'h1388;
                11'h579: chinese_glyph_row=16'h13c4;
                11'h478: chinese_glyph_row=16'h13d4;
                11'h207: chinese_glyph_row=16'h13f0;
                11'h262: chinese_glyph_row=16'h13f4;
                11'h2ca,11'h318,11'h436,11'h683: chinese_glyph_row=16'h13f8;
                11'h0d8,11'h103,11'h127,11'h129,11'h139,11'h13c,11'h155,11'h269,11'h26b,11'h2b3,11'h336,11'h359,11'h3a3,11'h3b3,11'h3b6,11'h3b8,11'h4da,11'h514,11'h693,11'h6b2,11'h6bb,11'h6c5,11'h6c8,11'h6cb: chinese_glyph_row=16'h13fc;
                11'h1c5,11'h1c8,11'h264,11'h6c2: chinese_glyph_row=16'h13fe;
                11'h662: chinese_glyph_row=16'h1404;
                11'h4f4,11'h55a: chinese_glyph_row=16'h1408;
                11'h3d4,11'h4f9: chinese_glyph_row=16'h1420;
                11'h3d6: chinese_glyph_row=16'h1424;
                11'h4fb: chinese_glyph_row=16'h1430;
                11'h1bd: chinese_glyph_row=16'h1446;
                11'h2cb: chinese_glyph_row=16'h1448;
                11'h216: chinese_glyph_row=16'h1488;
                11'h169: chinese_glyph_row=16'h14a0;
                11'h2bb: chinese_glyph_row=16'h14b0;
                11'h69c: chinese_glyph_row=16'h14d8;
                11'h256,11'h45b: chinese_glyph_row=16'h1502;
                11'h56a: chinese_glyph_row=16'h1512;
                11'h31a: chinese_glyph_row=16'h1530;
                11'h15a,11'h6b6: chinese_glyph_row=16'h15fc;
                11'h4fa: chinese_glyph_row=16'h15fe;
                11'h4ab: chinese_glyph_row=16'h1610;
                11'h36d: chinese_glyph_row=16'h1700;
                11'h303: chinese_glyph_row=16'h1720;
                11'h568: chinese_glyph_row=16'h17e0;
                11'h3d7: chinese_glyph_row=16'h17e8;
                11'h209,11'h559: chinese_glyph_row=16'h17f8;
                11'h0a8,11'h0da,11'h106,11'h1d8,11'h2c4,11'h686,11'h69a: chinese_glyph_row=16'h17fc;
                11'h0d2,11'h0d6,11'h1b9,11'h35d,11'h4a8,11'h4f5,11'h614,11'h61d: chinese_glyph_row=16'h17fe;
                11'h624: chinese_glyph_row=16'h1804;
                11'h63d: chinese_glyph_row=16'h1806;
                11'h65a: chinese_glyph_row=16'h1808;
                11'h4bb: chinese_glyph_row=16'h1810;
                11'h464: chinese_glyph_row=16'h1818;
                11'h564,11'h613,11'h672: chinese_glyph_row=16'h1820;
                11'h07a,11'h2c3,11'h638: chinese_glyph_row=16'h1840;
                11'h2cc: chinese_glyph_row=16'h1844;
                11'h29b,11'h2ba: chinese_glyph_row=16'h1860;
                11'h3a6: chinese_glyph_row=16'h1880;
                11'h5bb: chinese_glyph_row=16'h1882;
                11'h0e6: chinese_glyph_row=16'h1884;
                11'h52c: chinese_glyph_row=16'h189c;
                11'h708: chinese_glyph_row=16'h18a0;
                11'h107: chinese_glyph_row=16'h18c0;
                11'h31b: chinese_glyph_row=16'h18e0;
                11'h45c: chinese_glyph_row=16'h1902;
                11'h313: chinese_glyph_row=16'h1908;
                11'h16b: chinese_glyph_row=16'h1910;
                11'h354,11'h498,11'h609: chinese_glyph_row=16'h1920;
                11'h53b: chinese_glyph_row=16'h1924;
                11'h0db,11'h1b3: chinese_glyph_row=16'h1a04;
                11'h432: chinese_glyph_row=16'h1a08;
                11'h6c6: chinese_glyph_row=16'h1a44;
                11'h2f8: chinese_glyph_row=16'h1b18;
                11'h717: chinese_glyph_row=16'h1b30;
                11'h30c: chinese_glyph_row=16'h1bcc;
                11'h5f3: chinese_glyph_row=16'h1bf8;
                11'h2b9,11'h3ba: chinese_glyph_row=16'h1bfc;
                11'h2fd: chinese_glyph_row=16'h1c00;
                11'h1c6: chinese_glyph_row=16'h1c08;
                11'h2fb: chinese_glyph_row=16'h1c70;
                11'h16a: chinese_glyph_row=16'h1ca0;
                11'h56b: chinese_glyph_row=16'h1d12;
                11'h156,11'h15b,11'h41a: chinese_glyph_row=16'h1d24;
                11'h266: chinese_glyph_row=16'h1da6;
                11'h376: chinese_glyph_row=16'h1e24;
                11'h30b: chinese_glyph_row=16'h1e38;
                11'h479: chinese_glyph_row=16'h1e54;
                11'h519: chinese_glyph_row=16'h1e84;
                11'h032,11'h6fa: chinese_glyph_row=16'h1f00;
                11'h5ea: chinese_glyph_row=16'h1f28;
                11'h287: chinese_glyph_row=16'h1f44;
                11'h506: chinese_glyph_row=16'h1f48;
                11'h285: chinese_glyph_row=16'h1f7c;
                11'h673: chinese_glyph_row=16'h1f7e;
                11'h6f8: chinese_glyph_row=16'h1f80;
                11'h553: chinese_glyph_row=16'h1fc0;
                11'h019,11'h523,11'h526: chinese_glyph_row=16'h1fe0;
                11'h187: chinese_glyph_row=16'h1fe6;
                11'h028,11'h02b,11'h02e: chinese_glyph_row=16'h1ff0;
                11'h0f2,11'h0f7,11'h178,11'h17c,11'h238,11'h23a,11'h23c,11'h241,11'h243,11'h247,11'h249,11'h2d5,11'h2d7,11'h2d9,11'h2f4,11'h328,11'h32a,11'h385,11'h6d6,11'h6d8,11'h6da,11'h6dc: chinese_glyph_row=16'h1ff8;
                11'h015,11'h173,11'h205,11'h529,11'h5ca,11'h5e8: chinese_glyph_row=16'h1ffc;
                11'h0ad,11'h133,11'h203,11'h503,11'h556: chinese_glyph_row=16'h1ffe;
                11'h073,11'h1f9,11'h273,11'h278,11'h5d2,11'h62d,11'h65c,11'h6ed,11'h6f6: chinese_glyph_row=16'h2004;
                11'h01d,11'h01e,11'h543,11'h544,11'h59d: chinese_glyph_row=16'h2020;
                11'h562: chinese_glyph_row=16'h2028;
                11'h050,11'h0d1,11'h162,11'h292,11'h542,11'h684,11'h692: chinese_glyph_row=16'h2040;
                11'h040: chinese_glyph_row=16'h2078;
                11'h174,11'h222,11'h223,11'h229,11'h532: chinese_glyph_row=16'h2080;
                11'h224,11'h22a: chinese_glyph_row=16'h2082;
                11'h225,11'h274,11'h276,11'h3e8,11'h5c5: chinese_glyph_row=16'h2084;
                11'h3e9,11'h58d: chinese_glyph_row=16'h2086;
                11'h28d: chinese_glyph_row=16'h209c;
                11'h227: chinese_glyph_row=16'h20b0;
                11'h228: chinese_glyph_row=16'h20c0;
                11'h6e9: chinese_glyph_row=16'h20c4;
                11'h184: chinese_glyph_row=16'h20e4;
                11'h054: chinese_glyph_row=16'h20fe;
                11'h035,11'h036,11'h548,11'h549,11'h54a,11'h54b,11'h54c: chinese_glyph_row=16'h2100;
                11'h03c,11'h345,11'h346,11'h347,11'h348,11'h34a,11'h443,11'h444,11'h445,11'h448,11'h449,11'h44a,11'h44b: chinese_glyph_row=16'h2104;
                11'h055,11'h21c: chinese_glyph_row=16'h2108;
                11'h60b: chinese_glyph_row=16'h210c;
                11'h30a,11'h4a2,11'h58a: chinese_glyph_row=16'h2110;
                11'h50a: chinese_glyph_row=16'h2122;
                11'h589: chinese_glyph_row=16'h2128;
                11'h58b: chinese_glyph_row=16'h2138;
                11'h487: chinese_glyph_row=16'h2144;
                11'h043,11'h045: chinese_glyph_row=16'h2150;
                11'h626: chinese_glyph_row=16'h2188;
                11'h20b: chinese_glyph_row=16'h21a0;
                11'h63a: chinese_glyph_row=16'h21b0;
                11'h6e6: chinese_glyph_row=16'h21c4;
                11'h1ad,11'h1db,11'h20c: chinese_glyph_row=16'h21e0;
                11'h6eb: chinese_glyph_row=16'h21e4;
                11'h37d,11'h45d,11'h54d: chinese_glyph_row=16'h21fc;
                11'h0cc,11'h4dc,11'h6e2: chinese_glyph_row=16'h2204;
                11'h2a2: chinese_glyph_row=16'h2206;
                11'h1ec: chinese_glyph_row=16'h2220;
                11'h1ab,11'h1e8: chinese_glyph_row=16'h2224;
                11'h4c8: chinese_glyph_row=16'h2230;
                11'h0dc,11'h4dd: chinese_glyph_row=16'h223c;
                11'h061,11'h062,11'h06c,11'h06d,11'h0c4,11'h0c5,11'h0c6,11'h0c7,11'h0c8,11'h0c9,11'h323,11'h4d2: chinese_glyph_row=16'h2244;
                11'h042,11'h046,11'h04a,11'h04c,11'h04d,11'h4c7: chinese_glyph_row=16'h2248;
                11'h0ca: chinese_glyph_row=16'h227c;
                11'h22b: chinese_glyph_row=16'h2282;
                11'h4c3: chinese_glyph_row=16'h2284;
                11'h2ab,11'h4c5: chinese_glyph_row=16'h2288;
                11'h1ea,11'h4c2: chinese_glyph_row=16'h22fc;
                11'h214: chinese_glyph_row=16'h22fe;
                11'h6e8: chinese_glyph_row=16'h2304;
                11'h63b: chinese_glyph_row=16'h2310;
                11'h2bc: chinese_glyph_row=16'h2338;
                11'h2a5: chinese_glyph_row=16'h2340;
                11'h04b: chinese_glyph_row=16'h23f8;
                11'h122,11'h452,11'h474,11'h4d5,11'h634: chinese_glyph_row=16'h23fc;
                11'h59c: chinese_glyph_row=16'h23fe;
                11'h5d3: chinese_glyph_row=16'h2404;
                11'h55b: chinese_glyph_row=16'h2408;
                11'h482: chinese_glyph_row=16'h240e;
                11'h05b,11'h0b4,11'h0b7,11'h0b9,11'h0bb,11'h1a7,11'h1a9: chinese_glyph_row=16'h2420;
                11'h1ac: chinese_glyph_row=16'h2422;
                11'h27a: chinese_glyph_row=16'h2424;
                11'h2e8: chinese_glyph_row=16'h2448;
                11'h059,11'h05a: chinese_glyph_row=16'h2450;
                11'h1a3: chinese_glyph_row=16'h2470;
                11'h257: chinese_glyph_row=16'h2480;
                11'h66b: chinese_glyph_row=16'h2484;
                11'h057,11'h058: chinese_glyph_row=16'h2488;
                11'h118: chinese_glyph_row=16'h2490;
                11'h302: chinese_glyph_row=16'h24a0;
                11'h66a: chinese_glyph_row=16'h24a4;
                11'h0b6: chinese_glyph_row=16'h24b8;
                11'h114: chinese_glyph_row=16'h24fe;
                11'h484,11'h485: chinese_glyph_row=16'h2500;
                11'h598: chinese_glyph_row=16'h2504;
                11'h115,11'h116,11'h2b6,11'h71a: chinese_glyph_row=16'h2508;
                11'h48b: chinese_glyph_row=16'h2510;
                11'h59a: chinese_glyph_row=16'h2524;
                11'h0b5: chinese_glyph_row=16'h252c;
                11'h48a: chinese_glyph_row=16'h2538;
                11'h489: chinese_glyph_row=16'h2568;
                11'h483: chinese_glyph_row=16'h25f0;
                11'h2b5,11'h2b7: chinese_glyph_row=16'h25f8;
                11'h599: chinese_glyph_row=16'h25fc;
                11'h1da: chinese_glyph_row=16'h2630;
                11'h2a7: chinese_glyph_row=16'h2648;
                11'h3d8: chinese_glyph_row=16'h2658;
                11'h117: chinese_glyph_row=16'h2688;
                11'h56d: chinese_glyph_row=16'h270c;
                11'h2a8: chinese_glyph_row=16'h2748;
                11'h66c: chinese_glyph_row=16'h2784;
                11'h041: chinese_glyph_row=16'h27c0;
                11'h3d9: chinese_glyph_row=16'h27d0;
                11'h279,11'h27b: chinese_glyph_row=16'h27e4;
                11'h275,11'h6e3: chinese_glyph_row=16'h27f4;
                11'h55c: chinese_glyph_row=16'h27f8;
                11'h0b8,11'h3d3: chinese_glyph_row=16'h27fc;
                11'h1a8,11'h593: chinese_glyph_row=16'h27fe;
                11'h12c: chinese_glyph_row=16'h2800;
                11'h2b8: chinese_glyph_row=16'h2820;
                11'h706: chinese_glyph_row=16'h2840;
                11'h193: chinese_glyph_row=16'h2844;
                11'h594: chinese_glyph_row=16'h2888;
                11'h1a4: chinese_glyph_row=16'h2890;
                11'h709: chinese_glyph_row=16'h28a0;
                11'h596: chinese_glyph_row=16'h2904;
                11'h37b: chinese_glyph_row=16'h2924;
                11'h423: chinese_glyph_row=16'h292c;
                11'h379: chinese_glyph_row=16'h296c;
                11'h425,11'h597: chinese_glyph_row=16'h29fc;
                11'h19a: chinese_glyph_row=16'h2a10;
                11'h198: chinese_glyph_row=16'h2a90;
                11'h197: chinese_glyph_row=16'h2afe;
                11'h195: chinese_glyph_row=16'h2b00;
                11'h1a5: chinese_glyph_row=16'h2b0c;
                11'h2a9: chinese_glyph_row=16'h2b48;
                11'h2a4: chinese_glyph_row=16'h2bc0;
                11'h595: chinese_glyph_row=16'h2bfe;
                11'h047: chinese_glyph_row=16'h2c06;
                11'h6e4: chinese_glyph_row=16'h2c34;
                11'h674: chinese_glyph_row=16'h2ca0;
                11'h6ea: chinese_glyph_row=16'h2e04;
                11'h1ed: chinese_glyph_row=16'h2ee0;
                11'h50b: chinese_glyph_row=16'h2f52;
                11'h4c9: chinese_glyph_row=16'h2fb0;
                11'h277: chinese_glyph_row=16'h2ff4;
                11'h1a6: chinese_glyph_row=16'h2ffa;
                11'h1d9: chinese_glyph_row=16'h3008;
                11'h4bc: chinese_glyph_row=16'h300c;
                11'h687,11'h688: chinese_glyph_row=16'h3010;
                11'h069: chinese_glyph_row=16'h3018;
                11'h338: chinese_glyph_row=16'h3020;
                11'h3cc: chinese_glyph_row=16'h3030;
                11'h1fd: chinese_glyph_row=16'h303c;
                11'h0a9: chinese_glyph_row=16'h3040;
                11'h466: chinese_glyph_row=16'h3060;
                11'h5bc: chinese_glyph_row=16'h3082;
                11'h0eb: chinese_glyph_row=16'h3086;
                11'h2c6: chinese_glyph_row=16'h30e0;
                11'h22d: chinese_glyph_row=16'h30fc;
                11'h14b: chinese_glyph_row=16'h3110;
                11'h499: chinese_glyph_row=16'h3118;
                11'h29c: chinese_glyph_row=16'h3180;
                11'h1d4: chinese_glyph_row=16'h3190;
                11'h312: chinese_glyph_row=16'h31f8;
                11'h4d6,11'h616: chinese_glyph_row=16'h3204;
                11'h356,11'h5f6: chinese_glyph_row=16'h3220;
                11'h5a7: chinese_glyph_row=16'h324c;
                11'h2aa: chinese_glyph_row=16'h32c8;
                11'h2a3: chinese_glyph_row=16'h32f8;
                11'h6e5: chinese_glyph_row=16'h3364;
                11'h52d: chinese_glyph_row=16'h3386;
                11'h31c: chinese_glyph_row=16'h33b0;
                11'h048,11'h431: chinese_glyph_row=16'h33f8;
                11'h135,11'h1b6,11'h3a7: chinese_glyph_row=16'h33fc;
                11'h475: chinese_glyph_row=16'h3402;
                11'h663: chinese_glyph_row=16'h3424;
                11'h369: chinese_glyph_row=16'h3428;
                11'h11a: chinese_glyph_row=16'h3460;
                11'h4f6: chinese_glyph_row=16'h3480;
                11'h42c: chinese_glyph_row=16'h3488;
                11'h4e9: chinese_glyph_row=16'h3502;
                11'h158: chinese_glyph_row=16'h3524;
                11'h157: chinese_glyph_row=16'h35fc;
                11'h355: chinese_glyph_row=16'h35fe;
                11'h465: chinese_glyph_row=16'h3630;
                11'h267: chinese_glyph_row=16'h37fc;
                11'h6b7: chinese_glyph_row=16'h3804;
                11'h62c: chinese_glyph_row=16'h381c;
                11'h4e7: chinese_glyph_row=16'h3902;
                11'h4e8: chinese_glyph_row=16'h39fe;
                11'h43b: chinese_glyph_row=16'h3a04;
                11'h368: chinese_glyph_row=16'h3a24;
                11'h373: chinese_glyph_row=16'h3b24;
                11'h0ba,11'h59b: chinese_glyph_row=16'h3c20;
                11'h192: chinese_glyph_row=16'h3c44;
                11'h119: chinese_glyph_row=16'h3c50;
                11'h1a2,11'h592: chinese_glyph_row=16'h3c60;
                11'h22c: chinese_glyph_row=16'h3c82;
                11'h25b: chinese_glyph_row=16'h3c84;
                11'h1aa: chinese_glyph_row=16'h3d28;
                11'h488: chinese_glyph_row=16'h3d44;
                11'h0b3: chinese_glyph_row=16'h3df0;
                11'h212: chinese_glyph_row=16'h3e08;
                11'h1e9,11'h1eb: chinese_glyph_row=16'h3e24;
                11'h6e7: chinese_glyph_row=16'h3e3c;
                11'h0c3: chinese_glyph_row=16'h3e44;
                11'h4c6: chinese_glyph_row=16'h3e48;
                11'h196: chinese_glyph_row=16'h3e50;
                11'h0cb: chinese_glyph_row=16'h3e64;
                11'h060,11'h063,11'h06b,11'h06e: chinese_glyph_row=16'h3e7c;
                11'h4c4: chinese_glyph_row=16'h3e84;
                11'h056,11'h2ac: chinese_glyph_row=16'h3e88;
                11'h226: chinese_glyph_row=16'h3e98;
                11'h185: chinese_glyph_row=16'h3e9c;
                11'h306: chinese_glyph_row=16'h3ec4;
                11'h153: chinese_glyph_row=16'h3ef8;
                11'h1e5: chinese_glyph_row=16'h3efc;
                11'h199: chinese_glyph_row=16'h3efe;
                11'h6fc: chinese_glyph_row=16'h3f00;
                11'h69d: chinese_glyph_row=16'h3f0c;
                11'h424,11'h426,11'h428: chinese_glyph_row=16'h3f20;
                11'h378,11'h37c: chinese_glyph_row=16'h3f24;
                11'h588: chinese_glyph_row=16'h3f28;
                11'h2e9,11'h422: chinese_glyph_row=16'h3f38;
                11'h254: chinese_glyph_row=16'h3f48;
                11'h2e3: chinese_glyph_row=16'h3f4c;
                11'h58c: chinese_glyph_row=16'h3f6c;
                11'h258: chinese_glyph_row=16'h3f88;
                11'h664,11'h669: chinese_glyph_row=16'h3fa4;
                11'h37a: chinese_glyph_row=16'h3fb4;
                11'h5ec: chinese_glyph_row=16'h3fb8;
                11'h283,11'h28a: chinese_glyph_row=16'h3fc4;
                11'h5a9: chinese_glyph_row=16'h3ff0;
                11'h022,11'h144: chinese_glyph_row=16'h3ff8;
                11'h037,11'h072,11'h092,11'h1f8,11'h233,11'h24b,11'h272,11'h2d1,11'h2db,11'h322,11'h324,11'h344,11'h349,11'h372,11'h446,11'h44c,11'h486,11'h5b2,11'h5c2,11'h5c4,11'h5c8,11'h5d1,11'h676,11'h6e1,11'h6ec,11'h6f3,11'h6f5: chinese_glyph_row=16'h3ffc;
                11'h0e4,11'h183,11'h189,11'h1f3,11'h2a6,11'h397,11'h576,11'h5e6,11'h67a: chinese_glyph_row=16'h3ffe;
                11'h65d: chinese_glyph_row=16'h4002;
                11'h01f: chinese_glyph_row=16'h4020;
                11'h3d2: chinese_glyph_row=16'h4024;
                11'h27d: chinese_glyph_row=16'h403c;
                11'h1dc: chinese_glyph_row=16'h4060;
                11'h21d: chinese_glyph_row=16'h4078;
                11'h3ea: chinese_glyph_row=16'h4082;
                11'h50c: chinese_glyph_row=16'h408c;
                11'h633: chinese_glyph_row=16'h4100;
                11'h03d: chinese_glyph_row=16'h4104;
                11'h60c: chinese_glyph_row=16'h4106;
                11'h535: chinese_glyph_row=16'h4180;
                11'h04f,11'h074: chinese_glyph_row=16'h4208;
                11'h675: chinese_glyph_row=16'h4310;
                11'h27c: chinese_glyph_row=16'h4404;
                11'h55d: chinese_glyph_row=16'h4408;
                11'h63c: chinese_glyph_row=16'h440c;
                11'h71c: chinese_glyph_row=16'h4412;
                11'h001,11'h002,11'h003,11'h00d: chinese_glyph_row=16'h4444;
                11'h05c: chinese_glyph_row=16'h4450;
                11'h082: chinese_glyph_row=16'h4478;
                11'h007,11'h008,11'h009: chinese_glyph_row=16'h4484;
                11'h083: chinese_glyph_row=16'h4488;
                11'h004: chinese_glyph_row=16'h4494;
                11'h006: chinese_glyph_row=16'h44fc;
                11'h084: chinese_glyph_row=16'h4550;
                11'h2bd: chinese_glyph_row=16'h4624;
                11'h48c: chinese_glyph_row=16'h4668;
                11'h48d: chinese_glyph_row=16'h46c6;
                11'h538: chinese_glyph_row=16'h47f8;
                11'h534: chinese_glyph_row=16'h47fc;
                11'h12d,11'h4ad: chinese_glyph_row=16'h47fe;
                11'h685,11'h704: chinese_glyph_row=16'h4840;
                11'h3db: chinese_glyph_row=16'h4874;
                11'h00c: chinese_glyph_row=16'h4888;
                11'h70a: chinese_glyph_row=16'h48b0;
                11'h42d: chinese_glyph_row=16'h4904;
                11'h19c: chinese_glyph_row=16'h4e10;
                11'h20d: chinese_glyph_row=16'h4e1e;
                11'h49a: chinese_glyph_row=16'h4fec;
                11'h43c: chinese_glyph_row=16'h4ffe;
                11'h6b8: chinese_glyph_row=16'h5004;
                11'h36a: chinese_glyph_row=16'h5010;
                11'h36b: chinese_glyph_row=16'h5020;
                11'h0aa,11'h1b8: chinese_glyph_row=16'h5040;
                11'h08a,11'h08b,11'h08c: chinese_glyph_row=16'h5088;
                11'h467: chinese_glyph_row=16'h50c0;
                11'h4eb: chinese_glyph_row=16'h5102;
                11'h3a8,11'h618: chinese_glyph_row=16'h5108;
                11'h2c8: chinese_glyph_row=16'h5150;
                11'h4ea: chinese_glyph_row=16'h51fe;
                11'h5f8: chinese_glyph_row=16'h5220;
                11'h268: chinese_glyph_row=16'h5224;
                11'h578: chinese_glyph_row=16'h527c;
                11'h476: chinese_glyph_row=16'h53c4;
                11'h137: chinese_glyph_row=16'h53fc;
                11'h357: chinese_glyph_row=16'h5420;
                11'h05d: chinese_glyph_row=16'h5488;
                11'h4f8: chinese_glyph_row=16'h5520;
                11'h159: chinese_glyph_row=16'h5524;
                11'h689: chinese_glyph_row=16'h57fc;
                11'h339: chinese_glyph_row=16'h57fe;
                11'h08d: chinese_glyph_row=16'h5c88;
                11'h089: chinese_glyph_row=16'h5cf8;
                11'h5a8: chinese_glyph_row=16'h6002;
                11'h4bd: chinese_glyph_row=16'h6006;
                11'h3cd: chinese_glyph_row=16'h600c;
                11'h533: chinese_glyph_row=16'h6060;
                11'h718: chinese_glyph_row=16'h608e;
                11'h1d3: chinese_glyph_row=16'h60a0;
                11'h5bd: chinese_glyph_row=16'h60fc;
                11'h14c: chinese_glyph_row=16'h610c;
                11'h30d: chinese_glyph_row=16'h6186;
                11'h3bb: chinese_glyph_row=16'h6204;
                11'h19b: chinese_glyph_row=16'h6210;
                11'h53c: chinese_glyph_row=16'h6224;
                11'h665: chinese_glyph_row=16'h6424;
                11'h71b: chinese_glyph_row=16'h6494;
                11'h546: chinese_glyph_row=16'h6500;
                11'h307: chinese_glyph_row=16'h65cc;
                11'h4ac: chinese_glyph_row=16'h6800;
                11'h377: chinese_glyph_row=16'h69a4;
                11'h3da: chinese_glyph_row=16'h6a34;
                11'h705: chinese_glyph_row=16'h6ffc;
                11'h136: chinese_glyph_row=16'h7000;
                11'h6bc: chinese_glyph_row=16'h7004;
                11'h07f,11'h1c7: chinese_glyph_row=16'h7008;
                11'h38d: chinese_glyph_row=16'h700c;
                11'h363,11'h566: chinese_glyph_row=16'h7020;
                11'h0d5,11'h166: chinese_glyph_row=16'h7040;
                11'h1cc: chinese_glyph_row=16'h7078;
                11'h696: chinese_glyph_row=16'h7104;
                11'h4a6: chinese_glyph_row=16'h7110;
                11'h4e3: chinese_glyph_row=16'h7124;
                11'h2c7: chinese_glyph_row=16'h7160;
                11'h41b: chinese_glyph_row=16'h7174;
                11'h51a: chinese_glyph_row=16'h7184;
                11'h456: chinese_glyph_row=16'h71fc;
                11'h26c,11'h6cc: chinese_glyph_row=16'h7204;
                11'h435: chinese_glyph_row=16'h7208;
                11'h577: chinese_glyph_row=16'h7220;
                11'h126,11'h1b7,11'h6c7: chinese_glyph_row=16'h7244;
                11'h4ca: chinese_glyph_row=16'h7270;
                11'h617: chinese_glyph_row=16'h7304;
                11'h47a: chinese_glyph_row=16'h73d4;
                11'h5f7: chinese_glyph_row=16'h73fe;
                11'h4f7: chinese_glyph_row=16'h75fc;
                11'h316: chinese_glyph_row=16'h760e;
                11'h3ac: chinese_glyph_row=16'h7704;
                11'h10c: chinese_glyph_row=16'h778c;
                11'h108: chinese_glyph_row=16'h77fc;
                11'h5ad: chinese_glyph_row=16'h783e;
                11'h6c3: chinese_glyph_row=16'h7890;
                11'h539: chinese_glyph_row=16'h7924;
                11'h477: chinese_glyph_row=16'h7a54;
                11'h263: chinese_glyph_row=16'h7b28;
                11'h545: chinese_glyph_row=16'h7bfe;
                11'h6b4: chinese_glyph_row=16'h7c04;
                11'h085,11'h1c3: chinese_glyph_row=16'h7c20;
                11'h081,11'h413: chinese_glyph_row=16'h7c40;
                11'h296: chinese_glyph_row=16'h7c46;
                11'h473: chinese_glyph_row=16'h7c88;
                11'h2ec: chinese_glyph_row=16'h7cd2;
                11'h2f9: chinese_glyph_row=16'h7ce6;
                11'h00a: chinese_glyph_row=16'h7cfc;
                11'h005,11'h104,11'h2b4: chinese_glyph_row=16'h7d08;
                11'h366: chinese_glyph_row=16'h7d22;
                11'h605: chinese_glyph_row=16'h7d98;
                11'h000: chinese_glyph_row=16'h7dfc;
                11'h3a4: chinese_glyph_row=16'h7e04;
                11'h512: chinese_glyph_row=16'h7e40;
                11'h194: chinese_glyph_row=16'h7ebc;
                11'h4c1: chinese_glyph_row=16'h7f00;
                11'h309: chinese_glyph_row=16'h7f28;
                11'h3b4: chinese_glyph_row=16'h7f2c;
                11'h42a: chinese_glyph_row=16'h7f50;
                11'h304: chinese_glyph_row=16'h7f7e;
                11'h2e7: chinese_glyph_row=16'h7fc4;
                11'h667: chinese_glyph_row=16'h7fe4;
                11'h5d9: chinese_glyph_row=16'h7fe8;
                11'h375: chinese_glyph_row=16'h7fec;
                11'h1e3: chinese_glyph_row=16'h7ff8;
                11'h147,11'h382,11'h3c5,11'h494: chinese_glyph_row=16'h7ffc;
                11'h09d,11'h0a4,11'h176,11'h1e7,11'h236,11'h245,11'h24d,11'h2d3,11'h2dd,11'h2e5,11'h2f6,11'h326,11'h32d,11'h333,11'h3f2,11'h405,11'h4e5,11'h584,11'h5a4,11'h5b6,11'h646,11'h656,11'h678,11'h6a7,11'h6d4,11'h714: chinese_glyph_row=16'h7ffe;
                11'h00e: chinese_glyph_row=16'h8444;
                11'h05e: chinese_glyph_row=16'h8904;
                11'h53d: chinese_glyph_row=16'h8c3c;
                11'h536: chinese_glyph_row=16'h9910;
                11'h547: chinese_glyph_row=16'ha100;
                11'h04e: chinese_glyph_row=16'ha3f8;
                11'h06a: chinese_glyph_row=16'hc006;
                11'h53a: chinese_glyph_row=16'hc120;
                11'h08e: chinese_glyph_row=16'he0f8;
                11'h049: chinese_glyph_row=16'he248;
                11'h537: chinese_glyph_row=16'hf208;
                11'h044: chinese_glyph_row=16'hfbfc;
                11'h053: chinese_glyph_row=16'hfe80;
                11'h026,11'h066,11'h077: chinese_glyph_row=16'hfffe;
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
                "+": case(row) 1,2,4,5:glyph_row=5'b00100;3:glyph_row=5'b11111;default:glyph_row=0;endcase
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
    function [7:0] menu_rom_char;
        input [5:0] row_id;input [5:0] n;
        begin
            case({row_id,n})
                12'd0:menu_rom_char=8'haf;
                12'd1:menu_rom_char=8'hb0;
                12'd2:menu_rom_char=8'hb1;
                12'd3:menu_rom_char=8'hb2;
                12'd26:menu_rom_char=8'h94;
                12'd27:menu_rom_char=8'h9b;
                12'd28:menu_rom_char=8'hb3;
                12'd64:menu_rom_char=8'h9f;
                12'd65:menu_rom_char=8'ha0;
                12'd78:menu_rom_char=8'h30;
                12'd79:menu_rom_char=8'h30;
                12'd80:menu_rom_char=8'h30;
                12'd81:menu_rom_char=8'h2f;
                12'd82:menu_rom_char=8'h32;
                12'd83:menu_rom_char=8'h35;
                12'd84:menu_rom_char=8'h35;
                12'd128:menu_rom_char=8'ha1;
                12'd129:menu_rom_char=8'ha2;
                12'd130:menu_rom_char=8'ha0;
                12'd142:menu_rom_char=8'h30;
                12'd143:menu_rom_char=8'h30;
                12'd144:menu_rom_char=8'h30;
                12'd148:menu_rom_char=8'hb4;
                12'd149:menu_rom_char=8'hb5;
                12'd150:menu_rom_char=8'h31;
                12'd151:menu_rom_char=8'h32;
                12'd152:menu_rom_char=8'h38;
                12'd192:menu_rom_char=8'ha3;
                12'd193:menu_rom_char=8'ha4;
                12'd206:menu_rom_char=8'h30;
                12'd207:menu_rom_char=8'h30;
                12'd208:menu_rom_char=8'h30;
                12'd209:menu_rom_char=8'h2f;
                12'd210:menu_rom_char=8'h32;
                12'd211:menu_rom_char=8'h35;
                12'd212:menu_rom_char=8'h35;
                12'd256:menu_rom_char=8'ha5;
                12'd257:menu_rom_char=8'ha6;
                12'd258:menu_rom_char=8'ha7;
                12'd259:menu_rom_char=8'ha8;
                12'd270:menu_rom_char=8'h30;
                12'd271:menu_rom_char=8'h30;
                12'd272:menu_rom_char=8'h2e;
                12'd273:menu_rom_char=8'h30;
                12'd274:menu_rom_char=8'h30;
                12'd275:menu_rom_char=8'h30;
                12'd276:menu_rom_char=8'hb6;
                12'd320:menu_rom_char=8'ha9;
                12'd321:menu_rom_char=8'haa;
                12'd334:menu_rom_char=8'h4b;
                12'd335:menu_rom_char=8'h32;
                12'd336:menu_rom_char=8'h2f;
                12'd337:menu_rom_char=8'h4b;
                12'd338:menu_rom_char=8'h33;
                12'd339:menu_rom_char=8'hb7;
                12'd340:menu_rom_char=8'hb8;
                12'd384:menu_rom_char=8'hab;
                12'd385:menu_rom_char=8'hac;
                12'd386:menu_rom_char=8'had;
                12'd387:menu_rom_char=8'hae;
                12'd398:menu_rom_char=8'hb9;
                12'd399:menu_rom_char=8'hba;
                12'd400:menu_rom_char=8'h4b;
                12'd401:menu_rom_char=8'h34;
                12'd448:menu_rom_char=8'h4b;
                12'd449:menu_rom_char=8'h32;
                12'd451:menu_rom_char=8'hbb;
                12'd452:menu_rom_char=8'hbc;
                12'd456:menu_rom_char=8'h4b;
                12'd457:menu_rom_char=8'h33;
                12'd459:menu_rom_char=8'hbd;
                12'd460:menu_rom_char=8'hbe;
                12'd464:menu_rom_char=8'h4b;
                12'd465:menu_rom_char=8'h34;
                12'd467:menu_rom_char=8'hbf;
                12'd468:menu_rom_char=8'hc0;
                12'd469:menu_rom_char=8'hc1;
                12'd512:menu_rom_char=8'hb9;
                12'd513:menu_rom_char=8'hba;
                12'd514:menu_rom_char=8'h4b;
                12'd515:menu_rom_char=8'h34;
                12'd517:menu_rom_char=8'hc2;
                12'd518:menu_rom_char=8'h96;
                12'd522:menu_rom_char=8'h53;
                12'd523:menu_rom_char=8'h57;
                12'd524:menu_rom_char=8'h32;
                12'd526:menu_rom_char=8'hc3;
                12'd527:menu_rom_char=8'hc4;
                12'd704:menu_rom_char=8'h4b;
                12'd705:menu_rom_char=8'h32;
                12'd706:menu_rom_char=8'h2b;
                12'd707:menu_rom_char=8'h4b;
                12'd708:menu_rom_char=8'h33;
                12'd710:menu_rom_char=8'hb9;
                12'd711:menu_rom_char=8'hba;
                12'd712:menu_rom_char=8'h33;
                12'd713:menu_rom_char=8'hb6;
                12'd714:menu_rom_char=8'h9b;
                12'd715:menu_rom_char=8'hb3;
                12'd768:menu_rom_char=8'haf;
                12'd769:menu_rom_char=8'hb0;
                12'd770:menu_rom_char=8'hb1;
                12'd771:menu_rom_char=8'hb2;
                12'd794:menu_rom_char=8'h8f;
                12'd795:menu_rom_char=8'h9b;
                12'd796:menu_rom_char=8'hb3;
                12'd832:menu_rom_char=8'h4b;
                12'd833:menu_rom_char=8'h32;
                12'd834:menu_rom_char=8'h2f;
                12'd835:menu_rom_char=8'h4b;
                12'd836:menu_rom_char=8'h33;
                12'd838:menu_rom_char=8'hb7;
                12'd839:menu_rom_char=8'hb8;
                12'd843:menu_rom_char=8'h4b;
                12'd844:menu_rom_char=8'h34;
                12'd846:menu_rom_char=8'hbf;
                12'd847:menu_rom_char=8'hc0;
                12'd848:menu_rom_char=8'hc1;
                12'd896:menu_rom_char=8'hb9;
                12'd897:menu_rom_char=8'hba;
                12'd898:menu_rom_char=8'h4b;
                12'd899:menu_rom_char=8'h34;
                12'd901:menu_rom_char=8'hca;
                12'd902:menu_rom_char=8'hcb;
                12'd903:menu_rom_char=8'had;
                12'd904:menu_rom_char=8'hae;
                12'd905:menu_rom_char=8'h95;
                12'd906:menu_rom_char=8'h96;
                12'd960:menu_rom_char=8'hab;
                12'd961:menu_rom_char=8'hac;
                12'd962:menu_rom_char=8'had;
                12'd963:menu_rom_char=8'hae;
                12'd974:menu_rom_char=8'h95;
                12'd975:menu_rom_char=8'h96;
                12'd976:menu_rom_char=8'had;
                12'd977:menu_rom_char=8'hae;
                12'd978:menu_rom_char=8'h3f;
                12'd1024:menu_rom_char=8'h4b;
                12'd1025:menu_rom_char=8'h32;
                12'd1027:menu_rom_char=8'h95;
                12'd1028:menu_rom_char=8'h96;
                12'd1032:menu_rom_char=8'h4b;
                12'd1033:menu_rom_char=8'h33;
                12'd1035:menu_rom_char=8'hcc;
                12'd1036:menu_rom_char=8'hcd;
                12'd1088:menu_rom_char=8'h89;
                12'd1089:menu_rom_char=8'h8a;
                12'd1090:menu_rom_char=8'h9b;
                12'd1091:menu_rom_char=8'hb3;
                12'd1093:menu_rom_char=8'h8d;
                12'd1094:menu_rom_char=8'hce;
                12'd1095:menu_rom_char=8'hcf;
                12'd1152:menu_rom_char=8'h9b;
                12'd1153:menu_rom_char=8'hb3;
                12'd1154:menu_rom_char=8'hd0;
                12'd1155:menu_rom_char=8'hd1;
                12'd1216:menu_rom_char=8'hd2;
                12'd1217:menu_rom_char=8'hd3;
                12'd1218:menu_rom_char=8'hd4;
                12'd1220:menu_rom_char=8'h8d;
                12'd1221:menu_rom_char=8'hce;
                12'd1222:menu_rom_char=8'hd5;
                12'd1223:menu_rom_char=8'had;
                12'd1224:menu_rom_char=8'hd6;
                12'd1280:menu_rom_char=8'haf;
                12'd1281:menu_rom_char=8'hb0;
                12'd1282:menu_rom_char=8'hb3;
                12'd1283:menu_rom_char=8'hd7;
                12'd1284:menu_rom_char=8'hd8;
                12'd1285:menu_rom_char=8'hd9;
                12'd1344:menu_rom_char=8'h89;
                12'd1345:menu_rom_char=8'h8a;
                12'd1346:menu_rom_char=8'had;
                12'd1347:menu_rom_char=8'hae;
                12'd1348:menu_rom_char=8'hab;
                12'd1349:menu_rom_char=8'hac;
                12'd1408:menu_rom_char=8'haf;
                12'd1409:menu_rom_char=8'hb0;
                12'd1410:menu_rom_char=8'h94;
                12'd1411:menu_rom_char=8'hda;
                12'd1413:menu_rom_char=8'hdb;
                12'd1414:menu_rom_char=8'hdc;
                12'd1415:menu_rom_char=8'hdd;
                12'd1416:menu_rom_char=8'hcb;
                12'd1472:menu_rom_char=8'hde;
                12'd1473:menu_rom_char=8'hdf;
                12'd1474:menu_rom_char=8'he0;
                12'd1475:menu_rom_char=8'he1;
                12'd1477:menu_rom_char=8'h2f;
                12'd1479:menu_rom_char=8'he2;
                12'd1480:menu_rom_char=8'hae;
                12'd1481:menu_rom_char=8'he3;
                12'd1482:menu_rom_char=8'hb0;
                12'd1484:menu_rom_char=8'he4;
                12'd1485:menu_rom_char=8'he5;
                12'd1486:menu_rom_char=8'hca;
                12'd1487:menu_rom_char=8'he6;
                12'd1536:menu_rom_char=8'hde;
                12'd1537:menu_rom_char=8'hb9;
                12'd1538:menu_rom_char=8'he7;
                12'd1539:menu_rom_char=8'he8;
                12'd1540:menu_rom_char=8'ha7;
                12'd1541:menu_rom_char=8'ha8;
                12'd1543:menu_rom_char=8'h2f;
                12'd1545:menu_rom_char=8'had;
                12'd1546:menu_rom_char=8'hd6;
                12'd1547:menu_rom_char=8'he3;
                12'd1548:menu_rom_char=8'hb0;
                12'd1550:menu_rom_char=8'he4;
                12'd1551:menu_rom_char=8'he5;
                12'd1552:menu_rom_char=8'hca;
                12'd1553:menu_rom_char=8'he6;
                12'd1600:menu_rom_char=8'he9;
                12'd1601:menu_rom_char=8'hea;
                12'd1603:menu_rom_char=8'heb;
                12'd1604:menu_rom_char=8'hec;
                12'd1606:menu_rom_char=8'hed;
                12'd1607:menu_rom_char=8'hee;
                12'd1609:menu_rom_char=8'h97;
                12'd1610:menu_rom_char=8'h98;
                12'd1612:menu_rom_char=8'hef;
                12'd1613:menu_rom_char=8'hb6;
                12'd1615:menu_rom_char=8'he4;
                12'd1616:menu_rom_char=8'he5;
                12'd1617:menu_rom_char=8'hca;
                12'd1618:menu_rom_char=8'he6;
                12'd1664:menu_rom_char=8'hc8;
                12'd1665:menu_rom_char=8'hc9;
                12'd1667:menu_rom_char=8'h2f;
                12'd1669:menu_rom_char=8'hab;
                12'd1670:menu_rom_char=8'hac;
                12'd1671:menu_rom_char=8'hf0;
                12'd1672:menu_rom_char=8'hf1;
                12'd1674:menu_rom_char=8'he4;
                12'd1675:menu_rom_char=8'he5;
                12'd1676:menu_rom_char=8'hca;
                12'd1677:menu_rom_char=8'he6;
                default:menu_rom_char=" ";
            endcase
        end
    endfunction
    function [7:0] menu_char;
        input [3:0] r;input [5:0] n;
        reg [5:0] row_id;reg [11:0] digits;
        begin
            row_id=r;digits=0;
            if(r==0 && !menu_dirty)row_id=12;
            if(r==7 && menu_field==4)row_id=13;
            if(r==7 && menu_field==5)row_id=14;
            if(menu_confirm && r==6)row_id=15;
            if(menu_confirm && r==7)row_id=16;
            if(r==9)case(menu_feedback)
                1:row_id=17;
                2:row_id=18;
                3:row_id=19;
                4:row_id=20;
                5:row_id=21;
                6:row_id=22;
                default:row_id=9;
            endcase
            menu_char=menu_rom_char(row_id,n);
            case(r)1:digits=numbers_frame[43:32];2:digits=numbers_frame[55:44];3:digits=numbers_frame[31:20];endcase
            if(r>=1 && r<=3 && n>=14 && n<=16)menu_char="0"+((digits>>((16-n)*4))&15);
            if(r==4)case(n)14:menu_char="0"+numbers_frame[19:16];15:menu_char="0"+numbers_frame[15:12];17:menu_char="0"+numbers_frame[11:8];18:menu_char="0"+numbers_frame[7:4];19:menu_char="0"+numbers_frame[3:0];endcase
            if(menu_field==4 && r==7)begin
                menu_char=menu_rom_char(6'd23+menu_diag,n);
            end
            if(menu_field==4 && r==10)begin
                if(n==0)menu_char="D";else if(n==1)menu_char="0"+menu_diag;
                else if(n>=3 && n<19)menu_char=hex_char(diagnostic_data[(18-n)*4 +:4]);
            end
        end
    endfunction
    function [16:0] text_lookup;
        input [9:0] px,py;
        reg [9:0] lx,ly,sx;
        reg [5:0] cell_idx;
        reg [4:0] col;
        reg [7:0] ch;
        reg [4:0] row_bits;
        reg [15:0] cn_bits;
        reg found,sub;reg [3:0] mr,font_row;
        begin
            lx=0;ly=0;cell_idx=0;col=0;ch=" ";found=0;sub=0;text_lookup=0;font_row=0;
            row_bits=0;cn_bits=0;sx=px+scroll_pos;
            if(sx>=SCROLL_CYCLE) sx=sx-SCROLL_CYCLE;
            // 四个区块的坐标判定：lx/ly 是区块内局部坐标，cell_idx 是第几个字符格，
            // col 是字符格内的横向像素（右移 1 位即 2 倍横向放大）。
            if(MENU_ENABLE && show_info_frame && !alert_frame && px>=56 && px<584 && py>=88 && py<450)begin
                // One title, six 32-pixel rows, and a separate help area.
                // Power-of-two row spacing avoids a divide-by-24 pixel path.
                lx=px-56;mr=15;ly=0;
                if(py<106)begin mr=0;ly=py-88;end
                else if(py>=128 && py<320)begin mr=1+((py-128)>>5);ly=(py-128)&31;end
                else if(py>=322 && py<340 && menu_field==4)begin mr=10;ly=py-322;end
                else if(py>=350 && py<368)begin mr=7;ly=py-350;end
                else if(py>=378 && py<396)begin mr=8;ly=py-378;end
                else if(py>=406 && py<424)begin mr=11;ly=py-406;end
                else if(py>=432)begin mr=9;ly=py-432;end
                cell_idx=lx>>4;col=lx[3:0];
                if(mr!=15)begin ch=menu_char(mr,cell_idx);found=1;sub=1;end
            end else if(MENU_ENABLE && !show_info_frame && !alert_frame && menu_feedback!=0 && px>=56 && px<584 && py>=360 && py<378)begin
                lx=px-56;ly=py-360;cell_idx=lx>>4;col=lx[3:0];ch=menu_char(9,cell_idx);found=1;sub=1;
            end else if((alert_frame || clear_frames!=0) && px>=ALERT_TEXT_X && px<ALERT_TEXT_X+144 && py>=ALERT_STATUS_Y && py<ALERT_STATUS_Y+18) begin
                lx=px-ALERT_TEXT_X;cell_idx=lx/18;col=lx-cell_idx*18;ly=py-ALERT_STATUS_Y;
                ch=rescue_status_char(cell_idx);found=1;sub=1;
            end else if(alert_frame && px>=ALERT_TEXT_X && px<ALERT_TEXT_X+72 && py>=ALERT_HINT_Y && py<ALERT_HINT_Y+18) begin
                lx=px-ALERT_TEXT_X;cell_idx=lx/18;col=lx-cell_idx*18;ly=py-ALERT_HINT_Y;
                ch=8'h80+5'd27+cell_idx;found=1;sub=1;
            end else if((alert_frame || clear_frames!=0) && px>=ALERT_TEXT_X && px<ALERT_TEXT_X+84 && py>=ALERT_ID_Y && py<ALERT_ID_Y+16) begin
                lx=px-ALERT_TEXT_X;cell_idx=lx/CELL_W;col=(lx-cell_idx*CELL_W)>>1;ly=py-ALERT_ID_Y;
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
            end else if(show_info_frame && !MENU_ENABLE && py>=PARAM_Y && py<PARAM_Y+CELL_H && px>=PARAM_X && px<PARAM_X+PARAM_CHARS*CELL_W) begin
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
                if(sub && ch[7]) begin
                    if(col>=1 && col<17 && ly>=2 && ly<18) begin
                        font_row=ly-2;
                        text_lookup={1'b1,4'd0-col[3:0],ch,font_row};
                    end
                end else if(sub) begin
                    if(col>=4 && col<14 && ly>=2 && ly<16) begin
                        font_row=(ly-2)>>1;
                        text_lookup={1'b1,4'd3-col[3:0],ch,font_row};
                    end
                end else if(col<5 && ly<14) begin
                    font_row=ly>>1;
                    text_lookup={1'b1,4'd15-{col[2:0],1'b0},ch,font_row};
                end
            end
        end
    endfunction
    function [15:0] ascii_font_word;
        input [7:0] ch;input [3:0] row;
        reg [4:0] bits;
        begin
            bits=glyph_row(ch,row[2:0]);
            ascii_font_word={bits[4],bits[4],bits[3],bits[3],bits[2],bits[2],bits[1],bits[1],bits[0],bits[0],6'd0};
        end
    endfunction
    function text_pixel;
        input [9:0] px,py;reg [16:0] lookup;reg [15:0] bits;
        begin
            lookup=text_lookup(px,py);
            bits=lookup[11] ? chinese_glyph_row(lookup[10:4],lookup[3:0]) : ascii_font_word(lookup[11:4],lookup[3:0]);
            text_pixel=lookup[16] && bits[lookup[15:12]];
        end
    endfunction
    wire [9:0] compose_x,compose_y;
    wire [23:0] compose_rgb;
    wire compose_de,ink;
    generate if(FONT_BRAM)begin:g_font_bram
        // Configuration-time ROM contents are included in the bitstream.
        // A single synchronous read replaces the large per-pixel glyph mux.
        reg [15:0] font_rom[0:4095] /* fehdl force_ram=1, ram_style="bram" */;
        integer init_ch,init_row;
        initial begin
            for(init_ch=0;init_ch<256;init_ch=init_ch+1)
                for(init_row=0;init_row<16;init_row=init_row+1)
                    font_rom[init_ch*16+init_row]=init_ch>=128 ?
                        chinese_glyph_row(init_ch-128,init_row) : ascii_font_word(init_ch,init_row);
        end
        wire [16:0] lookup=text_lookup(pixel_x,pixel_y);
        reg [15:0] font_word;reg [4:0] meta;
        reg [9:0] x_q,y_q;reg [23:0] rgb_q;reg de_q;
        always @(posedge clk)font_word<=font_rom[lookup[11:0]];
        always @(posedge clk or negedge rst_n)
            if(!rst_n)begin meta<=0;x_q<=0;y_q<=0;rgb_q<=0;de_q<=0;end
            else begin meta<=lookup[16:12];x_q<=pixel_x;y_q<=pixel_y;rgb_q<=rgb_in;de_q<=de;end
        assign compose_x=x_q;assign compose_y=y_q;assign compose_rgb=rgb_q;assign compose_de=de_q;
        assign ink=enable && de_q && meta[4] && font_word[meta[3:0]];
    end else begin:g_font_comb
        assign compose_x=pixel_x;assign compose_y=pixel_y;assign compose_rgb=rgb_in;assign compose_de=de;
        assign ink=enable && de && text_pixel(pixel_x,pixel_y);
    end endgenerate
    // ===== 最终叠加：笔画画浅色，阴影画深色，其余保持照片原样 =====
    // 阴影不是"整块底色"，而是把同一个字形按 (x−1,y−1) 再查一次：
    // 只有笔画存在的位置才落深色，所以照片不会被铺上一层底板。
    // 字幕阴影额外裁剪到与文字相同的左右边界内，防止在画面边缘露边。
    // Clip the subtitle shadow at the same horizontal edge as its text.
    wire shadow;
    generate if(MENU_ENABLE)begin:g_shadow_line
        // Raster delay reuses the actual ink from the previous scanline.
        // Read-before-write + one pixel gives exactly (x-1,y-1), avoiding
        // a second complete coordinate/character/font combinational cone.
        reg ink_line[0:H_ACTIVE-1];reg delayed_ink;
        always @(posedge clk)if(compose_de && compose_x<H_ACTIVE)begin
            delayed_ink<=ink_line[compose_x];ink_line[compose_x]<=ink;
        end
        assign shadow=enable && compose_de && compose_x!=0 && compose_y!=0 &&
            !(compose_y>=SUBTITLE_Y && compose_y<=SUBTITLE_Y+18 && (compose_x<8 || compose_x>=H_ACTIVE-8)) && delayed_ink;
    end else begin:g_shadow_legacy
        assign shadow=enable && compose_de && compose_x!=0 && compose_y!=0 &&
            !(compose_y>=SUBTITLE_Y && compose_y<=SUBTITLE_Y+18 && (compose_x<8 || compose_x>=H_ACTIVE-8)) &&
            text_pixel(compose_x-10'd1,compose_y-10'd1);
    end endgenerate
    wire menu_visible=MENU_ENABLE && enable && show_info_frame && !alert_frame && compose_de;
    wire menu_card=menu_visible && compose_x>=32 && compose_x<608 && compose_y>=76 && compose_y<460;
    wire selected_box=menu_card && compose_x>=44 && compose_x<596 && compose_y>=124+{menu_field,5'b0} && compose_y<152+{menu_field,5'b0};
    wire menu_accent=selected_box && compose_x<48;
    wire menu_rule=menu_card && compose_x>=56 && compose_x<584 && (compose_y==115 || compose_y==343);
    // PIC5 的浅色留白使用深色字与浅色描边；其他区域保持原来的配色。
    wire alert_text_area=(alert_frame || clear_frames!=0) && !menu_card &&
        compose_x>=ALERT_TEXT_X && compose_x<=ALERT_TEXT_X+144 &&
        compose_y>=ALERT_STATUS_Y && compose_y<=ALERT_ID_Y+16;
    assign overlay_active=ink || shadow || menu_card;
    assign rgb_out=menu_accent ? 24'hffdc40 : ink ? (alert_text_area ? 24'h244536 : menu_card && compose_y<106 ? 24'hffdc40 : 24'heef6fa) :
        shadow ? (alert_text_area ? 24'hfffdf3 : 24'h162430) : selected_box ? 24'h30495c : menu_rule ? 24'h3a5060 : menu_card ? 24'h1c2e3b : compose_rgb;
endmodule
