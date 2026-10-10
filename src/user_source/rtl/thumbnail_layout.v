`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// 缩略图版面（纯组合，像素域）
//
// 屏幕上四格缩略图的坐标映射：
//   四格 160×120 拼成 320×240，居中放在 640×480 画面里，
//   所以左上角起点 ORIGIN_X=(640-320)/2=160、ORIGIN_Y=(480-240)/2=120。
//
//   图号排布（source_index）：
//        (0,0)=图0   (1,0)=图1
//        (0,1)=图2   (1,1)=图3
//   即先按上下半加 2，再看是不是右半格再加 1。
//
// 输出三类信息：
//   thumb_de     —— 当前像素是否落在某一格里（顶层用它决定显示缩略图还是黑底）；
//   source_x/y   —— 该格内像素对应到原图的坐标（局部坐标 ×4，因为 4:1 抽样）；
//   focus_border —— 当前焦点格的四条 2 像素边框，顶层把它画成黄色。
//
// 注意：image_complete[该格图号] 为 0 时 thumb_de 保持 0（那一格留黑），
// 所以没加载好的图不会显示半张。
// -----------------------------------------------------------------------------
module thumbnail_layout #(
    parameter integer DISPLAY_WIDTH = 640,
    parameter integer DISPLAY_HEIGHT = 480,
    parameter integer THUMB_WIDTH = 160,
    parameter integer THUMB_HEIGHT = 120
) (
    input  wire        in_de,
    input  wire [11:0] pixel_x,
    input  wire [11:0] pixel_y,
    input  wire [1:0]  focus_index,
    input  wire [3:0]  image_complete,
    output reg         thumb_de,
    output reg  [1:0]  source_index,
    output reg  [9:0]  source_x,
    output reg  [9:0]  source_y,
    output reg         focus_border
);
    localparam integer ORIGIN_X = (DISPLAY_WIDTH - 2*THUMB_WIDTH) / 2;
    localparam integer ORIGIN_Y = (DISPLAY_HEIGHT - 2*THUMB_HEIGHT) / 2;
    integer window_x;
    integer window_y;
    integer local_x;
    integer local_y;
    always @* begin
        window_x=0;window_y=0;local_x=0;local_y=0;
        thumb_de = 1'b0;
        source_index = 2'd0;
        source_x = 10'd0;
        source_y = 10'd0;
        focus_border = 1'b0;
        if (in_de && pixel_x >= ORIGIN_X && pixel_x < ORIGIN_X + 2*THUMB_WIDTH &&
            pixel_y >= ORIGIN_Y && pixel_y < ORIGIN_Y + 2*THUMB_HEIGHT) begin
            // 落在四格区域内：先按上下半选图号(0/2)，再看是否右半格(+1)
            source_index = (pixel_y >= ORIGIN_Y + THUMB_HEIGHT) ? 2'd2 : 2'd0;
            if (pixel_x >= ORIGIN_X + THUMB_WIDTH)
                source_index = source_index + 1'b1;
            // 求本格左上角，再算出格内局部坐标
            window_x = ORIGIN_X + ((pixel_x >= ORIGIN_X + THUMB_WIDTH) ? THUMB_WIDTH : 0);
            window_y = ORIGIN_Y + ((pixel_y >= ORIGIN_Y + THUMB_HEIGHT) ? THUMB_HEIGHT : 0);
            local_x = pixel_x - window_x;
            local_y = pixel_y - window_y;
            if (local_x < THUMB_WIDTH && local_y < THUMB_HEIGHT && image_complete[source_index]) begin
                thumb_de = 1'b1;
                // 4:1 抽样：缩略图 1 像素对应原图 4 像素
                source_x = local_x * (640 / THUMB_WIDTH);
                source_y = local_y * (480 / THUMB_HEIGHT);
                // 焦点格画 2 像素边框（四条边各 2 像素宽）
                focus_border = source_index == focus_index &&
                               (local_x < 2 || local_y < 2 ||
                                local_x >= THUMB_WIDTH-2 || local_y >= THUMB_HEIGHT-2);
            end
        end
    end
endmodule
