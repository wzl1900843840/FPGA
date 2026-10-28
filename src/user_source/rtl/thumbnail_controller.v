`timescale 1ns/1ps
// 所有输入均在 clk 域。事件先更新 pending，只有 frame_start 才提交可见状态。
// -----------------------------------------------------------------------------
// 缩略图模式控制器（像素域）
//
// 干什么：管理"全屏 ↔ 缩略图"的切换、缩略图里的焦点移动、以及确认选择。
//   key_mode    ：进出缩略图（顶层保证缓存没建好时不给这个键）
//   key_right/left：焦点格左右环绕移动
//   key_confirm ：确认当前焦点格，切回全屏并播放选中的那张
//
// 为什么要有 pending 这一层：
//   按键是异步来的，如果直接改 focus_index/active_index，画面可能在一帧中间变化，
//   而且"移动焦点后立刻确认"会引用到还没生效的旧焦点。所以规则是：
//     事件到来只更新 pending_*；到 frame_start 那一拍才把 pending 整体提交成可见状态。
//   这样一帧之内看到的状态永远自洽，切换也不会撕裂。
//
// 两个细节：
//   - 只有 image_complete[焦点] 为真才允许确认（没加载好的图不能选）；
//   - selection_committed 是给顶层的一拍脉冲，表示"选择已提交"，
//     顶层用它等目标 bank 真正被读取器接管后再退出缩略图，避免闪回旧图。
// -----------------------------------------------------------------------------
module thumbnail_controller (
    input wire clk, rst_n,
    input wire key_right, key_left, key_confirm, key_mode,
    input wire [3:0] image_complete,
    input wire frame_start,
    output reg view_mode,
    output reg [1:0] focus_index, active_index,
    output reg transition_req,
    output reg selection_committed,
    input wire cancel
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
                // 帧边界统一提交：这一帧内所有变化对外同时生效
                view_mode<=cancel ? 1'b0 : pending_mode; focus_index<=pending_focus;
                active_index<=pending_active; transition_req<=pending_transition;
                pending_transition<=0;
                selection_committed<=pending_selection && !cancel;pending_selection<=0;
            end
            // 同拍新事件进入下一帧，不被上面的提交清除。
            if(cancel) begin
                pending_mode<=0; pending_selection<=0;
                if(pending_mode) pending_transition<=1;
            end
            else if(key_mode) begin pending_mode<=~pending_mode; pending_transition<=1;pending_selection<=0; end
            else if(pending_mode) begin
                // 缩略图模式下：左右移动焦点（2位自然环绕），确认需目标图已完整
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
