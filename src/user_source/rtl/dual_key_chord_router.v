`timescale 1ns/1ps

// 模块职责：按键事件路由。把两个低有效按键整理成"短按 / 长按 / 组合键"三类单拍事件，
//           是所有人机交互的总入口，下游模块只认事件脉冲，不直接看按键电平。
// 位置：上游是顶层同步过的 key2_n/key3_n（顶层把 K2 接到 key2_n、K3 接到 key3_n），
//       下游是 param_menu_controller、media_video_pipeline、player_config_persistence。
// 时钟域：50MHz 系统时钟 clk，单域；按键电平由顶层 sync_2ff 同步后才进来。
// 输入约定：key*_n 低有效；save_enabled 表示 Flash 参数服务已就绪（就绪前不允许组合保存）。
// 输出约定：三个事件都是单拍脉冲，宽度一个 clk；
//          key2_event=短按 K2（下一张）、key3_event=短按 K3（手动/自动）、
//          key3_long_event=K3 单独长按后释放（上一张）、save_event=组合键保存。
// 判据（时间参数见模块端口）：
//   消抖/长按计时都在 dual_key_long_hold_guard 里，本模块只做状态编排；
//   按键在"释放"那一刻结算事件，所以按住不放不会连续触发；
//   先按 K2 再补 K3 会被识别为组合键，此时 K3 的长按阶梯作废（见 ST_KEY3 分支注释）；
//   组合键整段按住期间 guard 只给一次 trigger，因此一次按压只保存一次。
module dual_key_chord_router #(
    parameter integer DEBOUNCE_CYCLES = 1000000,
    parameter integer HOLD_CYCLES = 100000000,
    // KEY3 held alone for this long, then released, emits key3_long_event
    // (brightness ladder) instead of the single-click auto toggle.
    parameter integer KEY3_LONG_CYCLES = 50000000
) (
    input  wire clk,
    input  wire rst_n,
    input  wire save_enabled,
    input  wire key2_n,
    input  wire key3_n,
    output reg  key2_event,
    output reg  key3_event,
    output reg  key3_long_event,
    output wire save_event,
    output wire save_locked,
    output wire key2_stable_n,
    output wire key3_stable_n
);
    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_KEY2 = 2'd1;
    localparam [1:0] ST_KEY3 = 2'd2;
    localparam [1:0] ST_CHORD = 2'd3;

    reg [1:0] state;
    reg save_armed;
    wire guard_trigger;
    reg [31:0] key3_hold_count;
    reg key3_long_marked;

    initial begin
        if (DEBOUNCE_CYCLES < 1 || HOLD_CYCLES < 1) begin
            $display("DUAL_KEY_CHORD_ROUTER_CONFIG_ERROR invalid timing parameter");
            $finish;
        end
    end

    // ===== 组合键守护：只负责"消抖 + 同时按住足够久" =====
    // save_armed 表示"两键都已松开过"——必须先全部松开，组合键才被允许触发，
    // 这样上一次保存还没松手时不会重复触发。
    // 只有在 ST_CHORD 状态且 save_enabled（Flash 服务就绪）时 guard 才工作；
    // guard 输出 trigger 就是保存事件，locked 期间不会再次 trigger。
    dual_key_long_hold_guard #(
        .DEBOUNCE_CYCLES(DEBOUNCE_CYCLES),
        .HOLD_CYCLES(HOLD_CYCLES)
    ) u_guard (
        .clk(clk), .rst_n(rst_n),
        .enabled(save_enabled && save_armed && state == ST_CHORD),
        .key2_n(key2_n), .key3_n(key3_n), .trigger(guard_trigger),
        .locked(save_locked), .key2_stable_n(key2_stable_n),
        .key3_stable_n(key3_stable_n)
    );

    assign save_event = guard_trigger;

    // ===== 按键状态机 =====
    // 四个状态：IDLE 空闲 / ST_KEY2 只按着 K2 / ST_KEY3 只按着 K3 / ST_CHORD 两键同时按。
    // 事件统一在"松开的那一拍"发出，所以按下不松不会连发。
    // 从任一单键状态补按另一个键都会切到 ST_CHORD，并把 K3 的长按计数清零，
    // 这样"K3 长按调亮度"不会被误判成组合保存。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            save_armed <= 1'b0;
            key2_event <= 1'b0;
            key3_event <= 1'b0;
            key3_long_event <= 1'b0;
            key3_hold_count <= 32'd0;
            key3_long_marked <= 1'b0;
        end else begin
            key2_event <= 1'b0;
            key3_event <= 1'b0;
            key3_long_event <= 1'b0;

            if (!save_enabled)
                save_armed <= 1'b0;
            else if (key2_stable_n && key3_stable_n)
                save_armed <= 1'b1;

            case (state)
                ST_IDLE: begin
                    if (!key2_stable_n && !key3_stable_n)
                        state <= ST_CHORD;
                    else if (!key2_stable_n)
                        state <= ST_KEY2;
                    else if (!key3_stable_n) begin
                        state <= ST_KEY3;
                        key3_hold_count <= 32'd0;
                        key3_long_marked <= 1'b0;
                    end
                end
                ST_KEY2: begin
                    if (!key2_stable_n && !key3_stable_n) begin
                        state <= ST_CHORD;
                    end else if (key2_stable_n) begin
                        key2_event <= 1'b1;
                        state <= key3_stable_n ? ST_IDLE : ST_KEY3;
                    end
                end
                ST_KEY3: begin
                    if (!key2_stable_n && !key3_stable_n) begin
                        // KEY2 joining cancels the long-press ladder and
                        // hands the pair to the save chord.
                        state <= ST_CHORD;
                        key3_hold_count <= 32'd0;
                        key3_long_marked <= 1'b0;
                    end else if (key3_stable_n) begin
                        // 松开 K3 时结算：按住超过 KEY3_LONG_CYCLES 算长按（上一张），
                        // 否则算短按（手动/自动切换）。结算完把计时复位。
                        if (key3_long_marked)
                            key3_long_event <= 1'b1;
                        else
                            key3_event <= 1'b1;
                        key3_hold_count <= 32'd0;
                        key3_long_marked <= 1'b0;
                        state <= key2_stable_n ? ST_IDLE : ST_KEY2;
                    end else if (key3_hold_count < KEY3_LONG_CYCLES) begin
                        // 长按计时：计到阈值前先打"已长按"标记，等松开时才真正发事件；
                        // 这样长按过程中画面不会提前动作。
                        key3_hold_count <= key3_hold_count + 1'b1;
                        if (key3_hold_count == KEY3_LONG_CYCLES - 1)
                            key3_long_marked <= 1'b1;
                    end
                end
                ST_CHORD: begin
                    // 组合键状态下什么都不发，保存事件由 guard 的 trigger 单独产生；
                    // 两键都松开后回到 IDLE，下一次组合按压才能重新被认可。
                    if (key2_stable_n && key3_stable_n)
                        state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
            end
    end
endmodule
