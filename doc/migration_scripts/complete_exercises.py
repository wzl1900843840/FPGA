"""一次性迁移脚本：补全教程练习。修改记录见 doc/教程对照与验收.md。"""
from pathlib import Path

RTL = Path(__file__).resolve().parents[1] / 'src/user_source/rtl'

p = RTL / 'brightness_contrast_adjust.v'
t = p.read_text(encoding='utf-8-sig')
t = t[:t.index('    // ----')] + '''    // 255 为逐位旁路，0 为全黑；其余档位用 /256，符合教程验收基准。
    function [7:0] adjust;
        input [7:0] value;
        input [7:0] bright;
        input [7:0] cont;
        reg [15:0] product;
        reg [7:0] b;
        reg signed [17:0] centered, scaled;
        begin
            product = value * bright;
            b = bright == 255 ? value : product[15:8];
            centered = $signed({1'b0,b}) - 18'sd128;
            scaled = ((centered * $signed({1'b0,cont})) >>> 7) + 18'sd128;
            adjust = scaled < 0 ? 8'd0 : scaled > 255 ? 8'd255 : scaled[7:0];
        end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin out_de <= 0; rgb_out <= 0; end
        else begin
            out_de <= in_de;
            rgb_out <= in_de ? {adjust(rgb_in[23:16],brightness,contrast),
                               adjust(rgb_in[15:8],brightness,contrast),
                               adjust(rgb_in[7:0],brightness,contrast)} : 24'd0;
        end
    end
endmodule
'''
p.write_text(t.replace('练习骨架（完赛工程未单独实现）','练习完成版'), encoding='utf-8')
p = RTL / 'bilinear_8q8.v'
t = p.read_text(encoding='utf-8-sig')
start=t.index('    // ---- R通道')
t=t[:start]+'''    // 两级 Q0.8 加权，权重补数必须为 9 位，行结果先截到 8 位。
    function [7:0] interpolate;
        input [7:0] a,b,c,d,x,y;
        reg [8:0] ix,iy;
        reg [15:0] upper,lower,total;
        begin
            ix=9'd256-{1'b0,x}; iy=9'd256-{1'b0,y};
            upper=a*ix+b*x; lower=c*ix+d*x;
            total=upper[15:8]*iy+lower[15:8]*y;
            interpolate=total[15:8];
        end
    endfunction
    assign out_r=interpolate(p00_r,p10_r,p01_r,p11_r,wx,wy);
    assign out_g=interpolate(p00_g,p10_g,p01_g,p11_g,wx,wy);
    assign out_b=interpolate(p00_b,p10_b,p01_b,p11_b,wx,wy);
endmodule
'''
t=t.replace('选做骨架（完赛工程未实现）','三通道实现').replace('   // TODO(G通道)：接入对应像素','').replace('   // TODO(B通道)：接入对应像素','')
p.write_text(t,encoding='utf-8')
p=RTL/'thumbnail_controller.v'
p.write_text('''`timescale 1ns/1ps
// 所有输入均在 clk 域。事件先更新 pending，只有 frame_start 才提交可见状态。
module thumbnail_controller (
    input wire clk, rst_n,
    input wire key_right, key_left, key_confirm, key_mode,
    input wire [3:0] image_complete,
    input wire frame_start,
    output reg view_mode,
    output reg [1:0] focus_index, active_index,
    output reg transition_req
);
    reg pending_mode, pending_transition;
    reg [1:0] pending_focus, pending_active;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            view_mode<=0; focus_index<=0; active_index<=0; transition_req<=0;
            pending_mode<=0; pending_focus<=0; pending_active<=0; pending_transition<=0;
        end else begin
            transition_req<=0;
            if(frame_start) begin
                view_mode<=pending_mode; focus_index<=pending_focus;
                active_index<=pending_active; transition_req<=pending_transition;
                pending_transition<=0;
            end
            // 同拍新事件进入下一帧，不被上面的提交清除。
            if(key_mode) begin pending_mode<=~pending_mode; pending_transition<=1; end
            else if(pending_mode) begin
                if(key_right) pending_focus<=pending_focus+1'b1;
                else if(key_left) pending_focus<=pending_focus-1'b1;
                if(key_confirm && image_complete[pending_focus]) begin
                    pending_active<=pending_focus; pending_mode<=0; pending_transition<=1;
                end
            end
        end
    end
endmodule
''',encoding='utf-8')
# SDRAM 参数与最终版单 PLL 的 40 MHz 输出配套。
p=RTL.parent/'hdl_source/include/global_def.v'
t=p.read_text(encoding='utf-8-sig'); import re
t=re.sub(r'1000000000\s*/\s*\d+', '1000000000/40000000', t)
p.write_text(t,encoding='utf-8')
