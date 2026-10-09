`timescale 1ns/1ps

// One complete 128-word transaction owns the vendor interface until its
// returns/drain finish. The display wins below its FIFO watermark; background
// writes and thumbnail work use the buffered display's spare bandwidth.
module media_sdram_arbiter #(
    parameter integer BURST_SIZE = 128,
    parameter integer DRAIN_CYCLES = 16
) (
    input wire clk, rst_n,
    input wire controller_busy, refresh_active,
    input wire video_request, video_urgent,
    input wire write_request, cache_request, cache_write,
    input wire app_read, app_write, rd_valid,
    output wire video_grant, write_grant, cache_grant,
    output wire [1:0] owner,
    output wire video_return, cache_return,
    output wire write_drained
);
    localparam NONE=2'd0, VIDEO=2'd1, WRITE=2'd2, CACHE=2'd3;
    reg [1:0] active_owner;
    reg active_write, retiring;
    reg [$clog2(BURST_SIZE)-1:0] commands, returns;
    reg [$clog2(DRAIN_CYCLES+1)-1:0] drain;
    reg [1:0] selected;
    always @* begin
        selected=NONE;
        if(active_owner==NONE && !controller_busy && !refresh_active) begin
            if(video_request && (video_urgent || (!write_request && !cache_request)))
                selected=VIDEO;
            else if(write_request) selected=WRITE;
            else if(cache_request) selected=CACHE;
            else if(video_request) selected=VIDEO;
        end
    end
    assign owner=active_owner==NONE ? selected : active_owner;
    assign video_grant=selected==VIDEO;
    assign write_grant=selected==WRITE;
    assign cache_grant=selected==CACHE;
    assign video_return=active_owner==VIDEO && !retiring;
    assign cache_return=active_owner==CACHE && !active_write && !retiring;
    assign write_drained=active_owner!=WRITE && selected!=WRITE;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            active_owner<=NONE;active_write<=0;retiring<=0;
            commands<=0;returns<=0;drain<=0;
        end else if(active_owner==NONE) begin
            if(selected!=NONE) begin
                active_owner<=selected;
                active_write<=selected==WRITE || (selected==CACHE && cache_write);
                // The CDC client presents its first word on the grant edge.
                commands<=app_write ? 1 : 0;
                returns<=0;retiring<=0;drain<=0;
            end
        end else if(retiring) begin
            if(controller_busy || refresh_active) drain<=0;
            else if(drain==DRAIN_CYCLES-1) begin
                active_owner<=NONE;retiring<=0;drain<=0;
            end else drain<=drain+1'b1;
        end else if(active_write) begin
            if(app_write) begin
                commands<=commands+1'b1;
                if(commands==BURST_SIZE-1) begin retiring<=1;drain<=0;end
            end
        end else begin
            if(app_read) commands<=commands+1'b1;
            if(rd_valid) begin
                returns<=returns+1'b1;
                if(returns==BURST_SIZE-1) begin retiring<=1;drain<=0;end
            end
        end
    end
endmodule
