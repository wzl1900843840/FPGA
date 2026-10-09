`timescale 1ns/1ps
module tb_sd_protocol;
`ifdef FAST_SD
localparam CLOCK_HALF=10,INIT_DIV=64;
`else
localparam CLOCK_HALF=5,INIT_DIV=2;
`endif
reg clk=0;always #CLOCK_HALF clk=~clk;reg rst=0,start=0,req=0,bad=0;
wire done,ready,hc,busy,rdone,valid,cs,sclk,mosi,miso;wire[7:0]err,rerr,b;wire[8:0]idx;
sd_media_service #(.SPI_CLK_DIV(2),.INIT_SPI_CLK_DIV(INIT_DIV),.INIT_STARTUP_DELAY_CYCLES(8)) dut(.clk(clk),.rst_n(rst),.init_start(start),.init_done(done),.init_ready(ready),.init_error(err),.card_high_capacity(hc),
.sector_req(req),.sector_lba(32'd1234),.sector_busy(busy),.sector_done(rdone),.sector_valid(valid),.sector_byte(b),.sector_byte_index(idx),.sector_error(rerr),.sd_cs_n(cs),.sd_sclk(sclk),.sd_mosi(mosi),.sd_miso(miso));
spi_sd_model card(cs,sclk,mosi,bad,miso);
integer bytes=0;
`ifdef FAST_SD
time rise_at;integer slow_edges=0,fast_edges=0;
always @(posedge sclk)rise_at=$time;
always @(negedge sclk)if(rst)begin
 if(ready)begin
  if($time-rise_at!=40)$fatal(1,"SD read high pulse is not 40 ns");
  fast_edges=fast_edges+1;
 end else begin
  if($time-rise_at!=1280)$fatal(1,"SD initialization high pulse is not 1280 ns");
  slow_edges=slow_edges+1;
 end
end
`endif
always @(posedge clk)if(valid)begin if(idx!==bytes ||b!==(bytes&255))$fatal(1,"SD payload/order");bytes=bytes+1;end
task read_sector;begin @(negedge clk);req=1;@(negedge clk);req=0;wait(rdone);@(negedge clk);end endtask
initial begin #12;rst=1;@(negedge clk);start=1;@(negedge clk);start=0;wait(done);#1;
if(err||!ready||!hc)$fatal(1,"SD init %h",err);
read_sector;if(rerr||bytes!=512)$fatal(1,"SD read %h count%d",rerr,bytes);
bytes=0;bad=1;read_sector;if(rerr==0)$fatal(1,"bad CRC accepted");
`ifdef FAST_SD
if(slow_edges<80 || fast_edges<8192)$fatal(1,"SD speed coverage");
$display("PASS SD fast clocks: 390.625 kHz initialization, 12.5 MHz read, CRC and 512-byte payload");
`endif
$display("PASS SD SPI: CMD0/8/55/41/58, SDHC CMD17 address, all 512 bytes, CRC fault");$finish;end
initial begin #8000000;$fatal(1,"SD watchdog init%h read%h",err,rerr);end
endmodule
