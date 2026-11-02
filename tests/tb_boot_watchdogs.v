`timescale 1ns/1ps
module tb_boot_watchdogs;
reg clk=0,rst_n=0;
always #10 clk=~clk;
top #(.SW_DEBOUNCE_CYCLES(100),.UI_CLKS_PER_MS(10)) d(
 .clk(clk),.rst_n(rst_n),.key1(1'b1),.key2(1'b1),.key3(1'b1),
 .sw(4'b0),.uart_rx(1'b1),.sd_miso(1'b1),.flash_miso(1'b1));
task fresh;begin
 @(negedge clk);rst_n=0;repeat(10)@(negedge clk);
 rst_n=1;repeat(160)@(negedge clk);
 force d.diag_local_sys=0;
 force d.init_sys=0;
 force d.ingest_done=0;
 force d.cache_done_sys=0;
 force d.cdc_idle_sys=0;
 force d.recovery_ack=0;
end endtask
task unforce;begin
 release d.boot_state;release d.boot_stage_ms;release d.tick_ms;
 release d.diag_local_sys;release d.init_sys;release d.ingest_done;
 release d.cache_done_sys;release d.cdc_idle_sys;release d.recovery_ack;
end endtask
task check_fault;input [2:0] stage;input [15:0] elapsed;input [7:0] code;begin
 fresh;
 force d.boot_state=stage;force d.boot_stage_ms=elapsed;force d.tick_ms=1;
 repeat(8)@(negedge clk);
 if(!d.boot_fault || d.boot_fault_code!==code || d.first_boot_fault_code!==code ||
    d.system_error!==code || !d.recovery_fallback)
  $fatal(1,"stage %0d elapsed %0d failed fault=%b code=%h first=%h error=%h fallback=%b",
         stage,elapsed,d.boot_fault,d.boot_fault_code,d.first_boot_fault_code,d.system_error,d.recovery_fallback);
 unforce;
end endtask
initial begin
 check_fault(0,3000,8'h8a);
 check_fault(1,30000,8'h8b);
 check_fault(2,100,8'h8c);
 check_fault(3,5000,8'h8d);
 check_fault(7,0,8'h8e);
 fresh;force d.boot_state=4;force d.boot_stage_ms=1000;force d.tick_ms=1;
 repeat(10)@(negedge clk);
 if(d.boot_fault || d.first_boot_fault_code)$fatal(1,"normal playback incorrectly flagged");
 unforce;
 $display("PASS boot watchdogs: four bounded phases, illegal-state first cause, fallback and explicit playback state");$finish;
end
initial begin #1000000;$fatal(1,"watchdog");end
endmodule
