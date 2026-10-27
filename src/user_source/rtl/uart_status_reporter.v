`timescale 1ns/1ps

// Human-readable player status over the board UART transmitter. Reports the
// boot banner, every image switch, parameter menu changes and error codes as
// short CR/LF ASCII lines through one verified uart_tx_byte instance.
// The message bytes are produced combinationally by a character function
// from a latched event snapshot: no byte array exists, which keeps every
// path short enough for the 50 MHz system clock. Dynamic values print in
// hexadecimal to avoid divider logic.
module uart_status_reporter #(
    parameter integer CLKS_PER_BIT = 434
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    input  wire [1:0]  media_id,
    input  wire [7:0]  volume,
    input  wire [31:0] period_ms,
    input  wire        auto_enabled,
    input  wire        switch_event,
    input  wire        menu_event,
    input  wire [1:0]  menu_kind,
    input  wire [7:0]  error_code,
    input  wire        bright_event,
    input  wire [7:0]  bright_value,
    // Effective system-domain alarm, independent of the video/media state.
    input  wire        alert_request,
    input  wire [1:0]  alert_sources, // bit0 UART, bit1 local switch
    input  wire        floor_valid,
    input  wire        floor_basement,
    input  wire [3:0]  floor_tens,
    input  wire [3:0]  floor_ones,
    input  wire [1:0]  direction,
    input  wire [1:0]  door,
    output reg         rescue_overflow,
    input  wire        reply_valid,
    input  wire [7:0]  reply_data,
    input  wire        reply_last,
    output reg         reply_ready,
    output wire        uart_tx
);
    localparam [7:0] CR = 8'h0d;
    localparam [7:0] LF = 8'h0a;

    localparam [2:0] K_BANNER = 3'd0;
    localparam [2:0] K_PIC    = 3'd1;
    localparam [2:0] K_VOL    = 3'd2;
    localparam [2:0] K_PRD    = 3'd3;
    localparam [2:0] K_ERR    = 3'd4;
    localparam [2:0] K_BRT    = 3'd5;
    localparam [2:0] K_RESCUE = 3'd6;

    reg [2:0] kind_q;
    reg [1:0] pic_id_q;
    reg pic_auto_q;
    reg [7:0] val8_q;
    reg [31:0] val32_q;
    reg [5:0] msg_len;
    reg [5:0] send_index;
    reg tx_start_r;
    reg [1:0] state;
    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_SEND = 2'd1;
    localparam [1:0] ST_REPLY = 2'd2;
    reg [7:0] tx_data_r;
    reg reply_last_q;
    reg reply_wait;

    reg enable_q;
    reg switch_q;
    reg [1:0] switch_id_q;
    reg switch_auto_q;
    reg error_active_q;
    reg menu_pending;
    reg [1:0] menu_kind_q;
    reg bright_pending;
    reg [7:0] bright_val_q;

    // Four pending event snapshots plus the in-flight frame. Short pulses are
    // retained while capacity remains; complete output lines stay atomic.
    // Overflow is sticky until reset; it is exposed to the top-level error OSD.
    reg alert_seen;
    reg [1:0] last_alert_sources;
    reg [15:0] rescue_sequence;
    reg [40:0] rescue_fifo [0:3];
    reg [1:0] rescue_wr, rescue_rd;
    reg [2:0] rescue_count;
    reg [40:0] rescue_snapshot;
    wire rescue_pop = state == ST_IDLE && rescue_count != 0;
    wire rescue_edge = alert_request != alert_seen;
    wire rescue_push = rescue_edge && (rescue_count < 4 || rescue_pop);
    wire [15:0] report_id;
    wire report_alert, report_floor_valid, report_basement;
    wire [3:0] report_tens, report_ones;
    wire [1:0] report_direction, report_door, report_sources;
    wire [7:0] report_error;
    assign {report_id, report_alert, report_floor_valid, report_basement,
            report_tens, report_ones, report_direction, report_door,
            report_sources, report_error} = rescue_snapshot;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            alert_seen <= 1'b0;
            last_alert_sources <= 2'd0;
            rescue_sequence <= 16'd1;
            rescue_wr <= 2'd0; rescue_rd <= 2'd0; rescue_count <= 3'd0;
            rescue_snapshot <= 41'd0;
            rescue_overflow <= 1'b0;
        end else begin
            alert_seen <= alert_request;
            if (alert_request) last_alert_sources <= alert_sources;
            if (rescue_edge) begin
                rescue_sequence <= rescue_sequence + 1'b1;
                if (!rescue_push) rescue_overflow <= 1'b1;
            end
            if (rescue_push) begin
                rescue_fifo[rescue_wr] <= {rescue_sequence, alert_request,
                    floor_valid, floor_basement, floor_tens, floor_ones,
                    direction, door,
                    alert_request ? alert_sources : last_alert_sources, error_code};
                rescue_wr <= rescue_wr + 1'b1;
            end
            if (rescue_pop) begin
                rescue_snapshot <= rescue_fifo[rescue_rd];
                rescue_rd <= rescue_rd + 1'b1;
            end
            case ({rescue_push, rescue_pop})
                2'b10: rescue_count <= rescue_count + 1'b1;
                2'b01: rescue_count <= rescue_count - 1'b1;
                default: ;
            endcase
        end
    end

    wire tx_busy;
    wire tx_done;

    uart_tx_byte #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(clk), .rst_n(rst_n),
        .start(tx_start_r), .data(tx_data_r),
        .tx(uart_tx), .busy(tx_busy), .done(tx_done)
    );

    function [7:0] hex_digit;
        input [3:0] nibble;
        begin
            hex_digit = (nibble < 4'ha) ? (8'h30 + {4'b0, nibble})
                                        : (8'h37 + {4'b0, nibble});
        end
    endfunction

    function [7:0] msg_char;
        input [2:0] kind;
        input [5:0] idx;
        begin
            case (kind)
            K_BANNER: case (idx)
                0: msg_char = "M"; 1: msg_char = "E"; 2: msg_char = "D";
                3: msg_char = "I"; 4: msg_char = "A"; 5: msg_char = " ";
                6: msg_char = "P"; 7: msg_char = "L"; 8: msg_char = "A";
                9: msg_char = "Y"; 10: msg_char = "E"; 11: msg_char = "R";
                12: msg_char = " "; 13: msg_char = "R"; 14: msg_char = "E";
                15: msg_char = "A"; 16: msg_char = "D"; 17: msg_char = "Y";
                18: msg_char = CR; 19: msg_char = LF;
                default: msg_char = 8'h00;
            endcase
            K_PIC: case (idx)
                0: msg_char = "P"; 1: msg_char = "I"; 2: msg_char = "C";
                3: msg_char = " "; 4: msg_char = "1" + {6'b0, pic_id_q};
                5: msg_char = " ";
                6: msg_char = pic_auto_q ? "A" : "M";
                7: msg_char = CR; 8: msg_char = LF;
                default: msg_char = 8'h00;
            endcase
            K_VOL: case (idx)
                0: msg_char = "V"; 1: msg_char = "O"; 2: msg_char = "L";
                3: msg_char = " ";
                4: msg_char = hex_digit(val8_q[7:4]);
                5: msg_char = hex_digit(val8_q[3:0]);
                6: msg_char = CR; 7: msg_char = LF;
                default: msg_char = 8'h00;
            endcase
            K_PRD: case (idx)
                0: msg_char = "P"; 1: msg_char = "R"; 2: msg_char = "D";
                3: msg_char = " ";
                4: msg_char = hex_digit(val32_q[19:16]);
                5: msg_char = hex_digit(val32_q[15:12]);
                6: msg_char = hex_digit(val32_q[11:8]);
                7: msg_char = hex_digit(val32_q[7:4]);
                8: msg_char = hex_digit(val32_q[3:0]);
                9: msg_char = "m"; 10: msg_char = "s";
                11: msg_char = CR; 12: msg_char = LF;
                default: msg_char = 8'h00;
            endcase
            K_ERR: case (idx)
                0: msg_char = "E"; 1: msg_char = "R"; 2: msg_char = "R";
                3: msg_char = " ";
                4: msg_char = hex_digit(val8_q[7:4]);
                5: msg_char = hex_digit(val8_q[3:0]);
                6: msg_char = CR; 7: msg_char = LF;
                default: msg_char = 8'h00;
            endcase
            K_BRT: case (idx)
                0: msg_char = "B"; 1: msg_char = "R"; 2: msg_char = "T";
                3: msg_char = " ";
                4: msg_char = hex_digit(val8_q[7:4]);
                5: msg_char = hex_digit(val8_q[3:0]);
                6: msg_char = CR; 7: msg_char = LF;
                default: msg_char = 8'h00;
            endcase
            K_RESCUE: case (idx)
                0:msg_char="R"; 1:msg_char="E"; 2:msg_char="S";
                3:msg_char="C"; 4:msg_char="U"; 5:msg_char="E";
                6:msg_char=","; 7:msg_char="I"; 8:msg_char="D"; 9:msg_char="=";
                10:msg_char=hex_digit(report_id[15:12]);
                11:msg_char=hex_digit(report_id[11:8]);
                12:msg_char=hex_digit(report_id[7:4]);
                13:msg_char=hex_digit(report_id[3:0]);
                14:msg_char=","; 15:msg_char="A"; 16:msg_char="=";
                17:msg_char=report_alert ? "1" : "0";
                18:msg_char=","; 19:msg_char="F"; 20:msg_char="=";
                21:msg_char=!report_floor_valid ? "-" :
                    (report_basement ? "B" : hex_digit(report_tens));
                22:msg_char=!report_floor_valid ? "-" : hex_digit(report_ones);
                23:msg_char=","; 24:msg_char="D"; 25:msg_char="=";
                26:msg_char=report_direction==1 ? "U" : (report_direction==2 ? "D" : "S");
                27:msg_char=","; 28:msg_char="D"; 29:msg_char="O"; 30:msg_char="=";
                31:msg_char=report_door==1 ? "O" : (report_door==2 ? "C" : "M");
                32:msg_char=","; 33:msg_char="S"; 34:msg_char="=";
                35:msg_char=report_sources==2 ? "L" : (report_sources==3 ? "B" : "U");
                36:msg_char=","; 37:msg_char="E"; 38:msg_char="=";
                39:msg_char=hex_digit(report_error[7:4]);
                40:msg_char=hex_digit(report_error[3:0]);
                41:msg_char=CR; 42:msg_char=LF;
                default:msg_char=8'h00;
            endcase
            default: msg_char = 8'h00;
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            kind_q <= K_BANNER;
            pic_id_q <= 2'd0;
            pic_auto_q <= 1'b0;
            val8_q <= 8'd0;
            val32_q <= 32'd0;
            msg_len <= 5'd0;
            send_index <= 5'd0;
            tx_start_r <= 1'b0;
            enable_q <= 1'b0;
            switch_q <= 1'b0;
            switch_id_q <= 2'd0;
            switch_auto_q <= 1'b0;
            error_active_q <= 1'b0;
            menu_pending <= 1'b0;
            menu_kind_q <= 2'd0;
            bright_pending <= 1'b0;
            bright_val_q <= 8'd0;
            tx_data_r <= 8'd0;
            reply_last_q <= 1'b0;
            reply_wait <= 1'b0;
            reply_ready <= 1'b0;
        end else begin
            reply_ready <= 1'b0;
            enable_q <= enable;
            switch_q <= switch_event;
            switch_id_q <= media_id;
            switch_auto_q <= auto_enabled;
            if (menu_event) begin
                menu_pending <= 1'b1;
                menu_kind_q <= menu_kind;
            end
            if (bright_event) begin
                bright_pending <= 1'b1;
                bright_val_q <= bright_value;
            end

            case (state)
            ST_IDLE: begin
                tx_start_r <= 1'b0;
                send_index <= 5'd0;
                // 上一字节的 ready 为寄存脉冲，给解析器一拍撤销 last。
                if (rescue_pop) begin
                    kind_q <= K_RESCUE;
                    msg_len <= 6'd43;
                    state <= ST_SEND;
                end else if (reply_valid && !reply_ready) begin
                    tx_data_r <= reply_data;
                    reply_last_q <= reply_last;
                    reply_wait <= 1'b0;
                    tx_start_r <= 1'b1;
                    state <= ST_REPLY;
                end else if (!enable_q && enable) begin
                    kind_q <= K_BANNER;
                    msg_len <= 5'd20;
                    state <= ST_SEND;
                end else if ((error_code != 8'd0) && !error_active_q) begin
                    error_active_q <= 1'b1;
                    kind_q <= K_ERR;
                    val8_q <= error_code;
                    msg_len <= 5'd8;
                    state <= ST_SEND;
                end else if ((error_code == 8'd0) && error_active_q) begin
                    error_active_q <= 1'b0;
                end else if (switch_q) begin
                    kind_q <= K_PIC;
                    pic_id_q <= switch_id_q;
                    pic_auto_q <= switch_auto_q;
                    msg_len <= 5'd9;
                    state <= ST_SEND;
                end else if (menu_pending) begin
                    menu_pending <= 1'b0;
                    if (menu_kind_q == 2'd0) begin
                        kind_q <= K_VOL;
                        val8_q <= volume;
                        msg_len <= 5'd8;
                    end else begin
                        kind_q <= K_PRD;
                        val32_q <= period_ms;
                        msg_len <= 5'd13;
                    end
                    state <= ST_SEND;
                end else if (bright_pending) begin
                    bright_pending <= 1'b0;
                    kind_q <= K_BRT;
                    val8_q <= bright_val_q;
                    msg_len <= 5'd8;
                    state <= ST_SEND;
                end
            end
            ST_SEND: begin
                if (tx_done)
                    send_index <= send_index + 1'b1;
                if (send_index >= msg_len) begin
                    tx_start_r <= 1'b0;
                    send_index <= 5'd0;
                    state <= ST_IDLE;
                end else if (!tx_busy && !tx_start_r && !tx_done) begin
                    tx_data_r <= msg_char(kind_q, send_index);
                    tx_start_r <= 1'b1;
                end else begin
                    tx_start_r <= 1'b0;
                end
            end
            ST_REPLY: begin
                tx_start_r <= 1'b0;
                if (tx_done) begin
                    reply_ready <= 1'b1;
                    reply_wait <= !reply_last_q;
                    if (reply_last_q)
                        state <= ST_IDLE;
                end else if (reply_wait) begin
                    reply_wait <= 1'b0;
                end else if (!tx_busy && !tx_start_r && reply_valid) begin
                    tx_data_r <= reply_data;
                    reply_last_q <= reply_last;
                    tx_start_r <= 1'b1;
                end
            end
            default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
