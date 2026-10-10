`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// 单拍脉冲跨时钟域（工程里所有按键/事件/启动脉冲都走它）
//
// 直接打两拍不行：源域一个时钟宽的脉冲，很可能正好落在目的域两个时钟沿之间被整拍漏掉。
// 这里的做法是"翻转电平 + 边沿检测"：
//   1) 源域每来一个 src_pulse 就把 toggle 翻一次（电平保持，不会被漏采）；
//   2) 目的域把 toggle 打两拍，再和上一拍比较，电平变化的那一拍就是 dst_pulse；
//   3) 输出必然是目的域的一个单拍脉冲，宽度和周期都干净。
//
// 合同：两次源事件之间至少要隔 4 个目的时钟周期（本次翻转要被完整采到、再翻回来）。
// 本工程按键有 20ms 消抖，远远满足；不要用它传高频连续事件。
// -----------------------------------------------------------------------------
// 低频人机事件；两次源事件至少相隔4个目的时钟。按键20ms消抖满足此合同。
module pulse_toggle_sync(input wire src_clk,src_rst_n,src_pulse,
    input wire dst_clk,dst_rst_n,output wire dst_pulse);
    reg toggle;
    (* async_reg="true" *) reg s1,s2;
    reg seen;
    always @(posedge src_clk or negedge src_rst_n)
        if(!src_rst_n) toggle<=0;else if(src_pulse) toggle<=~toggle;   // 源域：单拍脉冲→电平翻转
    always @(posedge dst_clk or negedge dst_rst_n)
        if(!dst_rst_n) begin s1<=0;s2<=0;seen<=0;end
        else begin s1<=toggle;s2<=s1;seen<=s2;end                       // 目的域：两拍同步+一拍延迟
    assign dst_pulse=s2^seen;                                           // 电平变化=一次事件
endmodule
