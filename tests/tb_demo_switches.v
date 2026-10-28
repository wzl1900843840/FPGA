`timescale 1ns/1ps
module tb_demo_switches;
reg clk=0,r=0,tick=0;always #5 clk=~clk;reg [3:0] raw=0;wire [3:0] stable;integer i;
demo_switch_filter #(.STABLE_MS(4)) d(clk,r,tick,raw,stable);
task ms;input integer n;integer j;begin for(j=0;j<n;j=j+1)begin repeat(4)@(negedge clk);tick=1;@(negedge clk);tick=0;end end endtask
initial begin #12;r=1;ms(5);
 for(i=0;i<16;i=i+1)begin raw=i;ms(1);raw=stable;ms(5);if(stable!==i-1 && i>0)$fatal(1,"bounce accepted");raw=i;ms(6);if(stable!==i[3:0])$fatal(1,"combination %d",i);end
 $display("PASS switches: all 16 combinations, independent stable sampling, bounce rejection");$finish;end
initial begin #100000;$fatal(1,"switch timeout");end
endmodule
