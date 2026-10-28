`timescale 1ns/1ps
module tb_extended_flash;
reg clk=0;always #5 clk=~clk;reg rst=0,update=0,save=0;
reg[31:0]period=10000;reg[7:0]vol=128,mode=1;
wire [7:0] lb,lc,memory;wire unchanged;reg [7:0] brightness=223,contrast=144;
wire ready,ld,sd,fatal;wire[7:0]error,lv,lm;wire[31:0]lp,version;wire cs,sclk,mosi,miso;
player_config_persistence #(.EXTENDED_UI(1),.DEFAULT_VOLUME(0),.RESTORE_VOLUME_ON_BOOT(0),.SPI_CLK_DIV(2),.STARTUP_CYCLES(4),.WAKE_CYCLES(4),.POLL_INTERVAL_CYCLES(4)) dut(
.clk(clk),.rst_n(rst),.cfg_brightness(brightness),.cfg_contrast(contrast),.live_brightness(lb),.live_contrast(lc),.memory_volume(memory),.save_unchanged(unchanged),.cfg_update_valid(update),.cfg_period_ms(period),.cfg_volume(vol),.cfg_mode(mode),.save_request(save),
.service_ready(ready),.load_done(ld),.save_done(sd),.fatal_error(fatal),.error_code(error),.active_version(version),
.live_period_ms(lp),.live_volume(lv),.live_mode(lm),.flash_miso(miso),.flash_cs_n(cs),.flash_sclk(sclk),.flash_mosi(mosi));
spi_flash_model flash(clk,cs,sclk,mosi,miso);
task update_save;begin
@(negedge clk);update=1;@(negedge clk);update=0;repeat(4)@(negedge clk);save=1;@(negedge clk);save=0;
wait(sd ||fatal);if(fatal ||error)$fatal(1,"save error %h",error);repeat(4)@(negedge clk);
end endtask
task reboot;begin @(negedge clk);rst=0;repeat(4)@(negedge clk);rst=1;wait(ld ||fatal);if(fatal)$fatal(1,"load error %h",error);end endtask
reg[79:0] legacy_payload;reg[95:0] legacy_record;reg[15:0] legacy_crc;integer i;
initial begin #12;rst=1;wait(ld||fatal);
if(fatal||lp!=5000||lv!=0||lm!=0||lb!=255||lc!=128||memory!=128)$fatal(1,"default extended");
update_save;reboot;
if(lp!=10000||lv!=0||lm!=0||memory!=128||lb!=223||lc!=144)$fatal(1,"extended restore");
@(negedge clk);save=1;@(negedge clk);save=0;wait(sd);
if(!unchanged || flash.writes!=1)$fatal(1,"unchanged write");repeat(4)@(negedge clk);
period=30000;vol=64;brightness=127;contrast=96;update_save;reboot;
if(lp!=30000||lv!=0||memory!=64||lb!=127||lc!=96)$fatal(1,"second restore");
flash.mem[4096]=flash.mem[4096]^8'h80;reboot;
if(lp!=10000||lv!=0||memory!=128||lb!=223||lc!=144)$fatal(1,"extended CRC fallback");
// Model a partially programmed newer record after erase: old slot survives.
for(i=0;i<4096;i=i+1)flash.mem[4096+i]=255;
for(i=0;i<5;i=i+1)flash.mem[4096+i]=0;reboot;
if(lp!=10000||memory!=128||lb!=223)$fatal(1,"torn write fallback");
// Preload a valid version-7 legacy millisecond record, independently CRC-ed.
rst=0;repeat(4)@(negedge clk);
legacy_payload={32'd7,32'd30000,8'd192,8'd1};legacy_crc=16'hffff;
for(i=79;i>=0;i=i-1)begin
 if(legacy_crc[15]^legacy_payload[i])legacy_crc={legacy_crc[14:0],1'b0}^16'h1021;
 else legacy_crc={legacy_crc[14:0],1'b0};
end
legacy_record={legacy_payload,legacy_crc};
for(i=0;i<8192;i=i+1)flash.mem[i]=255;
for(i=0;i<12;i=i+1)flash.mem[i]=legacy_record[95-i*8 -:8];
rst=1;wait(ld||fatal);
if(fatal||lp!=30000||lv!=0||lm!=0||memory!=192||lb!=255||lc!=128)$fatal(1,"legacy migration");
$display("PASS extended Flash: four fields, boot mute/manual, unchanged no-write, CRC/torn fallback and legacy migration");$finish;end
initial begin #10000000;$fatal(1,"Flash watchdog state%d error%h",dut.state,error);end
endmodule
