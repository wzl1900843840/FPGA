`timescale 1ns/1ps
// 所有输入均在 clk 域。事件先更新 pending，只有 frame_start 才提交可见状态。
module thumbnail_controller (
    input wire clk, rst_n,
    input wire key_right, key_left, key_confirm, key_mode,
    input wire [3:0] image_complete,
    input wire frame_start,
    output reg view_mode,
    output reg [1:0] focus_index, active_index,
    output reg transition_req,
    output reg selection_committed
);
    reg pending_mode, pending_transition;
    reg pending_selection;
    reg [1:0] pending_focus, pending_active;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            view_mode<=0; focus_index<=0; active_index<=0; transition_req<=0;
            pending_mode<=0; pending_focus<=0; pending_active<=0; pending_transition<=0;
            pending_selection<=0;selection_committed<=0;
        end else begin
            transition_req<=0;
            selection_committed<=0;
            if(frame_start) begin
                view_mode<=pending_mode; focus_index<=pending_focus;
                active_index<=pending_active; transition_req<=pending_transition;
                pending_transition<=0;
                selection_committed<=pending_selection;pending_selection<=0;
            end
            // 同拍新事件进入下一帧，不被上面的提交清除。
            if(key_mode) begin pending_mode<=~pending_mode; pending_transition<=1;pending_selection<=0; end
            else if(pending_mode) begin
                if(key_right) pending_focus<=pending_focus+1'b1;
                else if(key_left) pending_focus<=pending_focus-1'b1;
                if(key_confirm && image_complete[pending_focus]) begin
                    pending_active<=pending_focus; pending_mode<=0; pending_transition<=1;
                    pending_selection<=1;
                end
            end
        end
    end
endmodule
