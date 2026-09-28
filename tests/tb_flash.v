`timescale 1ns/1ps
module tb_flash;
reg clk=0;always #5 clk=~clk;reg rst=0,update=0,save=0;
reg[31:0]period=10000;reg[7:0]vol=128,mode=1;
wire ready,ld,sd,fatal;wire[7:0]error,lv,lm;wire[31:0]lp,version;wire cs,sclk,mosi,miso;
player_config_persistence #(.SPI_CLK_DIV(2),.STARTUP_CYCLES(4),.WAKE_CYCLES(4),.POLL_INTERVAL_CYCLES(4)) dut(
.clk(clk),.rst_n(rst),.cfg_update_valid(update),.cfg_period_ms(period),.cfg_volume(vol),.cfg_mode(mode),.save_request(save),
.service_ready(ready),.load_done(ld),.save_done(sd),.fatal_error(fatal),.error_code(error),.active_version(version),
.live_period_ms(lp),.live_volume(lv),.live_mode(lm),.flash_miso(miso),.flash_cs_n(cs),.flash_sclk(sclk),.flash_mosi(mosi));
spi_flash_model flash(clk,cs,sclk,mosi,miso);
task update_save;begin
@(negedge clk);update=1;@(negedge clk);update=0;repeat(4)@(negedge clk);save=1;@(negedge clk);save=0;
wait(sd ||fatal);if(fatal ||error)$fatal(1,"save error %h",error);repeat(4)@(negedge clk);
end endtask
task reboot;begin @(negedge clk);rst=0;repeat(4)@(negedge clk);rst=1;wait(ld ||fatal);if(fatal)$fatal(1,"load error %h",error);end endtask
initial begin #12;rst=1;wait(ld||fatal);if(fatal||lp!=5000||lv!=255||lm!=0)$fatal(1,"default load %h",error);
update_save;reboot;if(lp!=10000||lv!=128||lm!=1)$fatal(1,"restore config");
period=30000;vol=64;mode=0;update_save;reboot;if(lp!=30000||lv!=64||lm!=0)$fatal(1,"second restore");
// Last write occupies slot1; a torn/corrupt record must fall back to slot0.
flash.mem[4096]=flash.mem[4096]^8'h80;reboot;
if(lp!=10000||lv!=128||lm!=1)$fatal(1,"CRC fallback lp%d lv%d lm%d",lp,lv,lm);
$display("PASS Flash: W25X64 SPI ID, default load, dual-slot save/readback, reboot restore, corrupt-slot fallback");$finish;end
initial begin #10000000;$fatal(1,"Flash watchdog state%d error%h",dut.state,error);end
endmodule
