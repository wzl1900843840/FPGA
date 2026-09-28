`timescale 1ns/1ps

module subtitle_uart_controller (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [7:0]   rx_data,
    input  wire         rx_valid,
    input  wire         rx_framing_error,
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
    output wire         reply_valid,
    output wire [7:0]   reply_data,
    output wire         reply_last,
    input  wire         reply_ready
);
    localparam integer MAX_LINE = 40;
    localparam integer MAX_TEXT = 12;
    localparam [95:0] CN_SUBTITLE_TEXT = {
        8'h00,8'h00,8'h00,8'h88,8'h87,8'h86,
        8'h85,8'h84,8'h83,8'h82,8'h81,8'h80
    };
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

    reg [8*MAX_LINE-1:0] line_buffer;
    reg [5:0] line_length;
    reg line_overflow;
    reg discard_lf;
    reg waiting_save;
    reg reply_active;
    reg [3:0] reply_kind;
    reg [6:0] reply_index;
    reg [6:0] reply_length;
    reg [95:0] reply_text;
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

    function cn_phrase_match;
        input dummy;
        begin
            cn_phrase_match = line_length == 31 &&
                line_char(0)=="S" && line_char(1)=="U" &&
                line_char(2)=="B" && line_char(3)=="=" &&
                line_char(4)==8'he7 && line_char(5)==8'hb1 && line_char(6)==8'hb3 &&
                line_char(7)==8'he9 && line_char(8)==8'h86 && line_char(9)==8'h8b &&
                line_char(10)==8'he7 && line_char(11)==8'h94 && line_char(12)==8'hb5 &&
                line_char(13)==8'he5 && line_char(14)==8'had && line_char(15)==8'h90 &&
                line_char(16)==8'he5 && line_char(17)==8'hb7 && line_char(18)==8'ha5 &&
                line_char(19)==8'he4 && line_char(20)==8'hbd && line_char(21)==8'h9c &&
                line_char(22)==8'he5 && line_char(23)==8'hae && line_char(24)==8'ha4 &&
                line_char(25)==8'he5 && line_char(26)==8'hbf && line_char(27)==8'ha7 &&
                line_char(28)==8'he9 && line_char(29)==8'h83 && line_char(30)==8'h81;
        end
    endfunction

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

    task start_reply;
        input [3:0] kind;
        input [6:0] length;
        reg [6:0] actual_length;
        begin
            actual_length = kind == R_QUERY ? length :
                            (kind <= R_OK_SAVE ? 7'd4 : 7'd5);
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

    assign reply_valid = reply_active;
    assign reply_data = reply_char(reply_kind,reply_index);
    assign reply_last = reply_active && reply_index + 1 >= reply_length;

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
        end else begin
            cfg_update_valid <= 1'b0;
            save_request <= 1'b0;

            if (reply_active && reply_ready) begin
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

            if (waiting_save && (save_done || save_failed || request_dropped)) begin
                waiting_save <= 1'b0;
                if (save_done && !save_failed && !request_dropped)
                    start_reply(R_OK_SAVE,10);
                else
                    start_reply(R_SAVEERR,10);
            end

            if (rx_framing_error)
                start_reply(R_FRAME,11);

            if (rx_valid) begin
                if (discard_lf && rx_data == 8'h0a) begin
                    discard_lf <= 1'b0;
                end else if (rx_data == 8'h0d || rx_data == 8'h0a) begin
                    discard_lf <= rx_data == 8'h0d;
                    if (!reply_active && !waiting_save && line_length != 0) begin
                        if (line_overflow) begin
                            start_reply(R_LONG,10);
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
                                cfg_length <= 6'd9;
                                cfg_enable <= live_enable;
                                cfg_update_valid <= 1'b1;
                                start_reply(R_OK_TEXT,9);
                            end else begin
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
