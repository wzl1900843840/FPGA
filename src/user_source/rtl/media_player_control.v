`timescale 1ns/1ps

module media_player_control #(
    parameter [31:0] DEFAULT_PERIOD_CYCLES = 32'd250000000,
    parameter [31:0] MIN_PERIOD_CYCLES = 32'd50000000,
    parameter [31:0] MAX_PERIOD_CYCLES = 32'd3000000000
) (
    input  wire        sys_clk,
    input  wire        sys_rst_n,
    input  wire        next_event,
    input  wire        previous_event,
    input  wire        select_valid,
    input  wire [2:0]  select_index,
    input  wire        toggle_auto_event,
    input  wire        period_cfg_valid,
    input  wire [31:0] period_cfg_cycles,
    input  wire        auto_cfg_valid,
    input  wire        auto_cfg_enabled,
    input  wire [4:0]  image_complete,
    output reg         auto_enabled,
    output reg  [31:0] active_period_cycles,
    output reg  [2:0]  pending_index,
    output reg  [7:0]  control_error,
    output wire        request_busy,
    input  wire        pix_clk,
    input  wire        pix_rst_n,
    input  wire        frame_start,
    input  wire        emergency_active,
    input  wire [2:0]  emergency_index,
    output reg  [2:0]  active_index,
    output reg         index_commit
);
    localparam ERR_NONE = 8'h00;
    localparam ERR_PERIOD_RANGE = 8'h51;
    localparam ERR_REQUEST_BUSY = 8'h52;
    localparam ERR_NO_RESOURCE = 8'h53;

    reg [31:0] auto_counter;
    reg [2:0] sys_current_index;
    reg [2:0] normal_index;
    reg emergency_seen;
    reg request_toggle;
    reg ack_toggle_pix;
    reg ack_sync1, ack_sync2;
    reg [2:0] index_sync1, index_sync2;
    reg req_sync1, req_sync2;
    reg req_seen_pix;
    reg [2:0] requested_index_pix;
    reg commit_pending_pix;
    reg emergency_pix1, emergency_pix2;
    reg emergency_seen_pix;
    reg [2:0] normal_index_pix;
    reg [4:0] complete_pix1, complete_pix2;
    reg [2:0] active_sys1, active_sys2;
    reg restore_pending;
    reg [3:0] restore_target;
    integer restore_scan;
    reg [3:0] restore_target_pix;
    integer pix_restore_scan;
    always @* begin
        restore_target_pix = 0;
        for (pix_restore_scan=0; pix_restore_scan<4; pix_restore_scan=pix_restore_scan+1)
            if (!restore_target_pix[3] && complete_pix2[pix_restore_scan])
                restore_target_pix = {1'b1,pix_restore_scan[2:0]};
        if (normal_index_pix<4 && complete_pix2[normal_index_pix])
            restore_target_pix = {1'b1,normal_index_pix};
    end
    always @* begin
        restore_target = 0;
        for (restore_scan=0; restore_scan<4; restore_scan=restore_scan+1)
            if (!restore_target[3] && image_complete[restore_scan])
                restore_target = {1'b1,restore_scan[2:0]};
        if (normal_index<4 && image_complete[normal_index])
            restore_target = {1'b1,normal_index};
    end

    assign request_busy = request_toggle != ack_sync2;

    function [3:0] next_available;
        input [2:0] current;
        input [4:0] complete;
        integer step;
        integer candidate_int;
        reg [2:0] candidate;
        begin
            next_available = 4'd0;
            // PIC5 is reserved for the emergency page.  Normal manual and
            // automatic rotation must wrap across the four daily banks only;
            // the emergency branch below is the sole path that may request
            // bank 4.
            for (step = 1; step <= 4; step = step + 1) begin
                if (previous_event) begin
                    candidate_int = current[1:0] - step;
                    if (candidate_int < 0) candidate_int = candidate_int + 4;
                end else begin
                    candidate_int = current[1:0] + step;
                    if (candidate_int >= 4) candidate_int = candidate_int - 4;
                end
                candidate = candidate_int[2:0];
                if (!next_available[3] && complete[candidate])
                    next_available = {1'b1, candidate};
            end
        end
    endfunction

    task issue_next_request;
        reg [3:0] selected;
        begin
            selected = next_available(sys_current_index, image_complete);
            if (request_busy) begin
                control_error <= ERR_REQUEST_BUSY;
            end else if (!selected[3]) begin
                control_error <= ERR_NO_RESOURCE;
            end else begin
                pending_index <= selected[2:0];
                request_toggle <= ~request_toggle;
                auto_counter <= 32'd0;
            end
        end
    endtask

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            auto_enabled <= 1'b0;
            active_period_cycles <= DEFAULT_PERIOD_CYCLES;
            pending_index <= 3'd0;
            control_error <= ERR_NONE;
            auto_counter <= 32'd0;
            sys_current_index <= 3'd0;
            normal_index <= 3'd0;
            emergency_seen <= 1'b0;
            request_toggle <= 1'b0;
            ack_sync1 <= 1'b0;
            ack_sync2 <= 1'b0;
            active_sys1 <= 0; active_sys2 <= 0; restore_pending <= 0;
        end else begin
            active_sys1 <= active_index; active_sys2 <= active_sys1;
            ack_sync1 <= ack_toggle_pix;
            ack_sync2 <= ack_sync1;
            if (!request_busy)
                sys_current_index <= pending_index;

            if (period_cfg_valid) begin
                if (period_cfg_cycles < MIN_PERIOD_CYCLES ||
                    period_cfg_cycles > MAX_PERIOD_CYCLES) begin
                    control_error <= ERR_PERIOD_RANGE;
                end else begin
                    active_period_cycles <= period_cfg_cycles;
                    auto_counter <= 32'd0;
                end
            end

            if (auto_cfg_valid && !emergency_active && !emergency_seen && !restore_pending) begin
                auto_enabled <= auto_cfg_enabled;
                auto_counter <= 32'd0;
            end

            if (toggle_auto_event && !emergency_active && !emergency_seen && !restore_pending) begin
                auto_enabled <= ~auto_enabled;
                auto_counter <= 32'd0;
            end

            // Emergency pages have priority over both manual and automatic media
            // changes.  Save the normal page once, request PIC5 at the next
            // frame boundary, then restore the saved page when the alarm clears.
            if (emergency_active) begin
                auto_counter <= 32'd0;
                if (!emergency_seen) begin
                    emergency_seen <= 1'b1;
                    normal_index <= active_sys2 < 4 ? active_sys2 : normal_index;
                    restore_pending <= 1'b0;
                end
                // Level request persists across busy handshakes and late PIC5.
                if (!request_busy && image_complete[emergency_index] &&
                    pending_index != emergency_index) begin
                    pending_index <= emergency_index;
                    request_toggle <= ~request_toggle;
                end
            end else if (emergency_seen || restore_pending) begin
                emergency_seen <= 1'b0;
                restore_pending <= 1'b1;
                auto_counter <= 32'd0;
                if (!request_busy && restore_target[3]) begin
                    pending_index <= restore_target[2:0];
                    request_toggle <= ~request_toggle;
                    restore_pending <= 1'b0;
                end
            end else if (select_valid && !request_busy && image_complete[select_index]) begin
                pending_index <= select_index;
                request_toggle <= ~request_toggle;
                auto_counter <= 0;
            end else if (!request_busy && image_complete!=0 && !image_complete[sys_current_index]) begin
                // PIC1缺失或损坏时，从已经完整加载的bank启动。
                issue_next_request();
            end else if (next_event || previous_event) begin
                issue_next_request();
            end else if (period_cfg_valid || auto_cfg_valid || toggle_auto_event) begin
                auto_counter <= 0;
            end else if (auto_enabled) begin
                if (request_busy)
                    auto_counter <= 32'd0;
                else if (auto_counter >= active_period_cycles - 1'b1)
                    issue_next_request();
                else
                    auto_counter <= auto_counter + 1'b1;
            end else begin
                auto_counter <= 32'd0;
            end
        end
    end

    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            index_sync1 <= 3'd0;
            index_sync2 <= 3'd0;
            req_sync1 <= 1'b0;
            req_sync2 <= 1'b0;
            req_seen_pix <= 1'b0;
            requested_index_pix <= 3'd0;
            commit_pending_pix <= 1'b0;
            active_index <= 3'd0;
            index_commit <= 1'b0;
            ack_toggle_pix <= 1'b0;
            emergency_pix1 <= 0; emergency_pix2 <= 0;
            emergency_seen_pix <= 0; normal_index_pix <= 0;
            complete_pix1 <= 0; complete_pix2 <= 0;
        end else begin
            emergency_pix1 <= emergency_active; emergency_pix2 <= emergency_pix1;
            complete_pix1 <= image_complete; complete_pix2 <= complete_pix1;
            index_sync1 <= pending_index;
            index_sync2 <= index_sync1;
            req_sync1 <= request_toggle;
            req_sync2 <= req_sync1;
            index_commit <= 1'b0;

            if (req_sync2 != req_seen_pix && !commit_pending_pix) begin
                req_seen_pix <= req_sync2;
                requested_index_pix <= index_sync2;
                commit_pending_pix <= 1'b1;
            end

            if (frame_start && emergency_pix2) begin
                if (!emergency_seen_pix) begin
                    emergency_seen_pix <= 1;
                    if (active_index<4) normal_index_pix <= active_index;
                end
                if (complete_pix2[emergency_index] && active_index != emergency_index) begin
                    active_index <= emergency_index; index_commit <= 1'b1;
                end
                if (commit_pending_pix) begin
                    commit_pending_pix <= 1'b0; ack_toggle_pix <= req_seen_pix;
                end
            end else if (frame_start && emergency_seen_pix) begin
                // Recovery uses the visible-page snapshot in this domain;
                // an obsolete handshake cannot add extra frame boundaries.
                if (restore_target_pix[3]) begin
                    active_index <= restore_target_pix[2:0]; index_commit <= 1;
                end
                emergency_seen_pix <= 0;
                if (commit_pending_pix) begin
                    commit_pending_pix <= 0; ack_toggle_pix <= req_seen_pix;
                end
            end else if (frame_start && commit_pending_pix) begin
                // A request already in flight cannot bring PIC5 back after clear.
                if (requested_index_pix < 4 && requested_index_pix != active_index) begin
                    active_index <= requested_index_pix; index_commit <= 1'b1;
                end
                commit_pending_pix <= 1'b0;
                ack_toggle_pix <= req_seen_pix;
            end
        end
    end
endmodule
