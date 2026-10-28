`timescale 1ns/1ps
module tb_fix_single_image;
reg clk=0,rst=0,next=0; always #20 clk=~clk;
reg [7:0] phase=0; wire fs=(phase==0);
always @(posedge clk) if(!rst) phase<=0;else if(phase==39)phase<=0;else phase<=phase+1;
wire fn,busy,commit;wire [7:0] alpha;wire [2:0] active,pending;
wire [7:0] err;
video_fade_transition #(.FADE_FRAMES(16)) fade(
 .ctrl_clk(clk),.ctrl_rst_n(rst),.next_event_in(next),.next_event_out(fn),.fade_busy(busy),
 .pix_clk(clk),.pix_rst_n(rst),.player_active(1'b1),.frame_start(fs),
 .index_commit(commit),.active_index(active[1:0]),.alpha_out(alpha),.fade_active(),
 .wipe_active(),.ramp_out(),.transition_kind(),.emergency_active(1'b0));
media_player_control #(.DEFAULT_PERIOD_CYCLES(1000),.MIN_PERIOD_CYCLES(1),.MAX_PERIOD_CYCLES(100000)) control(
 .sys_clk(clk),.sys_rst_n(rst),.next_event(fn),.previous_event(1'b0),
 .select_valid(1'b0),.select_index(3'd0),.toggle_auto_event(1'b0),
 .period_cfg_valid(1'b0),.period_cfg_cycles(32'd1000),.auto_cfg_valid(1'b0),.auto_cfg_enabled(1'b0),
 .image_complete(5'b00001),.auto_enabled(),.active_period_cycles(),.pending_index(pending),.control_error(err),.request_busy(),
 .pix_clk(clk),.pix_rst_n(rst),.frame_start(fs),.emergency_active(1'b0),.emergency_index(3'd4),
 .active_index(active),.index_commit(commit));
integer commits=0;always @(posedge clk)if(commit)commits=commits+1;
initial begin
 #93;rst=1;repeat(10)@(negedge clk);next=1;@(negedge clk);next=0;
 repeat(40*55)@(negedge clk);
 if(alpha==255 && !busy && active==0 && commits>=1)
  $display("PASS single valid image: manual NEXT completes visibly, alpha=%0d busy=%0d active=%0d commits=%0d",alpha,busy,active,commits);
 else $fatal(1,"single-image hazard not reproduced alpha=%0d busy=%0d active=%0d commits=%0d",alpha,busy,active,commits);
 $finish;
end
initial begin #500000;$fatal(1,"audit timeout");end
endmodule
