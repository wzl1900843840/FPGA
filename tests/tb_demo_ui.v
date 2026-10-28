`timescale 1ns/1ps
module tb_demo_ui;
reg clk=0,rst=0;always #5 clk=~clk;
reg [2:0] keys=7;reg [3:0] sw=0;
reg alarm=0,view=0,busy=0,cbusy=0,fb=0;
reg media_ready=1,unchanged=0,saved=0;
reg [7:0] b=255,c=128,v=0;reg [31:0] period=5000;
wire update,save,reload,valid,auto_mode,tick,confirm,dirty;
wire [7:0] nb,nc,nv;wire [31:0] np;wire [2:0] cmd,field;wire [1:0] diag;wire [3:0] feedback;
integer commands=0,saves=0,reloads=0,updates=0;reg [2:0] last;
demo_ui_controller #(.CLKS_PER_MS(2),.DEBOUNCE_MS(2),.LONG_MS(12),.SAVE_MS(30)) d(
 .clk(clk),.rst_n(rst),.keys_n(keys),.switches(sw),.alert_active(alarm),.view_mode(view),
 .apply_busy(busy),.command_busy(cbusy),.transition_busy(1'b0),.cfg_busy(fb),.cfg_ready(1'b1),
 .cfg_fatal(1'b0),.load_done(1'b0),.save_done(saved),.save_unchanged(unchanged),.media_ready(media_ready),.live_brightness(b),.live_contrast(c),
 .live_volume(v),.memory_volume(8'd192),.live_period_ms(period),.cache_ready(1'b1),.reload_busy(1'b0),
 .cfg_update(update),.cfg_brightness(nb),.cfg_contrast(nc),.cfg_volume(nv),.cfg_period_ms(np),
 .save_request(save),.reload_request(reload),.command_valid(valid),.command(cmd),.auto_mode(auto_mode),
 .field(field),.diag_page(diag),.reload_confirm(confirm),.feedback(feedback),.dirty(dirty),.tick_ms(tick));
always @(negedge clk)begin
 if(valid)begin commands=commands+1;last=cmd;end
 if(save)saves=saves+1;if(reload)reloads=reloads+1;
 if(update)begin updates=updates+1;b=nb;c=nc;v=nv;period=np;end
end
task ms;input integer n;begin repeat(n*2)@(negedge clk);end endtask
task press;input [2:0] k;input integer n;begin keys=k;ms(n);keys=7;ms(7);end endtask
integer before_count,i;
initial begin
 #12;rst=1;ms(10);
 press(6,5);if(commands!=1 || last!=1)$fatal(1,"next short");
 press(5,5);if(!auto_mode)$fatal(1,"auto short");
 press(5,18);if(last!=3 || !auto_mode)$fatal(1,"previous long emitted short");
 press(3,5);if(v!=192)$fatal(1,"unmute remembered volume");
 press(3,5);if(v!=0)$fatal(1,"mute");
 press(3,18);if(last!=4)$fatal(1,"thumbnail long");
 view=1;ms(10);press(5,5);if(last!=2)$fatal(1,"thumbnail left");
 press(3,5);if(last!=5)$fatal(1,"thumbnail confirm");
 view=0;sw=2;ms(10);if(field!=0)$fatal(1,"menu initial focus");
 press(5,5);if(b!=239)$fatal(1,"brightness down");
 press(3,5);if(field!=1)$fatal(1,"focus contrast");press(6,5);if(c!=144)$fatal(1,"contrast up");
 press(3,5);press(6,5);if(v!=64)$fatal(1,"volume step");
 press(3,5);press(5,5);if(period!=2000)$fatal(1,"period down");
 press(3,18);if(period!=5000 || v!=0 || b!=255 || c!=128 || field!=3)$fatal(1,"defaults or long short leak");
 press(3,5);press(6,5);if(field!=4 || diag!=1)$fatal(1,"diagnostic");
 press(3,5);press(3,18);if(!confirm || field!=5)$fatal(1,"reload confirm missing");
 press(5,5);if(confirm || reloads!=0)$fatal(1,"reload cancellation");
 press(3,18);press(6,5);if(reloads!=1)$fatal(1,"reload execute");
 press(3,5);if(field!=0)$fatal(1,"focus wrap");
 before_count=updates;fb=1;press(6,5);fb=0;if(updates!=before_count)$fatal(1,"save freeze");
 busy=1;press(6,5);busy=0;if(updates!=before_count)$fatal(1,"frame apply freeze");
 sw=0;ms(10);press(4,38);press(4,38);if(saves!=2)$fatal(1,"repeat chord saves %d",saves);
 before_count=commands;press(0,40);if(saves!=2 || commands!=before_count)$fatal(1,"three key gesture");
 cbusy=1;press(6,5);cbusy=0;if(commands!=before_count || feedback!=3)$fatal(1,"mailbox busy");
 keys=6;ms(5);sw=2;ms(5);keys=7;ms(10);if(commands!=before_count)$fatal(1,"page change leaked key");
 sw=0;ms(10);keys=6;ms(5);sw=5;keys=7;ms(8);if(commands!=before_count+1)$fatal(1,"layer change canceled key");
 alarm=1;ms(5);before_count=commands;press(6,8);alarm=0;ms(8);if(commands!=before_count)$fatal(1,"alarm key replay");
 media_ready=0;before_count=commands;press(6,5);press(3,18);
 if(commands!=before_count || feedback!=3)$fatal(1,"no media issued command");media_ready=1;
 unchanged=1;saved=1;ms(1);unchanged=0;saved=0;ms(8);if(feedback!=6)$fatal(1,"unchanged feedback not held");
 for(i=0;i<16;i=i+1)begin sw=i;ms(8);press(7,2);end
 $display("PASS demo UI: six visible fields, defaults, reload confirmation, short/long, repeat save, busy freeze, three keys and page ownership");$finish;
end
initial begin #1000000;$fatal(1,"demo UI watchdog");end
endmodule
