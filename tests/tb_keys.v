`timescale 1ns/1ps
module tb_keys;
reg clk=0,rst=0,k2=1,k3=1,k4=1;always #5 clk=~clk;
wire n,a,p,save,update,menu;wire[31:0]period;wire[7:0]volume;wire[1:0]kind;wire[3:0]level;
reg[31:0]live_period=5000;reg[7:0]live_volume=255;
dual_key_chord_router #(.DEBOUNCE_CYCLES(3),.HOLD_CYCLES(20),.KEY3_LONG_CYCLES(12)) d(
.clk(clk),.rst_n(rst),.save_enabled(1'b1),.key2_n(k2),.key3_n(k3),.key2_event(n),.key3_event(a),.key3_long_event(p),.save_event(save));
param_menu_controller #(.CLKS_PER_MS(2),.DEBOUNCE_MS(2),.LONG_HOLD_MS(20)) m(
.clk(clk),.rst_n(rst),.key4_n(k4),.service_ready(1'b1),.live_volume(live_volume),.live_period_ms(live_period),
.cfg_update_valid(update),.cfg_period_ms(period),.cfg_volume(volume),.menu_event(menu),.menu_kind(kind),.menu_level(level));
integer nn=0,aa=0,pp=0,ss=0,mm=0;
always @(posedge clk)begin
if(n)nn=nn+1;if(a)aa=aa+1;if(p)pp=pp+1;if(save)ss=ss+1;
if(update)begin live_period<=period;live_volume<=volume;mm=mm+1;end
end
task waitc;input integer count;begin repeat(count)@(negedge clk);end endtask
initial begin
#21;rst=1;waitc(20);k2=0;waitc(1);k2=1;waitc(20);if(nn)$fatal(1,"bounce");
k2=0;waitc(10);k2=1;waitc(15);if(nn!=1)$fatal(1,"next");
k3=0;waitc(10);k3=1;waitc(15);if(aa!=1||pp)$fatal(1,"auto short");
k3=0;waitc(40);k3=1;waitc(15);if(pp!=1||aa!=1)$fatal(1,"previous long");
k2=0;k3=0;waitc(90);if(ss!=1)$fatal(1,"chord once %d",ss);k2=1;k3=1;waitc(20);
if(nn!=1||aa!=1||pp!=1)$fatal(1,"chord leaked click");
k4=0;waitc(15);k4=1;waitc(15);if(live_volume!=0||live_period!=5000||mm!=1)$fatal(1,"volume menu");
k4=0;waitc(80);k4=1;waitc(15);if(live_period!=10000||mm!=2)$fatal(1,"period menu");
$display("PASS keys: debounce, next, short/long discrimination, one-shot chord save, volume and period menu");$finish;
end
endmodule
