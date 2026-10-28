`timescale 1ns/1ps
module tb_fix_repeat_save;
reg clk=0,rst=0,k2=1,k3=1;always #10 clk=~clk;
wire save,locked;integer count=0;
dual_key_chord_router #(.DEBOUNCE_CYCLES(3),.HOLD_CYCLES(20),.KEY3_LONG_CYCLES(12)) dut(
 .clk(clk),.rst_n(rst),.save_enabled(1'b1),.key2_n(k2),.key3_n(k3),
 .key2_event(),.key3_event(),.key3_long_event(),.save_event(save),.save_locked(locked),
 .key2_stable_n(),.key3_stable_n());
always @(posedge clk)if(save)count=count+1;
task waitc;input integer n;begin repeat(n)@(negedge clk);end endtask
initial begin
 #43;rst=1;waitc(20);k2=0;k3=0;waitc(60);k2=1;k3=1;waitc(30);
 k2=0;k3=0;waitc(60);k2=1;k3=1;waitc(30);
 if(count==2 && !locked) $display("PASS repeat-save rearmed: two full chord presses, save_count=%0d locked=%0d",count,locked);
 else $fatal(1,"repeat-save hazard not reproduced count=%0d locked=%0d",count,locked);
 $finish;
end
endmodule
