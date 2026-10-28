`timescale 1ns/1ps
// One system-clock input owner. Only CE advances debounce/hold timers.
// Event commands are accepted once by the frame mailbox; page changes consume
// every held key until all three have been stably released.
module demo_ui_controller #(parameter integer CLKS_PER_MS=50000,
 parameter integer DEBOUNCE_MS=20,LONG_MS=1000,SAVE_MS=3000)(
 input wire clk,rst_n,input wire [2:0] keys_n,input wire [3:0] switches,
 input wire alert_active,view_mode,apply_busy,command_busy,transition_busy,
 input wire cfg_busy,cfg_ready,cfg_fatal,load_done,save_done,save_unchanged,media_ready,
 input wire [7:0] live_brightness,live_contrast,live_volume,memory_volume,
 input wire [31:0] live_period_ms,input wire cache_ready,reload_busy,
 output reg cfg_update,output reg [7:0] cfg_brightness,cfg_contrast,cfg_volume,
 output reg [31:0] cfg_period_ms,output reg save_request,reload_request,
 output reg command_valid,output reg [2:0] command,output reg auto_mode,
 output reg [2:0] field,output reg [1:0] diag_page,
 output reg reload_confirm,output reg [3:0] feedback,output reg dirty,output wire tick_ms);
 localparam DIV_W=(CLKS_PER_MS<2)?1:$clog2(CLKS_PER_MS);
 reg [DIV_W-1:0] divider;wire tick=divider==CLKS_PER_MS-1;
 assign tick_ms=tick;
 (* async_reg="true" *) reg [2:0] key_sync1,key_sync2;
 reg [2:0] stable,previous;reg [7:0] debounce[0:2];
 reg [11:0] hold[0:2];reg [2:0] long_sent;
 reg armed,chord,chord_fired;reg [11:0] chord_ms;
 reg [3:0] page_seen;wire [3:0] page={alert_active,switches[1],view_mode,1'b0};
 reg [10:0] feedback_ms;integer i;reg [2:0] short_event,long_event;
 task reject;begin feedback<=4'd3;feedback_ms<=1500;end endtask
 task send;input [2:0] op;begin
  if(command_busy || media_ready===1'b0) reject();
  else begin command<=op;command_valid<=1;end
 end endtask
 task changed;begin cfg_update<=1;dirty<=1;end endtask
 function [7:0] vol_up;input [7:0] v;begin vol_up=v<64?64:v<128?128:v<192?192:255;end endfunction
 function [7:0] vol_down;input [7:0] v;begin vol_down=v>192?192:v>128?128:v>64?64:0;end endfunction
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   divider<=0;key_sync1<=7;key_sync2<=7;stable<=7;previous<=7;armed<=0;
   chord<=0;chord_fired<=0;chord_ms<=0;long_sent<=0;page_seen<=0;
   cfg_update<=0;cfg_brightness<=255;cfg_contrast<=128;cfg_volume<=0;cfg_period_ms<=5000;
   save_request<=0;reload_request<=0;command_valid<=0;command<=0;auto_mode<=0;
   field<=0;diag_page<=0;reload_confirm<=0;feedback<=0;feedback_ms<=0;dirty<=0;
   for(i=0;i<3;i=i+1)begin debounce[i]<=0;hold[i]<=0;end
  end else begin
   key_sync1<=keys_n;key_sync2<=key_sync1;
   divider<=tick?0:divider+1'b1;
   cfg_update<=0;save_request<=0;reload_request<=0;command_valid<=0;
   if(load_done || save_done)dirty<=0;
   if(page!=page_seen)for(i=0;i<3;i=i+1)hold[i]<=0;
   if(save_done)begin feedback<=(save_unchanged===1'b1) ? 4'd6 : 4'd2;feedback_ms<=1500;end
   if(page!=page_seen) begin
    page_seen<=page;armed<=0;chord<=0;chord_ms<=0;chord_fired<=0;long_sent<=7;
    reload_confirm<=0;
    if(switches[1] && !page_seen[2])field<=0;
   end
   if(tick) begin
    short_event=0;long_event=0;previous<=stable;
    if(feedback_ms!=0)feedback_ms<=feedback_ms-1'b1;else if(!cfg_busy)feedback<=0;
    for(i=0;i<3;i=i+1)begin
     if(key_sync2[i]==stable[i])debounce[i]<=0;
     else if(debounce[i]>=DEBOUNCE_MS-1)begin stable[i]<=key_sync2[i];debounce[i]<=0;end
     else debounce[i]<=debounce[i]+1'b1;
    end
    if(page!=page_seen || alert_active)begin
     armed<=0;chord<=0;chord_ms<=0;long_sent<=7;
     for(i=0;i<3;i=i+1)hold[i]<=0;
    end else if(!armed)begin
     if(stable==7 && key_sync2==7)begin armed<=1;long_sent<=0;previous<=7;end
    end else if(chord || stable==0 || stable[1:0]==0)begin
     chord<=1;long_sent<=7;
     if(stable==7)begin chord<=0;chord_fired<=0;chord_ms<=0;long_sent<=0;end
     else if(!stable[2])begin chord_fired<=1;chord_ms<=0;end
     else if(stable[1:0]==0 && !chord_fired)begin
      if(chord_ms>=SAVE_MS-1)begin
       chord_fired<=1;
       if(cfg_ready && !cfg_busy && !reload_busy && !apply_busy)begin save_request<=1;feedback<=1;end
       else begin feedback<=cfg_fatal?4:3;feedback_ms<=1500;end
      end else chord_ms<=chord_ms+1'b1;
     end else if(stable[1:0]!=0)begin chord_fired<=1;chord_ms<=0;end
    end else begin
     for(i=0;i<3;i=i+1)begin
      if(!stable[i])begin
       if(hold[i]<LONG_MS)hold[i]<=hold[i]+1'b1;
       if(hold[i]==LONG_MS-1 && !long_sent[i])begin long_event[i]=1;long_sent[i]<=1;end
      end else begin
       if(!previous[i] && !long_sent[i])short_event[i]=1;
       hold[i]<=0;long_sent[i]<=0;
      end
     end
     cfg_brightness<=live_brightness;cfg_contrast<=live_contrast;cfg_volume<=live_volume;cfg_period_ms<=live_period_ms;
     if(switches[1])begin
      if(short_event[2])begin field<=field==5?0:field+1'b1;reload_confirm<=0;end
      else if(reload_confirm)begin
       if(short_event[1])reload_confirm<=0;
       else if(short_event[0])begin
        reload_confirm<=0;
        if(!cfg_busy && !reload_busy)begin reload_request<=1;feedback<=5;feedback_ms<=1500;end else reject();
       end
      end else if(field==5)begin if(long_event[2])reload_confirm<=1;end
      else if(field==4)begin
       if(short_event[0])diag_page<=diag_page+1'b1;
       else if(short_event[1])diag_page<=diag_page-1'b1;
      end else if(cfg_busy || reload_busy || apply_busy)begin if(short_event!=0 || long_event[2])reject();end
      else if(long_event[2])begin cfg_brightness<=255;cfg_contrast<=128;cfg_volume<=0;cfg_period_ms<=5000;changed();end
      else if(short_event[0] || short_event[1])begin
       case(field)
        0:cfg_brightness<=short_event[0]?(live_brightness>239?255:live_brightness+16):(live_brightness<16?0:live_brightness-16);
        1:cfg_contrast<=short_event[0]?(live_contrast>239?255:live_contrast+16):(live_contrast<16?0:live_contrast-16);
        2:cfg_volume<=short_event[0]?vol_up(live_volume):vol_down(live_volume);
        3:cfg_period_ms<=short_event[0]?(live_period_ms<5000?5000:live_period_ms<10000?10000:30000):(live_period_ms>10000?10000:live_period_ms>5000?5000:2000);
       endcase
       changed();
      end
     end else if(view_mode)begin
      if(long_event[2])send(4);else if(short_event[2])send(5);
      else if(short_event[0])send(1);else if(short_event[1])send(2);
     end else begin
      if(short_event[0])send(1);
      else if(short_event[1])auto_mode<=~auto_mode;
      else if(long_event[1])send(3);
      else if(long_event[2])begin if(cache_ready && !transition_busy)send(4);else reject();end
      else if(short_event[2])begin
       if(cfg_busy || reload_busy || apply_busy)reject();
       else begin cfg_volume<=live_volume==0?(memory_volume==0?128:memory_volume):0;changed();end
      end
     end
    end
   end
  end
 end
endmodule
