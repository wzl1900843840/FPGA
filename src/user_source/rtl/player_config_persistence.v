`timescale 1ns/1ps

// 模块职责：播放参数的掉电保存与开机恢复（周期 / 音量 / 自动模式）。
// 位置：上游是顶层的按键事件与菜单结果，下游是 media_video_pipeline（周期、模式）
//       和 OSD/数码管（音量），并独占一片 W25X64 用户 Flash 的 SPI 接口。
// 时钟域：50MHz 系统时钟 clk，单域；SPI 由内部分频产生。
// 存储布局：Flash 末尾划出两个 4KB 槽（SLOT0=0x7FE000、SLOT1=0x7FF000），
//       每槽记录"版本号 + 周期 + 音量 + 模式 + CRC"，两块互为备份。
// 输入约定：cfg_update_valid 是"新参数要生效"的单拍脉冲，save_request 是"写 Flash"请求；
//       两者可能同拍到达，此时只更新 RAM 不落盘（见 ST_READY 里的 request_dropped）。
// 输出约定：service_ready 表示可以受理请求；load_done/save_done 各是一拍完成脉冲；
//       apply_valid 通知下游"新参数已提交"；error_code 见下面的错误码含义。
//
// 关键机制：
//   1) 开机先做 preflight：读 Flash JEDEC ID 并检查保护位，型号/保护不符就进入
//      ST_ERROR，此时仍允许 RAM 内调参（能看能调），但禁止写 Flash，避免写坏别的区域。
//   2) 双槽 + 版本号 + CRC：load 时比较两槽，取"CRC 正确且版本更新"的那一槽；
//      保存时先擦写另一个槽，写成功后版本号加一，所以新槽写坏也能回退到旧槽。
//   3) 启动时只覆盖音量（RESTORE_VOLUME_ON_BOOT=0 时用默认值），周期和模式照常恢复；
//      保存后的回读校验仍按实际运行值提交，不改变记录格式。
// 错误码：0xE_ 前缀=Flash 预检失败（低 4 位为 preflight 细分码）；
//       0xDE=保存后回读不合法；0xDF=请求被丢弃；0xD1=Flash 里存的字段越界；
//       0xD2=待写入的字段越界被拒绝；0xFF=状态机异常。
module player_config_persistence #(
    parameter integer SPI_CLK_DIV = 4,
    parameter integer STARTUP_CYCLES = 1024,
    parameter integer WAKE_CYCLES = 200,
    parameter integer CS_HIGH_CYCLES = 3,
    parameter integer POLL_INTERVAL_CYCLES = 5000,
    parameter [31:0] ERASE_TIMEOUT_CYCLES = 32'd250000000,
    parameter [31:0] PROGRAM_TIMEOUT_CYCLES = 32'd5000000,
    parameter [31:0] CLKS_PER_MS = 32'd50000,
    parameter [31:0] DEFAULT_PERIOD_MS = 32'd5000,
    parameter [31:0] MIN_PERIOD_MS = 32'd1000,
    parameter [31:0] MAX_PERIOD_MS = 32'd60000,
    parameter [7:0] DEFAULT_VOLUME = 8'd255,
    parameter integer RESTORE_VOLUME_ON_BOOT = 1,
    parameter [7:0] DEFAULT_MODE = 8'd0,
    parameter [23:0] SLOT0_ADDRESS = 24'h7fe000,
    parameter [23:0] SLOT1_ADDRESS = 24'h7ff000,
    parameter [23:0] ALLOWED_BASE = 24'h7fe000,
    parameter [23:0] ALLOWED_LIMIT = 24'h800000
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        cfg_update_valid,
    input  wire [31:0] cfg_period_ms,
    input  wire [7:0]  cfg_volume,
    input  wire [7:0]  cfg_mode,
    input  wire        save_request,
    output reg         service_ready,
    output wire        busy,
    output reg         load_done,
    output reg         save_done,
    output reg         apply_valid,
    output reg         config_rejected,
    output reg         fatal_error,
    output reg  [7:0]  error_code,
    output reg         request_dropped,
    output reg         stored_config_valid,
    output wire [31:0] active_version,
    output reg  [31:0] live_period_ms,
    output reg  [31:0] live_period_cycles,
    output reg  [7:0]  live_volume,
    output reg  [7:0]  live_mode,
    output wire [23:0] jedec_id,
    output wire [7:0]  status1,
    output wire [7:0]  status2,
    output wire [7:0]  status3,
    input  wire        flash_miso,
    output wire        flash_cs_n,
    output wire        flash_sclk,
    output wire        flash_mosi,
    output wire        flash_wp_n,
    output wire        flash_hold_n
);
    // ===== 状态与中间寄存器 =====
    // 主状态机顺序：预检 → 装载 → 应用 → READY；保存时从 READY 进 SAVE_WAIT/SAVE_APPLY。
    // staged_* 是"读回来待提交"的暂存值：先校验再整体提交，避免半个配置生效。
    localparam [3:0] ST_PREFLIGHT_ISSUE = 4'd0;
    localparam [3:0] ST_PREFLIGHT_WAIT  = 4'd1;
    localparam [3:0] ST_LOAD_ISSUE      = 4'd2;
    localparam [3:0] ST_LOAD_WAIT       = 4'd3;
    localparam [3:0] ST_LOAD_APPLY      = 4'd4;
    localparam [3:0] ST_READY           = 4'd5;
    localparam [3:0] ST_SAVE_WAIT       = 4'd6;
    localparam [3:0] ST_SAVE_APPLY      = 4'd7;
    localparam [3:0] ST_ERROR           = 4'd8;

    reg [3:0] state;
    reg [31:0] staged_period_ms;
    reg [7:0] staged_volume;
    reg [7:0] staged_mode;
    reg staged_stored_valid;
    reg staged_rejected;
    reg [7:0] staged_error_code;
    reg preflight_start;
    wire preflight_busy;
    wire preflight_done;
    wire preflight_accepted;
    wire preflight_error;
    wire [3:0] preflight_error_code;
    wire pf_cs_n, pf_sclk, pf_mosi, pf_wp_n, pf_hold_n;
    wire preflight_owner =
        state == ST_PREFLIGHT_ISSUE || state == ST_PREFLIGHT_WAIT;

    reg journal_load_start;
    reg journal_save_start;
    wire journal_rst_n = rst_n && !preflight_owner;
    wire journal_busy;
    wire journal_load_done;
    wire journal_save_done;
    wire journal_error;
    wire [7:0] journal_error_code;
    wire journal_request_dropped;
    wire journal_config_valid;
    wire [31:0] journal_period;
    wire [7:0] journal_volume;
    wire [7:0] journal_mode;
    wire st_cs_n, st_sclk, st_mosi, st_wp_n, st_hold_n;

    initial begin
        if (CLKS_PER_MS < 1 || MIN_PERIOD_MS < 1 ||
            DEFAULT_PERIOD_MS < MIN_PERIOD_MS ||
            DEFAULT_PERIOD_MS > MAX_PERIOD_MS ||
            DEFAULT_MODE[7:1] != 0 ||
            SLOT0_ADDRESS != 24'h7fe000 || SLOT1_ADDRESS != 24'h7ff000 ||
            ALLOWED_BASE != 24'h7fe000 || ALLOWED_LIMIT != 24'h800000) begin
            $display("PLAYER_CONFIG_PERSISTENCE_CONFIG_ERROR invalid production contract");
            $finish;
        end
    end

    // ===== 参数合法性检查与换算 =====
    // config_fields_valid：周期必须在 MIN~MAX 之间，模式只允许 0/1（高 7 位必须为 0）。
    // 越界的值一律不写入 Flash，也不提交给下游，只置错误码。
    function config_fields_valid;
        input [31:0] period_ms;
        input [7:0] mode_value;
        begin
            config_fields_valid = period_ms >= MIN_PERIOD_MS &&
                                  period_ms <= MAX_PERIOD_MS &&
                                  mode_value[7:1] == 0;
        end
    endfunction

    // 周期换算：毫秒 × 每毫秒时钟数。中间乘积用 64 位再截低 32 位，
    // 防止 60s 这种大周期在乘法里溢出。
    function [31:0] period_to_cycles;
        input [31:0] period_ms;
        reg [63:0] product;
        begin
            product = {32'd0,period_ms};
            product = product * CLKS_PER_MS;
            period_to_cycles = product[31:0];
        end
    endfunction

    // 提交配置：四个 live_* 寄存器同时更新，并打一拍 apply_valid 通知下游。
    // 因为是一拍同时更新，下游不会看到"周期已变、模式还是旧的"的中间态。
    task apply_config;
        input [31:0] period_ms;
        input [7:0] volume_value;
        input [7:0] mode_value;
        begin
            live_period_ms <= period_ms;
            live_period_cycles <= period_to_cycles(period_ms);
            live_volume <= volume_value;
            live_mode <= mode_value;
            apply_valid <= 1'b1;
        end
    endtask

    // 进入致命错误：关掉服务就绪、置错误码并停在 ST_ERROR。
    // 注意 ST_ERROR 里仍受理 RAM 调参，只是不再写 Flash。
    task enter_fatal;
        input [7:0] code;
        begin
            service_ready <= 1'b0;
            fatal_error <= 1'b1;
            error_code <= code;
            state <= ST_ERROR;
        end
    endtask

    // ===== 两套 SPI 逻辑共享同一组引脚 =====
    // 预检阶段（preflight_owner）由 preflight 读 JEDEC ID 和状态寄存器；
    // 其余时间由 journal 读写参数槽。因为物理上只有一组 SPI 引脚，
    // 这里用 owner 信号做引脚多路选择，两个子模块都不会同时驱动。
    // 另外 journal_rst_n 在预检期间保持复位，保证它不会误发命令。
    assign busy = state != ST_READY && state != ST_ERROR;
    assign flash_cs_n = preflight_owner ? pf_cs_n : st_cs_n;
    assign flash_sclk = preflight_owner ? pf_sclk : st_sclk;
    assign flash_mosi = preflight_owner ? pf_mosi : st_mosi;
    assign flash_wp_n = preflight_owner ? pf_wp_n : st_wp_n;
    assign flash_hold_n = preflight_owner ? pf_hold_n : st_hold_n;

    // 预检：读 Flash 的 JEDEC ID 与状态/保护寄存器，确认"这片 Flash 能安全写"。
    // EXPECTED_JEDEC_ID=0xEF4017 是 W25Q64 的型号码；不匹配（例如实际是 W25X64）或
    // 保护位不允许写时 accepted=0，主状态机据此进入 ST_ERROR，宁可不动 Flash。
    w25q64_preflight_reader #(
        .SPI_CLK_DIV(SPI_CLK_DIV), .STARTUP_CYCLES(STARTUP_CYCLES),
        .WAKE_CYCLES(WAKE_CYCLES), .CS_HIGH_CYCLES(CS_HIGH_CYCLES),
        .EXPECTED_JEDEC_ID(24'hef4017)
    ) u_preflight (
        .clk(clk), .rst_n(rst_n), .start(preflight_start),
        .flash_miso(flash_miso), .flash_cs_n(pf_cs_n),
        .flash_sclk(pf_sclk), .flash_mosi(pf_mosi),
        .flash_wp_n(pf_wp_n), .flash_hold_n(pf_hold_n),
        .busy(preflight_busy), .done(preflight_done),
        .accepted(preflight_accepted), .error(preflight_error),
        .error_code(preflight_error_code), .jedec_id(jedec_id),
        .status1(status1), .status2(status2), .status3(status3)
    );

    // 参数日志（双槽 + CRC + 版本号）：load 时自己挑可用的槽，
    // save 时写另一个槽并让版本号加一。地址范围由 ALLOWED_BASE/LIMIT 限定，
    // 任何越界访问都会被它自己拒绝，避免误擦配置区以外的内容。
    config_flash_journal #(
        .CLK_DIV(SPI_CLK_DIV), .CS_HIGH_CYCLES(CS_HIGH_CYCLES),
        .POLL_INTERVAL_CYCLES(POLL_INTERVAL_CYCLES),
        .ERASE_TIMEOUT_CYCLES(ERASE_TIMEOUT_CYCLES),
        .PROGRAM_TIMEOUT_CYCLES(PROGRAM_TIMEOUT_CYCLES),
        .SLOT0_ADDRESS(SLOT0_ADDRESS), .SLOT1_ADDRESS(SLOT1_ADDRESS),
        .ALLOWED_BASE(ALLOWED_BASE), .ALLOWED_LIMIT(ALLOWED_LIMIT)
    ) u_journal (
        .clk(clk), .rst_n(journal_rst_n),
        .load_start(journal_load_start), .save_start(journal_save_start),
        .save_period(live_period_ms), .save_volume(live_volume),
        .save_mode(live_mode), .busy(journal_busy),
        .load_done(journal_load_done), .save_done(journal_save_done),
        .error(journal_error), .error_code(journal_error_code),
        .request_dropped(journal_request_dropped),
        .config_valid(journal_config_valid),
        .active_version(active_version), .active_period(journal_period),
        .active_volume(journal_volume), .active_mode(journal_mode),
        .slot0_present_out(), .slot1_present_out(),
        .slot0_raw(), .slot1_raw(), .spi_cs_n(st_cs_n),
        .spi_sclk(st_sclk), .spi_mosi(st_mosi), .spi_miso(flash_miso),
        .spi_wp_n(st_wp_n), .spi_hold_n(st_hold_n)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_PREFLIGHT_ISSUE;
            preflight_start <= 1'b0;
            journal_load_start <= 1'b0;
            journal_save_start <= 1'b0;
            service_ready <= 1'b0;
            load_done <= 1'b0;
            save_done <= 1'b0;
            apply_valid <= 1'b0;
            config_rejected <= 1'b0;
            fatal_error <= 1'b0;
            error_code <= 8'd0;
            request_dropped <= 1'b0;
            stored_config_valid <= 1'b0;
            live_period_ms <= DEFAULT_PERIOD_MS;
            live_period_cycles <= period_to_cycles(DEFAULT_PERIOD_MS);
            live_volume <= DEFAULT_VOLUME;
            live_mode <= DEFAULT_MODE;
            staged_period_ms <= DEFAULT_PERIOD_MS;
            staged_volume <= DEFAULT_VOLUME;
            staged_mode <= DEFAULT_MODE;
            staged_stored_valid <= 1'b0;
            staged_rejected <= 1'b0;
            staged_error_code <= 8'd0;
        end else begin
            preflight_start <= 1'b0;
            journal_load_start <= 1'b0;
            journal_save_start <= 1'b0;
            load_done <= 1'b0;
            save_done <= 1'b0;
            apply_valid <= 1'b0;
            config_rejected <= 1'b0;
            request_dropped <= 1'b0;

            if ((cfg_update_valid || save_request) && state != ST_READY)
                request_dropped <= 1'b1;
            if (journal_request_dropped)
                request_dropped <= 1'b1;

            case (state)
                ST_PREFLIGHT_ISSUE: begin
                    preflight_start <= 1'b1;
                    state <= ST_PREFLIGHT_WAIT;
                end
                ST_PREFLIGHT_WAIT: if (preflight_done) begin
                    if (!preflight_accepted || preflight_error)
                        enter_fatal({4'he,preflight_error_code});
                    else
                        state <= ST_LOAD_ISSUE;
                end
                ST_LOAD_ISSUE: begin
                    journal_load_start <= 1'b1;
                    state <= ST_LOAD_WAIT;
                end
                ST_LOAD_WAIT: if (journal_load_done) begin
                    if (journal_error || journal_request_dropped) begin
                        enter_fatal(journal_request_dropped ? 8'hdf :
                                    journal_error_code);
                    end else begin
                        if (journal_config_valid &&
                            config_fields_valid(journal_period,journal_mode)) begin
                            staged_period_ms <= journal_period;
                            staged_volume <= journal_volume;
                            staged_mode <= journal_mode;
                            staged_stored_valid <= 1'b1;
                            staged_rejected <= 1'b0;
                            staged_error_code <= 8'd0;
                        end else begin
                            staged_period_ms <= DEFAULT_PERIOD_MS;
                            staged_volume <= DEFAULT_VOLUME;
                            staged_mode <= DEFAULT_MODE;
                            staged_stored_valid <= 1'b0;
                            staged_rejected <= journal_config_valid;
                            staged_error_code <= journal_config_valid ? 8'hd1 : 8'd0;
                        end
                        state <= ST_LOAD_APPLY;
                    end
                end
                ST_LOAD_APPLY: begin
                    service_ready <= 1'b1;
                    load_done <= 1'b1;
                    stored_config_valid <= staged_stored_valid;
                    config_rejected <= staged_rejected;
                    error_code <= staged_error_code;
                    // Only startup overrides volume. Save verification must apply
                    // the actual runtime volume without changing the record format.
                    apply_config(staged_period_ms,
                        RESTORE_VOLUME_ON_BOOT ? staged_volume : DEFAULT_VOLUME,
                        staged_mode);
                    state <= ST_READY;
                end
                ST_READY: begin
                    if (cfg_update_valid) begin
                        if (save_request)
                            request_dropped <= 1'b1;
                        if (config_fields_valid(cfg_period_ms,cfg_mode)) begin
                            error_code <= 8'd0;
                            apply_config(cfg_period_ms,cfg_volume,cfg_mode);
                        end else begin
                            config_rejected <= 1'b1;
                            error_code <= 8'hd2;
                        end
                    end else if (save_request) begin
                        service_ready <= 1'b0;
                        journal_save_start <= 1'b1;
                        state <= ST_SAVE_WAIT;
                    end
                end
                ST_SAVE_WAIT: if (journal_save_done) begin
                    if (journal_error || journal_request_dropped ||
                        !journal_config_valid ||
                        !config_fields_valid(journal_period,journal_mode)) begin
                        enter_fatal(journal_request_dropped ? 8'hdf :
                                    journal_error ? journal_error_code : 8'hde);
                    end else begin
                        staged_period_ms <= journal_period;
                        staged_volume <= journal_volume;
                        staged_mode <= journal_mode;
                        state <= ST_SAVE_APPLY;
                    end
                end
                ST_SAVE_APPLY: begin
                    service_ready <= 1'b1;
                    save_done <= 1'b1;
                    stored_config_valid <= 1'b1;
                    error_code <= 8'd0;
                    apply_config(staged_period_ms,staged_volume,staged_mode);
                    state <= ST_READY;
                end
                ST_ERROR: begin
                    // Flash型号/保护检查失败后仍允许RAM参数调节；禁止写操作。
                    service_ready<=1'b0;
                    if(cfg_update_valid && config_fields_valid(cfg_period_ms,cfg_mode))
                        apply_config(cfg_period_ms,cfg_volume,cfg_mode);
                end
                default: enter_fatal(8'hff);
            endcase
        end
    end
endmodule


