`timescale 1ns/1ps

// 模块职责：串口字幕命令解析器（SUB=… 系列命令）与回包生成。
// 位置：上游是 uart_rx_byte（单字节 valid），下游是顶层的帧边界提交 CDC
//       与 promax_text_overlay（真正画字的地方）。
// 时钟域：50MHz 系统时钟 clk，单域；与像素域之间由顶层用 frame_config_cdc 做帧提交。
// 输入约定：rx_data/rx_valid 是已收到的字节；service_ready 表示参数服务可用；
//       save_done/save_failed/request_dropped 是本模块发出的保存请求的回执；
//       live_text/live_length/live_enable 是当前生效值，供 SUB? 查询回显。
// 输出约定：cfg_update_valid 是"新字幕要生效"的单拍脉冲，cfg_text/cfg_length/cfg_enable
//       是新值；reply_valid/reply_data/reply_last/reply_ready 是串口回包的字节流握手。
//
// 命令与回包（一律以 CR 或 LF 结束；回包固定 OK/ERR + CRLF）：
//   SUB=<文本>  设置最多 12 个可打印 ASCII 字符，小写自动转大写，成功回 OK
//   SUB=ON/OFF  开/关字幕（沿用当前文本），回 OK
//   SUB?        查询，回 "SUB=<0/1>:<文本>" 形式
//   SUB=CN      选中性短句（内置"照片音乐"字形），也接受 UTF-8 的 SUB=照片音乐
//   SUB=SAVE    本集成没有字幕 Flash 存储，会返回 ERR，不会假报成功
// 设计要点：
//   1) 行缓冲 40 字节，超长只记 overflow 标志，在行尾一次性回 ERR，不会边收边解析。
//   2) CRLF 会被当作一个结束符：收到 CR 后丢弃紧随的一个 LF。
//   3) 回包用"当前回包 + 一个待发回包"的两级结构，避免上一条还没发完时丢回执。
//   4) 字幕只在这里改寄存器，真正上屏要等顶层帧边界提交，所以不会撕裂画面。
module subtitle_uart_controller #(parameter integer APPLIED_STATUS_INPUTS=0,
                                  parameter integer MAX_LINE=40,
                                  parameter integer ENABLE_LEGACY_ELEV=1) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [7:0]   rx_data,
    input  wire         rx_valid,
    input  wire         rx_framing_error,
    input  wire         secure_status_valid,
    input  wire         secure_status_ok,
    input  wire         service_ready,
    input  wire         save_done,
    input  wire         save_failed,
    input  wire         request_dropped,
    input  wire [95:0] live_text,
    input  wire [5:0]   live_length,
    input  wire         live_enable,
    output reg          cfg_update_valid,
    output reg  [95:0] cfg_text,
    output reg  [5:0]   cfg_length,
    output reg          cfg_enable,
    output reg          save_request,
    // Elevator-demo status/alert sideband. These signals share the same
    // line parser with SUB= commands so a command is consumed only once.
    output reg          elev_update_valid,
    output reg  [7:0]   elev_floor_value,
    output reg  [3:0]   elev_floor_tens,elev_floor_ones,
    output reg          elev_floor_basement,
    output reg  [1:0]   elev_direction,
    output reg  [1:0]   elev_door,
    output reg          elev_alert_value,
    output reg          elev_alert_update_valid,
    output reg          alert_command_valid,
    output reg          alert_command_value,
    output wire         reply_valid,
    output wire [7:0]   reply_data,
    output wire         reply_last,
    input  wire         reply_ready,
    output reg          rescue_ack_valid,
    output reg [15:0]   rescue_ack_id,
    input wire [15:0]   rescue_event_id,
    input wire [1:0]    rescue_comm_state,
    input wire         applied_alert,
    input wire         applied_floor_basement,
    input wire [3:0]   applied_floor_tens,applied_floor_ones,
    input wire [1:0]   applied_direction,applied_door,
    input wire [84:0]  boot_metrics
);
    // ===== 常量与回包种类 =====
    // MAX_LINE 是整行缓冲上限（含 "SUB=" 前缀），MAX_TEXT 是字幕正文上限。
    // R_* 是回包种类，决定 reply_char 生成哪一串固定文本。
    localparam integer MAX_TEXT = 12;
    // Optional neutral phrase "照片音乐". No workshop signature is built in.
    localparam [95:0] CN_SUBTITLE_TEXT = {64'd0,8'h83,8'h82,8'h81,8'h80};
    localparam [3:0] R_OK_TEXT = 4'd0;
    localparam [3:0] R_OK_ON   = 4'd1;
    localparam [3:0] R_OK_OFF  = 4'd2;
    localparam [3:0] R_OK_SAVE = 4'd3;
    localparam [3:0] R_QUERY   = 4'd4;
    localparam [3:0] R_SYNTAX  = 4'd5;
    localparam [3:0] R_LONG    = 4'd6;
    localparam [3:0] R_CHAR    = 4'd7;
    localparam [3:0] R_BUSY    = 4'd8;
    localparam [3:0] R_FRAME   = 4'd9;
    localparam [3:0] R_SAVEERR = 4'd10;
    localparam [3:0] R_OK_ELEV = 4'd11;
    localparam [3:0] R_ERR_ELEV = 4'd12;
    localparam [3:0] R_ELEV_QUERY = 4'd13;
    localparam [3:0] R_RESCUE_QUERY = 4'd14;
    localparam [3:0] R_BOOT_QUERY = 4'd15;
    reg [15:0] query_event_id;
    reg [15:0] rescue_reply_crc;
    reg [1:0] query_comm_state;
    reg query_alert,query_basement;
    reg [3:0] query_tens,query_ones;
    reg [1:0] query_direction,query_door;
    wire [2:0] comm_word_length=rescue_comm_state==3 ? 7 : rescue_comm_state==2 ? 5 : 4;
    function [4:0] hex_value;
        input [7:0] ch;
        begin
            if(ch>="0" && ch<="9") hex_value=ch-"0";
            else if(ch>="A" && ch<="F") hex_value=ch-"A"+10;
            else if(ch>="a" && ch<="f") hex_value=ch-"a"+10;
            else hex_value=5'h10;
        end
    endfunction
    function [7:0] hex_char;
        input [3:0] n;
        begin hex_char=n<10 ? "0"+n : "A"+n-10;end
    endfunction
    function [15:0] crc_byte;
        input [15:0] old_crc;
        input [7:0] c;
        reg [15:0] v;
        integer j;
        begin
            v=old_crc^{c,8'h00};
            for(j=0;j<8;j=j+1) v=v[15] ? (v<<1)^16'h1021 : (v<<1);
            crc_byte=v;
        end
    endfunction
    function [7:0] comm_char;
        input [1:0] code;input integer pos;reg[55:0] word;
        begin
            case(code)
                0:word="IDLE   ";1:word="WAIT   ";2:word="ACKED  ";default:word="TIMEOUT";
            endcase
            comm_char=word[55-pos*8 -:8];
        end
    endfunction

    localparam integer LINE_STORAGE = MAX_LINE < 21 ? 21 : MAX_LINE;
    reg [8*LINE_STORAGE-1:0] line_buffer;
    reg [5:0] line_length;
    reg line_overflow;
    reg discard_lf;
    reg waiting_save;
    reg reply_active;
    reg [3:0] reply_kind;
    reg [6:0] reply_index;
    reg [6:0] reply_length;
    reg [95:0] reply_text;
    // A BOOT reply and a subtitle reply are mutually exclusive. Reuse the
    // existing reply snapshot bank instead of adding 85 duplicate registers.
    wire [84:0] query_boot=reply_text[84:0];
    reg [5:0] reply_text_length;
    reg reply_enable;
    reg pending_reply;
    reg [3:0] pending_reply_kind;
    reg [6:0] pending_reply_length;
    integer i;
    reg command_good;
    reg char_good;
    reg [7:0] normalized;
    reg [95:0] parsed_text;
    reg [5:0] parsed_length;

    // 行缓冲与字幕文本都按"字节在低位"存放，下面两个函数就是按下标取字节。
    // 这样 SUB? 回显、大小写转换都可以直接按索引访问，不需要额外的数组。
    function [7:0] line_char;
        input integer index;
        begin
            line_char = line_buffer[index*8 +: 8];
        end
    endfunction

    function [7:0] text_char;
        input [95:0] text_value;
        input integer index;
        begin
            text_char = text_value[index*8 +: 8];
        end
    endfunction

    // 中文短句匹配：只认固定那 12 个字节（"SUB=" + "照片音乐" 的 UTF-8 编码），
    // 不是通用中文解析——不做任何 Unicode 解码，只做逐字节比较。
    function cn_phrase_match;
        input dummy;
        begin
            cn_phrase_match = line_length == 16 &&
                line_char(0)=="S" && line_char(1)=="U" &&
                line_char(2)=="B" && line_char(3)=="=" &&
                line_char(4)==8'he7 && line_char(5)==8'h85 && line_char(6)==8'ha7 &&
                line_char(7)==8'he7 && line_char(8)==8'h89 && line_char(9)==8'h87 &&
                line_char(10)==8'he9 && line_char(11)==8'h9f && line_char(12)==8'hb3 &&
                line_char(13)==8'he4 && line_char(14)==8'hb9 && line_char(15)==8'h90;
        end
    endfunction

    // 回包字节生成：按 kind 和下标拼出固定字符串。
    // OK 系列统一为 "OK\r\n"（4 字节），ERR 系列为 "ERR\r\n"（5 字节）；
    // 查询回包是 "SUB=<0/1>:<文本>\r\n"，长度随文本变化，末尾两字节是 CR、LF。
    function [7:0] reply_char;
        input [3:0] kind;
        input integer index;
        begin
            reply_char = 8'h00;
            case (kind)
                R_OK_TEXT,R_OK_ON,R_OK_OFF,R_OK_SAVE: case(index)
                    0:reply_char="O";1:reply_char="K";
                    2:reply_char=8'h0d;default:reply_char=8'h0a;
                endcase
                R_SYNTAX,R_LONG,R_CHAR,R_BUSY,R_FRAME,R_SAVEERR: case(index)
                    0:reply_char="E";1:reply_char="R";2:reply_char="R";
                    3:reply_char=8'h0d;default:reply_char=8'h0a;
                endcase
                R_OK_ELEV: begin
                    case(index)
                        0:reply_char="O"; 1:reply_char="K";
                        2:reply_char=8'h0d; default:reply_char=8'h0a;
                    endcase
                end
                R_ERR_ELEV: begin
                    case(index)
                        0:reply_char="E"; 1:reply_char="R"; 2:reply_char="R";
                        3:reply_char=" "; 4:reply_char="E"; 5:reply_char="L";
                        6:reply_char="E"; 7:reply_char="V"; 8:reply_char=8'h0d;
                        default:reply_char=8'h0a;
                    endcase
                end
                R_ELEV_QUERY: begin
                    // ELEV=F05,D=U,DO=C,A=0\r\n (23 bytes)
                    case(index)
                        0:reply_char="E"; 1:reply_char="L"; 2:reply_char="E";
                        3:reply_char="V"; 4:reply_char="="; 5:reply_char="F";
                        6:reply_char = query_basement ? "B" : (8'h30 + query_tens);
                        7:reply_char = 8'h30 + query_ones;
                        8:reply_char=","; 9:reply_char="D"; 10:reply_char="=";
                        11:reply_char = query_direction==2'd1 ? "U" :
                                         (query_direction==2'd2 ? "D" : "S");
                        12:reply_char=","; 13:reply_char="D"; 14:reply_char="O";
                        15:reply_char="=";
                        16:reply_char = query_door==2'd1 ? "O" :
                                         (query_door==2'd2 ? "C" : "M");
                        17:reply_char=","; 18:reply_char="A"; 19:reply_char="=";
                        20:reply_char=query_alert ? "1" : "0";
                        21:reply_char=8'h0d; default:reply_char=8'h0a;
                    endcase
                end
                R_BOOT_QUERY: begin
                    // BOOT,SD=hhhh,SC=hhhh,P1=hhhh,TF=hhhh,P5=hhhh,V=hh (ms)
                    case(index)
                        0:reply_char="B";1:reply_char="O";2:reply_char="O";3:reply_char="T";
                        4,12,20,28,36,44:reply_char=",";
                        5:reply_char="S";6:reply_char="D";13:reply_char="S";14:reply_char="C";
                        21:reply_char="P";22:reply_char="1";29:reply_char="T";30:reply_char="F";
                        37:reply_char="P";38:reply_char="5";45:reply_char="V";
                        7,15,23,31,39,46:reply_char="=";
                        8,9,10,11,16,17,18,19,24,25,26,27,32,33,34,35,40,41,42,43:
                            reply_char=hex_char(query_boot[79:76]);
                        47:reply_char=hex_char({3'd0,query_boot[84]});48:reply_char=hex_char(query_boot[83:80]);
                        49:reply_char=8'h0d;default:reply_char=8'h0a;
                    endcase
                end
                R_RESCUE_QUERY: begin
                    case(index)
                        0:reply_char="R";1:reply_char="E";2:reply_char="S";3:reply_char="C";
                        4:reply_char="U";5:reply_char="E";6:reply_char=",";7:reply_char="I";
                        8:reply_char="D";9:reply_char="=";
                        10:reply_char=hex_char(query_event_id[15:12]);
                        11:reply_char=hex_char(query_event_id[11:8]);
                        12:reply_char=hex_char(query_event_id[7:4]);
                        13:reply_char=hex_char(query_event_id[3:0]);
                        14:reply_char=",";15:reply_char="A";16:reply_char="=";17:reply_char=query_alert?"1":"0";
                        18:reply_char=",";19:reply_char="C";20:reply_char="=";
                        default:begin
                            if(index==reply_length-7) reply_char="*";
                            else if(index==reply_length-6) reply_char=hex_char(rescue_reply_crc[15:12]);
                            else if(index==reply_length-5) reply_char=hex_char(rescue_reply_crc[11:8]);
                            else if(index==reply_length-4) reply_char=hex_char(rescue_reply_crc[7:4]);
                            else if(index==reply_length-3) reply_char=hex_char(rescue_reply_crc[3:0]);
                            else if(index==reply_length-2) reply_char=8'h0d;
                            else if(index==reply_length-1) reply_char=8'h0a;
                            else reply_char=comm_char(query_comm_state,index-21);
                        end
                    endcase
                end
                R_QUERY: begin
                    if (index < 4) begin
                        case(index) 0:reply_char="S";1:reply_char="U";2:reply_char="B";default:reply_char="=";endcase
                    end else if (index == 4)
                        reply_char = reply_enable ? "1" : "0";
                    else if (index == 5)
                        reply_char = ":";
                    else if (index < reply_length - 2) begin
                        reply_char = text_char(reply_text,index - 6);
                    end else if (index == reply_length - 2)
                        reply_char = 8'h0d;
                    else
                        reply_char = 8'h0a;
                end
                default: reply_char = 8'h00;
            endcase
        end
    endfunction

    // 启动一条回包：若当前已有回包在发，就把这一条挂到 pending（只挂一条），
    // 等当前回包发完自动接上；两条以上同时到来时后面的会被丢弃，
    // 因为串口回包本来就要求"收到回复再发下一条"。
    task start_reply;
        input [3:0] kind;
        input [6:0] length;
        reg [6:0] actual_length;
        begin
            actual_length = (kind == R_QUERY || kind == R_ELEV_QUERY || kind == R_RESCUE_QUERY || kind == R_BOOT_QUERY) ? length :
                            ((kind <= R_OK_SAVE || kind == R_OK_ELEV) ? 7'd4 :
                             (kind == R_ERR_ELEV ? 7'd10 : 7'd5));
            if (reply_active) begin
                if (!pending_reply) begin
                    pending_reply <= 1'b1;
                    pending_reply_kind <= kind;
                    pending_reply_length <= actual_length;
                end
            end else begin
                reply_kind <= kind;
                reply_length <= actual_length;
                reply_index <= 7'd0;
                reply_active <= 1'b1;
            end
        end
    endtask

    // 回包发送握手：reply_valid 表示当前字节有效，下游取走后 reply_index 前进；
    // 最后一个字节（reply_last）被取走时，若还有 pending 回包就无缝切换到它，
    // 否则关闭 reply_active。这样连续两条命令不会粘在一起。
    assign reply_valid = reply_active;
    assign reply_data = reply_char(reply_kind,reply_index);
    assign reply_last = reply_active && reply_index + 1 >= reply_length;

    // ===== 主解析状态机 =====
    // 每拍先清掉一拍脉冲输出（cfg_update_valid/save_request 只持续一拍），
    // 然后按优先级处理：回包推进 → 保存回执 → 帧错误 → 收字节。
    // 所有命令都等到"行尾"才动作，所以半条命令不会生效。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            line_buffer <= 0;
            line_length <= 0;
            line_overflow <= 0;
            discard_lf <= 0;
            waiting_save <= 0;
            reply_active <= 0;
            reply_kind <= R_SYNTAX;
            reply_index <= 0;
            reply_length <= 0;
            reply_text <= 0;
            reply_text_length <= 0;
            reply_enable <= 0;
            pending_reply <= 0;
            pending_reply_kind <= R_BUSY;
            pending_reply_length <= 0;
            cfg_update_valid <= 0;
            cfg_text <= 0;
            cfg_length <= 0;
            cfg_enable <= 0;
            save_request <= 0;
            elev_update_valid <= 1'b0;
            elev_floor_value <= 8'd0;
            elev_floor_tens <= 4'd0; elev_floor_ones <= 4'd0;
            elev_floor_basement <= 1'b0;
            elev_direction <= 2'd0;
            elev_door <= 2'd0;
            elev_alert_value <= 1'b0;
            elev_alert_update_valid <= 1'b0;
            alert_command_valid <= 1'b0;
            alert_command_value <= 1'b0;
            rescue_ack_valid<=0;rescue_ack_id<=0;query_event_id<=0;query_comm_state<=0;rescue_reply_crc<=16'hffff;
            query_alert<=0;query_basement<=0;query_tens<=0;query_ones<=0;query_direction<=0;query_door<=0;
        end else begin
            cfg_update_valid <= 1'b0;
            save_request <= 1'b0;
            elev_update_valid <= 1'b0;
            elev_alert_update_valid <= 1'b0;
            alert_command_valid <= 1'b0;

            rescue_ack_valid<=0;

            if (reply_active && reply_ready) begin
                if(reply_kind==R_RESCUE_QUERY && reply_index<reply_length-7)
                    rescue_reply_crc<=crc_byte(rescue_reply_crc,reply_data);
                // Serial nibble shift avoids five wide variable-select trees.
                // Shift only accepted hex bytes; stalled replies stay stable.
                if(reply_kind==R_BOOT_QUERY && reply_index>=8 && reply_index<=43 && reply_index[2:0]<4)
                    reply_text<={11'd0,query_boot[84:80],query_boot[75:0],4'd0};
                if (reply_last) begin
                    if (pending_reply) begin
                        reply_kind <= pending_reply_kind;
                        reply_length <= pending_reply_length;
                        reply_index <= 0;
                        pending_reply <= 1'b0;
                    end else begin
                        reply_active <= 1'b0;
                        reply_index <= 0;
                    end
                end else begin
                    reply_index <= reply_index + 1'b1;
                end
            end

            // 保存回执：等待期间不回 OK，必须等下游明确给出 done/failed/dropped
            // 才回 OK 或 ERR——本集成没有字幕存储，所以 SUB=SAVE 一定走到 ERR 分支，
            // 不会假报保存成功。
            if (waiting_save && (save_done || save_failed || request_dropped)) begin
                waiting_save <= 1'b0;
                if (save_done && !save_failed && !request_dropped)
                    start_reply(R_OK_SAVE,10);
                else
                    start_reply(R_SAVEERR,10);
            end

            if (secure_status_valid === 1'b1)
                start_reply(secure_status_ok ? R_OK_ELEV : R_SYNTAX,5);
            if (rx_framing_error)
                start_reply(R_FRAME,11);

            if (rx_valid) begin
                // discard_lf：刚收到 CR，下一个字节若是 LF 就当同一个结束符丢掉。
                // 行尾（CR 或 LF）才进入解析：先判超长/查询/命令，
                // 再判 SUB= 的各个子命令，最后才是普通文本设置。
                if (discard_lf && rx_data == 8'h0a) begin
                    discard_lf <= 1'b0;
                end else if (rx_data == 8'h0d || rx_data == 8'h0a) begin
                    discard_lf <= rx_data == 8'h0d;
                    // ACK is accepted independently of reply capacity and
                    // emits no textual response, preventing an ACK loop.
                    if (!line_overflow && line_length==8 && line_char(0)=="A" &&
                        line_char(1)=="C" && line_char(2)=="K" && line_char(3)=="=" &&
                        hex_value(line_char(4))<16 && hex_value(line_char(5))<16 &&
                        hex_value(line_char(6))<16 && hex_value(line_char(7))<16) begin
                        rescue_ack_id<=(hex_value(line_char(4))<<12) | (hex_value(line_char(5))<<8) |
                                       (hex_value(line_char(6))<<4) | hex_value(line_char(7));
                        rescue_ack_valid<=1;
                    end else if (!reply_active && !waiting_save && line_length != 0) begin
                        if (line_overflow) begin
                            start_reply(R_LONG,10);
                        end else if(line_length==5 && line_char(0)=="B" && line_char(1)=="O" &&
                                    line_char(2)=="O" && line_char(3)=="T" && line_char(4)=="?") begin
                            reply_text<={11'd0,boot_metrics};start_reply(R_BOOT_QUERY,51);
                        end else if(line_length==7 && line_char(0)=="R" && line_char(1)=="E" &&
                                    line_char(2)=="S" && line_char(3)=="C" && line_char(4)=="U" &&
                                    line_char(5)=="E" && line_char(6)=="?") begin
                            query_event_id<=rescue_event_id;query_comm_state<=rescue_comm_state;
                            query_alert<=applied_alert;
                            rescue_reply_crc<=16'hffff;
                            start_reply(R_RESCUE_QUERY,28+comm_word_length);
                        end else if (line_length == 5 &&
                                     line_char(0)=="E" && line_char(1)=="L" &&
                                     line_char(2)=="E" && line_char(3)=="V" &&
                                     line_char(4)=="?") begin
                            query_alert<=APPLIED_STATUS_INPUTS ? applied_alert : elev_alert_value;
                            query_basement<=APPLIED_STATUS_INPUTS ? applied_floor_basement : elev_floor_basement;
                            query_tens<=APPLIED_STATUS_INPUTS ? applied_floor_tens : elev_floor_value/10;
                            query_ones<=APPLIED_STATUS_INPUTS ? applied_floor_ones : elev_floor_value%10;
                            query_direction<=APPLIED_STATUS_INPUTS ? applied_direction : elev_direction;
                            query_door<=APPLIED_STATUS_INPUTS ? applied_door : elev_door;
                            start_reply(R_ELEV_QUERY,23);
                        end else if (line_length == 18 &&
                                     line_char(0)=="F" && line_char(1)=="L" &&
                                     line_char(2)=="O" && line_char(3)=="O" &&
                                     line_char(4)=="R" && line_char(5)=="=" &&
                                     line_char(6)=="F" && line_char(9)=="," &&
                                     line_char(10)=="D" && line_char(11)=="=" &&
                                     line_char(13)=="," && line_char(14)=="D" &&
                                     line_char(15)=="O" && line_char(16)=="=" &&
                                     (((line_char(7)>="0" && line_char(7)<="9") &&
                                       (line_char(8)>="0" && line_char(8)<="9")) ||
                                      (line_char(7)=="B" && line_char(8)>="1" && line_char(8)<="9")) &&
                                     (line_char(12)=="U" || line_char(12)=="D" || line_char(12)=="S") &&
                                     (line_char(17)=="O" || line_char(17)=="C" || line_char(17)=="M")) begin
                            elev_floor_basement<=line_char(7)=="B";
                            elev_floor_value<=line_char(7)=="B" ? line_char(8)-8'h30 :
                                ((line_char(7)-8'h30)*8'd10 + (line_char(8)-8'h30));
                            elev_floor_tens<=line_char(7)=="B" ? 4'd0 : line_char(7)-8'h30;
                            elev_floor_ones<=line_char(8)-8'h30;
                            elev_direction<=line_char(12)=="U" ? 2'd1 :
                                (line_char(12)=="D" ? 2'd2 : 2'd0);
                            elev_door<=line_char(17)=="O" ? 2'd1 :
                                (line_char(17)=="C" ? 2'd2 : 2'd0);
                            elev_update_valid<=1;
                            start_reply(R_OK_ELEV,8);
                        end else if (line_length == 8 &&
                                     line_char(0)=="A" && line_char(1)=="L" &&
                                     line_char(2)=="E" && line_char(3)=="R" &&
                                     line_char(4)=="T" && line_char(5)=="=" &&
                                     line_char(6)=="O" && line_char(7)=="N") begin
                            alert_command_valid <= 1'b1;
                            alert_command_value <= 1'b1;
                            start_reply(R_OK_ELEV,8);
                        end else if (line_length == 9 &&
                                     line_char(0)=="A" && line_char(1)=="L" &&
                                     line_char(2)=="E" && line_char(3)=="R" &&
                                     line_char(4)=="T" && line_char(5)=="=" &&
                                     line_char(6)=="O" && line_char(7)=="F" &&
                                     line_char(8)=="F") begin
                            alert_command_valid <= 1'b1;
                            alert_command_value <= 1'b0;
                            start_reply(R_OK_ELEV,8);
                        end else if (ENABLE_LEGACY_ELEV && line_length >= 5 &&
                                     line_char(0)=="E" && line_char(1)=="L" &&
                                     line_char(2)=="E" && line_char(3)=="V" &&
                                     line_char(4)=="=") begin
                            // Fixed-width ASCII frame: F05 or FB1, U/D/S, O/C/M, 0/1.
                            if (line_length == 21 && line_char(5)=="F" &&
                                line_char(8)=="," && line_char(9)=="D" &&
                                line_char(10)=="=" && line_char(12)=="," &&
                                line_char(13)=="D" && line_char(14)=="O" &&
                                line_char(15)=="=" && line_char(17)=="," &&
                                line_char(18)=="A" && line_char(19)=="=" &&
                                (((line_char(6)>="0" && line_char(6)<="9") &&
                                 (line_char(7)>="0" && line_char(7)<="9")) ||
                                 (line_char(6)=="B" && line_char(7)>="1" && line_char(7)<="9"))) begin
                                if ((line_char(11)=="U" || line_char(11)=="D" || line_char(11)=="S") &&
                                    (line_char(16)=="O" || line_char(16)=="C" || line_char(16)=="M") &&
                                    (line_char(20)=="0" || line_char(20)=="1")) begin
                                    elev_floor_basement <= line_char(6)=="B";
                                    elev_floor_value <= line_char(6)=="B" ?
                                        (line_char(7)-8'h30) :
                                        ((line_char(6)-8'h30)*8'd10 + (line_char(7)-8'h30));
                                    elev_floor_tens <= line_char(6)=="B" ? 4'd0 : line_char(6)-8'h30;
                                    elev_floor_ones <= line_char(7)-8'h30;
                                    elev_direction <= line_char(11)=="U" ? 2'd1 :
                                                      (line_char(11)=="D" ? 2'd2 : 2'd0);
                                    elev_door <= line_char(16)=="O" ? 2'd1 :
                                                 (line_char(16)=="C" ? 2'd2 : 2'd0);
                                    elev_alert_value <= line_char(20)=="1";
                                    elev_update_valid <= 1'b1;
                                    elev_alert_update_valid <= 1'b1;
                                    start_reply(R_OK_ELEV,8);
                                end else begin
                                    start_reply(R_ERR_ELEV,10);
                                end
                            end else begin
                                start_reply(R_ERR_ELEV,10);
                            end
                        end else if (line_length == 4 && line_char(0)=="S" && line_char(1)=="U" && line_char(2)=="B" && line_char(3)=="?") begin
                            reply_text <= live_text;
                            reply_text_length <= live_length;
                            reply_enable <= live_enable;
                            start_reply(R_QUERY,8+live_length);
                        end else if (line_length >= 4 && line_char(0)=="S" && line_char(1)=="U" && line_char(2)=="B" && line_char(3)=="=") begin
                            if (!service_ready) begin
                                start_reply(R_BUSY,10);
                            end else if (line_length==6 && line_char(4)=="O" && line_char(5)=="N") begin
                                cfg_text <= live_text;
                                cfg_length <= live_length;
                                cfg_enable <= 1'b1;
                                cfg_update_valid <= 1'b1;
                                start_reply(R_OK_ON,7);
                            end else if (line_length==7 && line_char(4)=="O" && line_char(5)=="F" && line_char(6)=="F") begin
                                cfg_text <= live_text;
                                cfg_length <= live_length;
                                cfg_enable <= 1'b0;
                                cfg_update_valid <= 1'b1;
                                start_reply(R_OK_OFF,8);
                            end else if (line_length==8 && line_char(4)=="S" && line_char(5)=="A" && line_char(6)=="V" && line_char(7)=="E") begin
                                save_request <= 1'b1;
                                waiting_save <= 1'b1;
                            end else if ((line_length == 6 && line_char(4)=="C" && line_char(5)=="N") ||
                                         cn_phrase_match(1'b0)) begin
                                cfg_text <= CN_SUBTITLE_TEXT;
                                cfg_length <= 6'd4;
                                cfg_enable <= live_enable;
                                cfg_update_valid <= 1'b1;
                                start_reply(R_OK_TEXT,9);
                            end else begin
                                // 普通文本设置：命令总长不超过 16（"SUB=" + 12 字符），
                                // 小写转大写，非可打印 ASCII（0x20~0x7E）判为非法。
                                // 越界/非法只回 ERR，不会改动当前生效字幕。
                                command_good = line_length <= 16;
                                char_good = 1'b1;
                                parsed_text = 0;
                                parsed_length = line_length - 4;
                                for (i=0;i<MAX_TEXT;i=i+1) begin
                                    if (i < parsed_length) begin
                                        normalized = line_char(i+4);
                                        if (normalized >= "a" && normalized <= "z")
                                            normalized = normalized - 8'd32;
                                        if (normalized < 8'h20 || normalized > 8'h7e)
                                            char_good = 1'b0;
                                        parsed_text[i*8 +: 8] = normalized;
                                    end
                                end
                                if (!command_good)
                                    start_reply(R_LONG,10);
                                else if (!char_good)
                                    start_reply(R_CHAR,10);
                                else begin
                                    cfg_text <= parsed_text;
                                    cfg_length <= parsed_length;
                                    cfg_enable <= live_enable;
                                    cfg_update_valid <= 1'b1;
                                    start_reply(R_OK_TEXT,9);
                                end
                            end
                        end else begin
                            start_reply(R_SYNTAX,12);
                        end
                    end else if (line_length != 0) begin
                        start_reply(R_BUSY,10);
                    end
                    line_length <= 0;
                    line_overflow <= 0;
                end else begin
                    // 普通字节：追加进行缓冲；超过 40 字节只置 overflow 标志，
                    // 仍然继续把这一行收完，等行尾再统一回 ERR，避免残行污染下一条命令。
                    discard_lf <= 1'b0;
                    if (line_length < MAX_LINE) begin
                        line_buffer[line_length*8 +: 8] <= rx_data;
                        line_length <= line_length + 1'b1;
                    end else begin
                        line_overflow <= 1'b1;
                    end
                end
            end
        end
    end
endmodule
