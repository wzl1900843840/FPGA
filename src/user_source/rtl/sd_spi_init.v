`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// SD卡上电初始化（SPI 模式）
//
// 这一步必须用很慢的 SPI 时钟（约390.625kHz），因为卡刚上电还没跑起来。
// 顺序是 SD 规范定死的，少一步卡就不认：
//   1) 上电先等一段时间（STARTUP_DELAY_CYCLES，默认5,000,000拍≈100ms），
//      期间 CS 拉高、只发 0xFF 空字节给卡供电时钟；
//   2) CMD0：让卡进入 SPI 模式，回应 0x01；
//   3) CMD8：带参数 0x1AA，用来判断是不是 V2 卡（SDHC/SDXC）。老卡会不回应，
//      这时按 V1 卡继续；
//   4) 循环 CMD55 + ACMD41：反复问"初始化好了吗"，直到卡回 0x00，
//      表示它准备好并且 OCR 里的 busy 位清了；
//   5) CMD58：读 OCR，取 CCS 位判断是不是高容量卡（决定后面地址按块还是按字节）。
//
// 输出：init_ready=卡可用；card_high_capacity/ocr 供读扇区模块换算地址；
//      error_code 非0表示失败（哪一步、是超时还是状态错，见下面的错误码）；
//      last_cmd/last_r1/acmd41_attempts 是留给调试观察的。
//
// 每个命令都分成 *_ISSUE（发命令）和 *_WAIT（等响应）两个状态，
// 因为下面的字节引擎和命令引擎一次只能处理一个字节/一条命令，需要握手。
// -----------------------------------------------------------------------------
module sd_spi_init #(
    parameter integer SPI_CLK_DIV = 4,
    parameter integer POWER_UP_BYTES = 80,
    parameter integer MAX_RESPONSE_BYTES = 16,
    parameter integer MAX_ACMD41_ATTEMPTS = 2048,
    parameter integer STARTUP_DELAY_CYCLES = 4000000  // 100ms at 40MHz
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        init_start,
    output wire        init_busy,
    output reg         init_done,
    output reg         init_ready,
    output reg  [7:0]  error_code,
    output reg         card_high_capacity,
    output reg  [31:0] ocr,
    output reg  [5:0]  last_cmd,
    output reg  [7:0]  last_r1,
    output reg  [15:0] acmd41_attempts,
    output wire        sd_cs_n,
    output wire        sd_sclk,
    output wire        sd_mosi,
    input  wire        sd_miso
);

    // 错误码按"哪条命令 + 超时还是状态错"分类，方便定位卡在哪一步
    localparam ERR_NONE           = 8'h00;
    localparam ERR_CMD0_TIMEOUT   = 8'h01;
    localparam ERR_CMD0_R1        = 8'h02;
    localparam ERR_CMD8_TIMEOUT   = 8'h03;
    localparam ERR_CMD8_R1        = 8'h04;
    localparam ERR_CMD8_ECHO      = 8'h05;
    localparam ERR_CMD55_TIMEOUT  = 8'h06;
    localparam ERR_CMD55_R1       = 8'h07;
    localparam ERR_ACMD41_TIMEOUT = 8'h08;
    localparam ERR_ACMD41_R1      = 8'h09;
    localparam ERR_CMD58_TIMEOUT  = 8'h0a;
    localparam ERR_CMD58_R1       = 8'h0b;
    localparam ERR_OCR_NOT_READY  = 8'h0c;

    // 状态机：按 SD 规范顺序走 CMD0 → CMD8 → (CMD55+ACMD41)* → CMD58
    localparam ST_IDLE          = 5'd0;
    localparam ST_STARTUP_DELAY = 5'd15;
    localparam ST_POWER_REQ     = 5'd1;
    localparam ST_POWER_WAIT    = 5'd2;
    localparam ST_CMD0_ISSUE    = 5'd3;
    localparam ST_CMD0_WAIT     = 5'd4;
    localparam ST_CMD8_ISSUE    = 5'd5;
    localparam ST_CMD8_WAIT     = 5'd6;
    localparam ST_CMD55_ISSUE   = 5'd7;
    localparam ST_CMD55_WAIT    = 5'd8;
    localparam ST_ACMD41_ISSUE  = 5'd9;
    localparam ST_ACMD41_WAIT   = 5'd10;
    localparam ST_CMD58_ISSUE   = 5'd11;
    localparam ST_CMD58_WAIT    = 5'd12;

    reg [4:0] state;
    reg [7:0] power_byte_count;
    reg [31:0] startup_delay_cnt; // 50MHz下100ms需要23位；保留32位参数范围
    reg card_v2;
    reg power_byte_start;
    reg command_start;

    wire byte_busy;
    wire byte_done;
    wire [7:0] byte_rx;
    wire command_busy;
    wire command_done;
    wire command_timeout;
    wire [7:0] command_r1;
    wire [31:0] command_data;
    wire command_cs_n;
    wire command_byte_start;
    wire [7:0] command_byte_tx;
    wire selected_byte_start;
    wire [7:0] selected_byte_tx;

    reg [5:0] selected_cmd_index;
    reg [31:0] selected_cmd_argument;
    reg [7:0] selected_cmd_crc;
    reg [2:0] selected_extra_bytes;

    assign init_busy = (state != ST_IDLE);
    assign selected_byte_start = (state == ST_POWER_REQ || state == ST_POWER_WAIT)
                               ? power_byte_start : command_byte_start;
    assign selected_byte_tx = (state == ST_POWER_REQ || state == ST_POWER_WAIT)
                            ? 8'hff : command_byte_tx;
    assign sd_cs_n = (state == ST_POWER_REQ || state == ST_POWER_WAIT || state == ST_IDLE || state == ST_STARTUP_DELAY)
                   ? 1'b1 : command_cs_n;

    always @* begin
        selected_cmd_index    = 6'd0;
        selected_cmd_argument = 32'd0;
        selected_cmd_crc      = 8'hff;
        selected_extra_bytes  = 3'd0;
        case (state)
            ST_CMD0_ISSUE, ST_CMD0_WAIT: begin
                selected_cmd_index = 6'd0;
                selected_cmd_crc   = 8'h95;
            end
            ST_CMD8_ISSUE, ST_CMD8_WAIT: begin
                selected_cmd_index    = 6'd8;
                selected_cmd_argument = 32'h000001aa;
                selected_cmd_crc      = 8'h87;
                selected_extra_bytes  = 3'd4;
            end
            ST_CMD55_ISSUE, ST_CMD55_WAIT: begin
                selected_cmd_index = 6'd55;
            end
            ST_ACMD41_ISSUE, ST_ACMD41_WAIT: begin
                selected_cmd_index    = 6'd41;
                selected_cmd_argument = card_v2 ? 32'h40000000 : 32'h00000000;
            end
            ST_CMD58_ISSUE, ST_CMD58_WAIT: begin
                selected_cmd_index   = 6'd58;
                selected_extra_bytes = 3'd4;
            end
            default: begin end
        endcase
    end

    sd_spi_byte_engine #(
        .CLK_DIV(SPI_CLK_DIV)
    ) u_byte_engine (
        .clk(clk), .rst_n(rst_n),
        .start(selected_byte_start), .tx_byte(selected_byte_tx),
        .miso(sd_miso), .busy(byte_busy), .done(byte_done),
        .rx_byte(byte_rx), .sclk(sd_sclk), .mosi(sd_mosi)
    );

    sd_spi_command #(
        .MAX_RESPONSE_BYTES(MAX_RESPONSE_BYTES)
    ) u_command (
        .clk(clk), .rst_n(rst_n), .start(command_start),
        .cmd_index(selected_cmd_index),
        .cmd_argument(selected_cmd_argument), .cmd_crc(selected_cmd_crc),
        .extra_response_bytes(selected_extra_bytes),
        .busy(command_busy), .done(command_done),
        .response_timeout(command_timeout), .r1(command_r1),
        .response_data(command_data), .cs_n(command_cs_n),
        .byte_start(command_byte_start), .byte_tx(command_byte_tx),
        .byte_busy(byte_busy), .byte_done(byte_done), .byte_rx(byte_rx)
    );

    task finish_with_error;
        input [7:0] code;
        begin
            error_code <= code;
            init_ready <= 1'b0;
            init_done  <= 1'b1;
            state      <= ST_IDLE;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state              <= ST_IDLE;
            power_byte_count   <= 8'd0;
            card_v2            <= 1'b0;
            power_byte_start   <= 1'b0;
            command_start      <= 1'b0;
            init_done          <= 1'b0;
            init_ready         <= 1'b0;
            error_code         <= ERR_NONE;
            card_high_capacity <= 1'b0;
            ocr                <= 32'd0;
            last_cmd           <= 6'd0;
            last_r1            <= 8'hff;
            acmd41_attempts    <= 16'd0;
            startup_delay_cnt   <= 22'd0;
        end else begin
            init_done        <= 1'b0;
            power_byte_start <= 1'b0;
            command_start    <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (init_start) begin
                        power_byte_count   <= 8'd0;
                        card_v2            <= 1'b0;
                        init_ready         <= 1'b0;
                        error_code         <= ERR_NONE;
                        card_high_capacity <= 1'b0;
                        ocr                <= 32'd0;
                        last_cmd           <= 6'd0;
                        last_r1            <= 8'hff;
                        acmd41_attempts    <= 16'd0;
                        startup_delay_cnt  <= 22'd0;
                        state              <= ST_STARTUP_DELAY;
                    end
                end

                ST_STARTUP_DELAY: begin
                    if (startup_delay_cnt >= STARTUP_DELAY_CYCLES) begin
                        state <= ST_POWER_REQ;
                    end else begin
                        startup_delay_cnt <= startup_delay_cnt + 1'b1;
                    end
                end

                ST_POWER_REQ: begin
                    if (!byte_busy) begin
                        power_byte_start <= 1'b1;
                        state <= ST_POWER_WAIT;
                    end
                end

                ST_POWER_WAIT: begin
                    if (byte_done) begin
                        if (power_byte_count == POWER_UP_BYTES-1) begin
                            state <= ST_CMD0_ISSUE;
                        end else begin
                            power_byte_count <= power_byte_count + 1'b1;
                            state <= ST_POWER_REQ;
                        end
                    end
                end

                ST_CMD0_ISSUE, ST_CMD8_ISSUE, ST_CMD55_ISSUE,
                ST_ACMD41_ISSUE, ST_CMD58_ISSUE: begin
                    if (!command_busy) begin
                        command_start <= 1'b1;
                        case (state)
                            ST_CMD0_ISSUE:   state <= ST_CMD0_WAIT;
                            ST_CMD8_ISSUE:   state <= ST_CMD8_WAIT;
                            ST_CMD55_ISSUE:  state <= ST_CMD55_WAIT;
                            ST_ACMD41_ISSUE: state <= ST_ACMD41_WAIT;
                            default:         state <= ST_CMD58_WAIT;
                        endcase
                    end
                end

                ST_CMD0_WAIT: if (command_done) begin
                    last_cmd <= 6'd0;
                    last_r1  <= command_r1;
                    if (command_timeout)
                        finish_with_error(ERR_CMD0_TIMEOUT);
                    else if (command_r1 != 8'h01)
                        finish_with_error(ERR_CMD0_R1);
                    else
                        state <= ST_CMD8_ISSUE;
                end

                ST_CMD8_WAIT: if (command_done) begin
                    last_cmd <= 6'd8;
                    last_r1  <= command_r1;
                    if (command_timeout) begin
                        finish_with_error(ERR_CMD8_TIMEOUT);
                    end else if (command_r1 == 8'h01) begin
                        if (command_data[11:0] != 12'h1aa)
                            finish_with_error(ERR_CMD8_ECHO);
                        else begin
                            card_v2 <= 1'b1;
                            state <= ST_CMD55_ISSUE;
                        end
                    end else if (command_r1 == 8'h05) begin
                        card_v2 <= 1'b0;
                        state <= ST_CMD55_ISSUE;
                    end else begin
                        finish_with_error(ERR_CMD8_R1);
                    end
                end

                ST_CMD55_WAIT: if (command_done) begin
                    last_cmd <= 6'd55;
                    last_r1  <= command_r1;
                    if (command_timeout)
                        finish_with_error(ERR_CMD55_TIMEOUT);
                    else if (command_r1 != 8'h01)
                        finish_with_error(ERR_CMD55_R1);
                    else
                        state <= ST_ACMD41_ISSUE;
                end

                ST_ACMD41_WAIT: if (command_done) begin
                    last_cmd <= 6'd41;
                    last_r1  <= command_r1;
                    acmd41_attempts <= acmd41_attempts + 1'b1;
                    if (command_timeout) begin
                        finish_with_error(ERR_ACMD41_TIMEOUT);
                    end else if (command_r1 == 8'h00) begin
                        state <= ST_CMD58_ISSUE;
                    end else if (command_r1 == 8'h01) begin
                        if (acmd41_attempts == MAX_ACMD41_ATTEMPTS-1)
                            finish_with_error(ERR_ACMD41_TIMEOUT);
                        else
                            state <= ST_CMD55_ISSUE;
                    end else begin
                        finish_with_error(ERR_ACMD41_R1);
                    end
                end

                ST_CMD58_WAIT: if (command_done) begin
                    last_cmd <= 6'd58;
                    last_r1  <= command_r1;
                    ocr      <= command_data;
                    if (command_timeout) begin
                        finish_with_error(ERR_CMD58_TIMEOUT);
                    end else if (command_r1 != 8'h00) begin
                        finish_with_error(ERR_CMD58_R1);
                    end else if (!command_data[31]) begin
                        finish_with_error(ERR_OCR_NOT_READY);
                    end else begin
                        card_high_capacity <= card_v2 && command_data[30];
                        error_code <= ERR_NONE;
                        init_ready <= 1'b1;
                        init_done  <= 1'b1;
                        state      <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
