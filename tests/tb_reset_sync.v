`timescale 1ns/1ps
module tb_reset_sync;
reg clk=0,ext=0;
always #20 clk=~clk;
wire rising_reset,falling_reset;
reset_sync a(.clk(clk),.ext_rst_n(ext),.rst_n_sync(rising_reset));
reset_sync #(.RELEASE_ON_FALLING_EDGE(1)) b(.clk(clk),.ext_rst_n(ext),.rst_n_sync(falling_reset));
integer rising_count=0,falling_count=0;
always @(posedge clk) if(ext) rising_count=rising_count+1; else rising_count=0;
always @(negedge clk) if(ext) falling_count=falling_count+1; else falling_count=0;
always @(posedge rising_reset) begin
 if(clk!==1 || rising_count<2) $fatal(1,"rising release is not second domain edge");
end
always @(posedge falling_reset) begin
 if(clk!==0 || falling_count<2) $fatal(1,"falling release is not second domain edge");
end
integer n;
initial begin
 #1;ext=1;#1;ext=0;#1;
 for(n=0;n<5;n=n+1) begin
  rising_count=0;falling_count=0;
  #(7+n);ext=1;
  wait(rising_reset && falling_reset);
  #13;ext=0;#1;
  if(rising_reset!==0 || falling_reset!==0) $fatal(1,"assertion not asynchronous");
  #67;
 end
 $display("PASS reset_sync: async assertion, two-edge rising/falling release across five phases");$finish;
end
initial begin #3000;$fatal(1,"timeout");end
endmodule
