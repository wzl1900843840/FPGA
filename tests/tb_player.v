`timescale 1ns/1ps

module tb_player;
    reg sys_clk = 0, pix_clk = 0;
    always #5 sys_clk = ~sys_clk;
    always #7 pix_clk = ~pix_clk;

    reg sys_rst_n = 0, pix_rst_n = 0;
    reg next_event = 0, previous_event = 0;
    reg select_valid = 0;
    reg [2:0] select_index = 0;
    reg toggle_auto_event = 0;
    reg period_cfg_valid = 0;
    reg [31:0] period_cfg_cycles = 0;
    reg auto_cfg_valid = 0, auto_cfg_enabled = 0;
    reg [4:0] image_complete = 5'b11111;
    reg frame_start = 0;
    reg emergency_active = 0;
    reg [2:0] emergency_index = 3'd4;
    reg normal_phase = 1;
    wire auto_enabled, request_busy, index_commit;
    wire [31:0] active_period_cycles;
    wire [2:0] pending_index, active_index;
    wire [7:0] control_error;
    integer pix_div = 0;

    always @(posedge pix_clk) begin
        if (!pix_rst_n) begin
            pix_div <= 0;
            frame_start <= 0;
        end else begin
            frame_start <= 0;
            if (pix_div == 3) begin
                pix_div <= 0;
                frame_start <= 1;
            end else begin
                pix_div <= pix_div + 1;
            end
        end
    end

    media_player_control #(
        .DEFAULT_PERIOD_CYCLES(5), .MIN_PERIOD_CYCLES(1), .MAX_PERIOD_CYCLES(100)
    ) dut (
        .sys_clk(sys_clk), .sys_rst_n(sys_rst_n), .next_event(next_event),
        .previous_event(previous_event), .select_valid(select_valid),
        .select_index(select_index), .toggle_auto_event(toggle_auto_event),
        .period_cfg_valid(period_cfg_valid), .period_cfg_cycles(period_cfg_cycles),
        .auto_cfg_valid(auto_cfg_valid), .auto_cfg_enabled(auto_cfg_enabled),
        .image_complete(image_complete), .auto_enabled(auto_enabled),
        .active_period_cycles(active_period_cycles), .pending_index(pending_index),
        .control_error(control_error), .request_busy(request_busy),
        .pix_clk(pix_clk), .pix_rst_n(pix_rst_n), .frame_start(frame_start),
        .emergency_active(emergency_active), .emergency_index(emergency_index),
        .active_index(active_index), .index_commit(index_commit)
    );

    task wait_request;
        begin
            wait (request_busy);
            wait (!request_busy);
            repeat (2) @(posedge pix_clk);
        end
    endtask

    task next_and_expect;
        input [2:0] expected;
        begin
            @(posedge sys_clk); next_event = 1;
            @(posedge sys_clk); next_event = 0;
            wait_request();
            if (active_index !== expected)
                $fatal(1, "normal rotation selected %0d, expected %0d", active_index, expected);
        end
    endtask

    always @(posedge pix_clk)
        if (pix_rst_n && normal_phase && active_index === 3'd4)
            $fatal(1, "PIC5 leaked into normal rotation");

    initial begin
        #31; sys_rst_n = 1; pix_rst_n = 1;
        repeat (4) @(posedge sys_clk);

        next_and_expect(3'd1);
        next_and_expect(3'd2);
        next_and_expect(3'd3);
        next_and_expect(3'd0);

        auto_cfg_enabled = 1; auto_cfg_valid = 1;
        @(posedge sys_clk); auto_cfg_valid = 0;
        repeat (120) @(posedge sys_clk);

        normal_phase = 0;
        emergency_active = 1;
        wait_request();
        if (active_index !== 3'd4)
            $fatal(1, "alert did not select PIC5, got %0d", active_index);
        emergency_active = 0;
        wait_request();
        if (active_index === 3'd4)
            $fatal(1, "alert recovery left PIC5 active");
        normal_phase = 1;
        $display("PASS player: normal rotation is PIC1..PIC4; alert selects and recovers PIC5");
        $finish;
    end

    initial begin
        #100000; $fatal(1, "watchdog");
    end
endmodule
