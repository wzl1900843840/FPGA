// bilinear_8q8.v —— 双线性插值三通道实现
// 输入：4个相邻像素 p00/p10/p01/p11（左上/右上/左下/右下）
//       wx = (x的小数部分)<<8, wy = (y的小数部分)<<8  (0~255)
// 思路：先按行加权，再按列加权，每步乘16位再取高8位
// R/G/B 三个通道均已补齐，作为可选插值练习模块：
module bilinear_8q8 (
    input  wire [7:0] p00_r, p10_r, p01_r, p11_r,
    input  wire [7:0] p00_g, p10_g, p01_g, p11_g,
    input  wire [7:0] p00_b, p10_b, p01_b, p11_b,
    input  wire [7:0] wx, wy,
    output wire [7:0] out_r, out_g, out_b
);
    // 两级 Q0.8 加权，权重补数必须为 9 位，行结果先截到 8 位。
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
