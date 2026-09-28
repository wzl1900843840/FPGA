`timescale 1ns/1ps
module tb_sd_delay;
reg clk=0;always #1 clk=~clk;reg rst=0,start=0;wire cs,sclk,mosi,busy,done,ready;
sd_spi_init #(.STARTUP_DELAY_CYCLES(5000000),.SPI_CLK_DIV(64)) dut(.clk(clk),.rst_n(rst),.init_start(start),.init_busy(busy),.init_done(done),.init_ready(ready),.sd_cs_n(cs),.sd_sclk(sclk),.sd_mosi(mosi),.sd_miso(1'b1));
integer n;initial begin #4;rst=1;@(negedge clk);start=1;@(negedge clk);start=0;
for(n=0;n<5000000;n=n+1) begin @(negedge clk);if(!cs ||sclk)$fatal(1,"early SD clock %d",n);end
wait(sclk);$display("PASS SD: real 5000000-cycle startup delay reaches SPI clocks");$finish;end
initial begin #10100000;$fatal(1,"startup counter stuck");end
endmodule
