`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// 电梯宣传屏演示状态机。
//
// 这是一个显示域控制器，不连接电梯安全回路，也不向电梯控制器发送运行命令。
// UART/拨码告警在系统域整理成 alert_request 后，状态只在帧边界改变：
// STARTUP -> NORMAL -> ALERT -> RECOVERY -> NORMAL。
// ALERT 期间播放器会锁住普通轮播并请求 PIC5；PIC5 尚未完成时输出
// alert_fallback，顶层可用逻辑图案维持可见告警页。
// -----------------------------------------------------------------------------
module elevator_demo_controller (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       frame_start,
    input  wire       startup_ready,
    input  wire       media_fault,
    input  wire       alert_request,
    input  wire       alert_page_available,
    output wire       alert_active,
    output wire       alert_fallback,
    output wire [2:0] alert_page_index,
    output reg  [2:0] state_code
);
    localparam ST_STARTUP  = 3'd0;
    localparam ST_NORMAL   = 3'd1;
    localparam ST_ALERT    = 3'd2;
    localparam ST_RECOVERY = 3'd3;
    localparam ST_FAULT    = 3'd4;

    assign alert_active = state_code == ST_ALERT;
    assign alert_fallback = alert_active && !alert_page_available;
    assign alert_page_index = 3'd4;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_code <= ST_STARTUP;
        end else if (frame_start) begin
            if (media_fault) begin
                state_code <= ST_FAULT;
            end else begin
                case (state_code)
                    ST_STARTUP: begin
                        if (alert_request) state_code <= ST_ALERT;
                        else if (startup_ready) state_code <= ST_NORMAL;
                    end
                    ST_NORMAL: begin
                        if (alert_request) state_code <= ST_ALERT;
                    end
                    ST_ALERT: begin
                        if (!alert_request) state_code <= ST_RECOVERY;
                    end
                    ST_RECOVERY: begin
                        if (alert_request) state_code <= ST_ALERT;
                        else if (startup_ready) state_code <= ST_NORMAL;
                        else state_code <= ST_STARTUP;
                    end
                    default: begin
                        if (alert_request) state_code <= ST_ALERT;
                        else if (startup_ready) state_code <= ST_NORMAL;
                        else state_code <= ST_STARTUP;
                    end
                endcase
            end
        end
    end
endmodule
