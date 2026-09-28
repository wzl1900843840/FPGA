`timescale 1ns/1ps

module media_recovery_fsm #(
    parameter integer MAX_RETRIES = 2
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       error_valid,
    input  wire [7:0] error_code,
    input  wire       retry_complete,
    input  wire       retry_success,
    input  wire       manual_rescan,
    output reg        retry_pulse,
    output reg        skip_pulse,
    output reg        rescan_pulse,
    output reg        preserve_previous_frame,
    output reg [7:0]  sticky_error,
    output reg [3:0]  retry_count,
    output reg [1:0]  state
);
    localparam ST_OK=0, ST_RETRY=1, ST_DEGRADED=2;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            retry_pulse<=0; skip_pulse<=0; rescan_pulse<=0; preserve_previous_frame<=0;
            sticky_error<=0; retry_count<=0; state<=ST_OK;
        end else begin
            retry_pulse<=0; skip_pulse<=0; rescan_pulse<=0;
            case(state)
                ST_OK: begin
                    preserve_previous_frame<=0;
                    if(error_valid) begin
                        sticky_error<=error_code; preserve_previous_frame<=1;
                        retry_count<=1; retry_pulse<=1; state<=ST_RETRY;
                    end
                end
                ST_RETRY: if(retry_complete) begin
                    if(retry_success) begin
                        preserve_previous_frame<=0; state<=ST_OK;
                    end else if(retry_count < MAX_RETRIES) begin
                        retry_count<=retry_count+1'b1; retry_pulse<=1;
                    end else begin
                        skip_pulse<=1; state<=ST_DEGRADED;
                    end
                end
                default: begin
                    preserve_previous_frame<=1;
                    if(manual_rescan) begin
                        rescan_pulse<=1; retry_count<=0; state<=ST_OK;
                    end
                end
            endcase
        end
    end
endmodule
