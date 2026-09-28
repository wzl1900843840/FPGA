// brightness_contrast_adjust.v —— 第13课练习完成版
module brightness_contrast_adjust (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_de,
    input  wire [23:0] rgb_in,
    input  wire [7:0]  brightness,   // 帧边界锁存后的亮度
    input  wire [7:0]  contrast,     // 帧边界锁存后的对比度
    output reg         out_de,
    output reg  [23:0] rgb_out
);
    // 255 为逐位旁路，0 为全黑；其余档位用 /256，符合教程验收基准。
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
