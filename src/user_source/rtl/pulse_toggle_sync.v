`timescale 1ns/1ps
// 低频人机事件；两次源事件至少相隔4个目的时钟。按键20ms消抖满足此合同。
module pulse_toggle_sync(input wire src_clk,src_rst_n,src_pulse,
    input wire dst_clk,dst_rst_n,output wire dst_pulse);
    reg toggle;
    (* async_reg="true" *) reg s1,s2;
    reg seen;
    always @(posedge src_clk or negedge src_rst_n)
        if(!src_rst_n) toggle<=0;else if(src_pulse) toggle<=~toggle;
    always @(posedge dst_clk or negedge dst_rst_n)
        if(!dst_rst_n) begin s1<=0;s2<=0;seen<=0;end
        else begin s1<=toggle;s2<=s1;seen<=s2;end
    assign dst_pulse=s2^seen;
endmodule
