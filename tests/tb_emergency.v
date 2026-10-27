`timescale 1ns/1ps
module tb_emergency;
reg clk=0,rst=0,fs=0,alarm=0,fault=0; always #5 clk=~clk;
reg [4:0] complete=15;
reg next=0,sel=0,auto_valid=0,auto_value=0; reg [2:0] selection=0;
wire alert,fallback,busy,commit,auto_on; wire [2:0] active,pending,state,page;
wire [7:0] error; wire [31:0] period;
elevator_demo_controller e(.clk(clk),.rst_n(rst),.frame_start(fs),
 .startup_ready(|complete[3:0]),.media_fault(fault),.alert_request(alarm),
 .alert_page_available(complete[4] && active==4 && !fault),
 .alert_active(alert),.alert_fallback(fallback),.alert_page_index(page),.state_code(state));
media_player_control #(.DEFAULT_PERIOD_CYCLES(100000),.MIN_PERIOD_CYCLES(1)) p(
 .sys_clk(clk),.sys_rst_n(rst),.next_event(next),.previous_event(1'b0),
 .select_valid(sel),.select_index(selection),.toggle_auto_event(1'b0),
 .period_cfg_valid(1'b0),.period_cfg_cycles(32'd100000),.auto_cfg_valid(auto_valid),
 .auto_cfg_enabled(auto_value),.image_complete(complete),.auto_enabled(auto_on),
 .active_period_cycles(period),.pending_index(pending),.control_error(error),.request_busy(busy),
 .pix_clk(clk),.pix_rst_n(rst),.frame_start(fs),.emergency_active(alarm),
 .emergency_index(page),.active_index(active),.index_commit(commit));
reg fade_req=0; wire fade_next,fade_busy,fade_active,wipe; wire[7:0]alpha;wire[4:0]ramp;wire[1:0]kind;
video_fade_transition #(.FADE_FRAMES(4)) f(clk,rst,fade_req,fade_next,fade_busy,clk,rst,1'b1,fs,commit,active[1:0],alpha,fade_active,wipe,ramp,kind,alarm);
task frame;begin repeat(40)@(negedge clk);fs=1;@(negedge clk);fs=0;repeat(4)@(negedge clk);end endtask
task choose;input[2:0]n;begin @(negedge clk);selection=n;sel=1;@(negedge clk);sel=0;frame;frame;if(active!==n)$fatal(1,"choose %d got %d",n,active);end endtask
task enter;begin alarm=1;frame;if(!alert || ((!complete[4] || fault) && !fallback))$fatal(1,"first-frame emergency fallback missing");frame;if(!alert)$fatal(1,"alarm lost");end endtask
task clear;input[2:0]n;begin alarm=0;frame;frame;frame;if(alert||active!==n)$fatal(1,"recovery >3 frames got %d expected%d",active,n);end endtask
integer i;
initial begin
 #22;rst=1;frame;choose(2);
 auto_value=1;auto_valid=1;@(negedge clk);auto_valid=0;
 // A normal request and fade are already pending when alarm takes over.
 next=1;fade_req=1;@(negedge clk);next=0;fade_req=0;
 if(!busy)$fatal(1,"busy setup failed");enter;
 if(active!==2 || !fallback)$fatal(1,"missing PIC5 must preserve visible daily page behind fallback");
 auto_value=0;auto_valid=1;complete[4]=1;frame;frame;auto_valid=0;
 if(active!==4 || fallback || alpha!==255 || fade_next)$fatal(1,"late PIC5/fade takeover failed");
 if(!auto_on)$fatal(1,"auto mode changed during alarm");
 clear(2);if(fade_active || wipe || alpha!=255)$fatal(1,"recovery hidden by ordinary 16-frame transition");
 for(i=0;i<8;i=i+1)frame;
 if(active!==2 || busy || fade_next)$fatal(1,"late normal/PIC5 request escaped recovery");
 // Media fault before and after alarm, including no valid daily banks.
 complete=0;fault=1;frame;if(state!==4)$fatal(1,"fault page missing");
 enter;if(!fallback)$fatal(1,"fault covered fallback");
 complete=5'b10010;frame;frame;if(!alert||!fallback)$fatal(1,"read fault covered emergency");
 fault=0;frame;if(fallback || active!==4)$fatal(1,"PIC5 did not recover");
 clear(1);
 // Clear while old emergency handshake is waiting: no late PIC5.
 choose(1);enter;alarm=0;complete[4]=0;frame;complete[4]=1;
 frame;frame;for(i=0;i<4;i=i+1)frame;
 if(active!==1 || alert)$fatal(1,"cancelled request restored PIC5");
 complete=0;fault=1;enter;alarm=0;frame;frame;frame;
 if(state!==4 || alert)$fatal(1,"no daily page recovery must show fault");
 complete=5'b00100;fault=0;frame;frame;frame;
 if(active!==2)$fatal(1,"late valid daily page never restored");
 $display("PASS emergency: busy, late PIC5, fault/alarm order, fade abort, saved page/auto, invalid page fallback, cancellation, <=2/3 frames");$finish;
end
initial begin #1000000;$fatal(1,"emergency timeout");end
endmodule
