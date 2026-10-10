`timescale 1ns/1ps

// Frame-stable time-domain waveform, filled envelope and peak-hold VU meter.
// No FFT, per-pixel multipliers or frame buffer are required.
//
// 模块职责：把 PCM 样本画成"时域波形 + 填充包络 + 峰值保持音量柱"的底板，
//           叠加在照片像素上，是照片优先界面里唯一的音频可视化。
// 位置：上游是 media_hdmi_audio_bridge 的 pcm_tap（真正送进 HDMI 的样本），
//       下游是 HDMI 编码链，本模块只改 RGB，不动 hs/vs/de。
// 时钟域：25MHz 像素时钟；样本在整帧期间按 DECIMATE 抽点采集，帧边界换 bank。
// 输入约定：pixel_x 是水平像素坐标，vsync 用来定位帧边界，de 表示有效像素；
//          pcm_tap_valid 是"样本可用"的单拍脉冲。
// 输出约定：rgb_out 是叠加后的像素，waveform_active 表示本像素属于面板区域。
//
// 为什么这样设计：
//   1) 64 点采样 + 双缓冲：采集 bank 与显示 bank 分离，一帧内画面绝不半更新，
//      所以不会出现波形撕裂；换 bank 只在帧边界发生。
//   2) 不用帧缓存、不用乘法器：连线段用三次移位加法做线性插值，
//      混色用 (7*底图+效果)/8 与 (3*底图+效果)/4 的移位加法实现，省 DSP。
//   3) 静音不做"清空显示"，而是把显示幅值逐帧右移衰减，约 6 帧回到零轴，
//      避免静音瞬间波形突然消失造成的视觉跳变。
module promax_audio_waveform #(
    parameter integer WAVE_X=64, WAVE_Y=400, WAVE_WIDTH=512, WAVE_HEIGHT=64,
    parameter integer DECIMATE=8,
    parameter integer PIPELINE_OUTPUT=0
)(
    input wire clk,rst_n,vsync,de,
    input wire [23:0] rgb_in,
    input wire [9:0] pixel_x,
    input wire enable,pcm_tap_valid,
    input wire signed [15:0] pcm_tap_left,
    output wire [23:0] rgb_out,
    output wire waveform_active
);
    // ===== 采样与显示的双缓冲 =====
    // sample_bank0/1 各存 64 个 8bit 有符号样本（取样本高 8 位即可，显示精度足够）；
    // write_bank 指向正在采集的那一组，display_bank 指向正在显示的那一组，
    // 两者永远相反，所以采集过程不会影响当前画面。
    // peak_bank0/1 同步记录该 bank 的绝对值峰值，供音量柱使用。
    localparam integer SAMPLE_COUNT=64;
    localparam integer SAMPLE_SPACING=WAVE_WIDTH/SAMPLE_COUNT;
    localparam integer CENTER=WAVE_HEIGHT/2;
    localparam signed [8:0] DISP_MAX=CENTER-5, DISP_MIN=5-CENTER;
    reg [11:0] line_y;
    reg de_q,vs_q;
    wire frame_start=vs_q && !vsync;
    reg signed [7:0] sample_bank0[0:SAMPLE_COUNT-1];
    reg signed [7:0] sample_bank1[0:SAMPLE_COUNT-1];
    reg write_bank,display_bank,display_valid;
    reg [6:0] capture_count;
    reg [7:0] decimate_count,peak_bank0,peak_bank1;
    reg [7:0] display_peak,held_peak;
    reg [3:0] hold_frames;
    reg [2:0] silence_shift;
    // captured_peak 取"正在采集那一组"的峰值：帧末用它判断这一帧是否整段静音，
    // 以及决定音量柱要不要更新。
    wire [7:0] sample_abs=pcm_tap_left[15] ?
        (~pcm_tap_left[15:8]+1'b1) : pcm_tap_left[15:8];
    wire [7:0] captured_peak=write_bank ? peak_bank1 : peak_bank0;
    // ===== 采集/显示控制与峰值保持 =====
    // frame_start 是 vsync 下降沿，即每帧只执行一次的"结算点"。
    // line_y 用 de 的下降沿计数，得到当前行的 Y 坐标（与顶层 video_y 等价，
    // 这里自己数是为了不依赖上游是否把 Y 接进来）。
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            line_y<=0;de_q<=0;vs_q<=1;write_bank<=0;display_bank<=1;
            display_valid<=0;capture_count<=0;decimate_count<=0;
            peak_bank0<=0;peak_bank1<=0;display_peak<=0;held_peak<=0;hold_frames<=0;
            silence_shift<=0;
        end else begin
            de_q<=de;vs_q<=vsync;
            if(!vsync) line_y<=0;
            else if(de_q && !de) line_y<=line_y+1'b1;
            if(frame_start) begin
                if(capture_count==SAMPLE_COUNT) begin
                    // On silence, retain the visible bank and attenuate it for
                    // six frames (~101 ms). Capture still owns the other bank.
                    // Audio gain itself is zero immediately; only the visual decays.
                    if(captured_peak==0 && display_valid && silence_shift<5) begin
                        // 本帧整段静音：不换 bank、不清显示，只把 silence_shift 加一，
                        // 让显示幅值右移更多位，画面在约 6 帧内衰减回零轴。
                        // 采集仍占用另一个 bank，所以衰减期间新声音一进来就能立刻显示。
                        silence_shift<=silence_shift+1'b1;
                        if(write_bank) peak_bank1<=0;else peak_bank0<=0;
                    end else begin
                        display_bank<=write_bank;display_valid<=1;write_bank<=~write_bank;
                        silence_shift<=0;
                        // Clear the new capture bank, never the visible bank.
                        if(write_bank) peak_bank0<=0;else peak_bank1<=0;
                    end
                    // 音量柱：显示的峰值取两者较大值，回落时每帧减 2（慢降，不抖）；
                    // held_peak 是"峰值保持"标记，命中新峰值后保持 12 帧，之后每帧减 1。
                    if(captured_peak>=display_peak) display_peak<=captured_peak;
                    else if(display_peak>2) display_peak<=display_peak-2;
                    else display_peak<=0;
                    if(captured_peak>=held_peak) begin held_peak<=captured_peak;hold_frames<=12;end
                    else if(hold_frames!=0) hold_frames<=hold_frames-1'b1;
                    else if(held_peak!=0) held_peak<=held_peak-1'b1;
                end else begin
                    if(write_bank) peak_bank1<=0;else peak_bank0<=0;
                end
                capture_count<=0;decimate_count<=0;
            end else if(enable && pcm_tap_valid && capture_count<SAMPLE_COUNT) begin
                // 抽取：decimate_count 从 DECIMATE-1 递减，减到 0 才真正存一个样本，
                // 于是每 DECIMATE 个有效样本采一个点，64 个点正好铺满面板宽度。
                if(decimate_count==0) begin
                    if(write_bank) begin
                        sample_bank1[capture_count[5:0]]<=pcm_tap_left[15:8];
                        if(sample_abs>peak_bank1) peak_bank1<=sample_abs;
                    end else begin
                        sample_bank0[capture_count[5:0]]<=pcm_tap_left[15:8];
                        if(sample_abs>peak_bank0) peak_bank0<=sample_abs;
                    end
                    capture_count<=capture_count+1'b1;decimate_count<=DECIMATE-1;
                end else decimate_count<=decimate_count-1'b1;
            end
        end
    end
    // ===== 显示段：面板区域判定与波形几何 =====
    // local_x/local_y 是相对面板原点的坐标；panel 条件里额外加了 24 像素，
    // 因为面板右侧还要留出音量柱的位置；最外圈 3 像素是边框，挖空后由边框色填充。
    wire [9:0] local_x=pixel_x-WAVE_X;
    wire [6:0] local_y=line_y-WAVE_Y;
    wire panel=enable && de && pixel_x>=WAVE_X && pixel_x<WAVE_X+WAVE_WIDTH+24 &&
        line_y>=WAVE_Y && line_y<WAVE_Y+WAVE_HEIGHT &&
        !((local_x<3 || local_x>=WAVE_WIDTH+21) && (local_y<3 || local_y>=WAVE_HEIGHT-3));
    // sample_index 把横向像素映射到第几个采样点（WAVE_WIDTH/64 = 8 像素一个点），
    // previous_index 是它左边相邻的点，两者之间的连线靠插值补齐。
    wire [5:0] sample_index=local_x/SAMPLE_SPACING;
    wire [5:0] previous_index=sample_index==0 ? 0 : sample_index-1'b1;
    reg signed [7:0] selected_sample,previous_sample;
    reg signed [8:0] displacement,previous_displacement;
    reg [6:0] sample_y,previous_y,trace_y,amplitude;
    reg signed [9:0] delta;
    reg signed [12:0] interpolated_delta;
    reg [6:0] distance,level,marker;
    reg [23:0] color;
    reg trace,glow,fill,grid,border,meter;
    // Widen before shifting: floor((7*photo+effect)/8) and
    // floor((3*photo+effect)/4). Blends always use the original pixel,
    // so overlapping layers never compound the darkening. No DSP required.
    // ===== 颜色混合函数 =====
    // quarter=1 走 75% 底图：floor((3*photo+effect)/4)；
    // quarter=0 走 87.5% 底图：floor((7*photo+effect)/8)。
    // 两者都用"左移减自身"凑出系数（x<<2 - x = 3x，x<<3 - x = 7x），
    // 因此不占用 DSP；先加宽到 11bit 再移位，避免中间结果溢出丢位。
    function [23:0] blend;
        input [23:0] photo,effect;
        input quarter;
        reg [10:0] r,g,b;
        begin
            if(quarter) begin
                r=({3'd0,photo[23:16]}<<2)-{3'd0,photo[23:16]}+{3'd0,effect[23:16]};
                g=({3'd0,photo[15:8]}<<2)-{3'd0,photo[15:8]}+{3'd0,effect[15:8]};
                b=({3'd0,photo[7:0]}<<2)-{3'd0,photo[7:0]}+{3'd0,effect[7:0]};
                blend={r[9:2],g[9:2],b[9:2]};
            end else begin
                r=({3'd0,photo[23:16]}<<3)-{3'd0,photo[23:16]}+{3'd0,effect[23:16]};
                g=({3'd0,photo[15:8]}<<3)-{3'd0,photo[15:8]}+{3'd0,effect[15:8]};
                b=({3'd0,photo[7:0]}<<3)-{3'd0,photo[7:0]}+{3'd0,effect[7:0]};
                blend={r[10:3],g[10:3],b[10:3]};
            end
        end
    endfunction
    // ===== 逐像素决定面板内容（纯组合，流水线可选） =====
    // 默认所有标志位为 0，表示"这个像素不改颜色"；随后按 网格 → 零轴 → 填充 →
    // 辉光 → 波形线 → 音量柱 → 边框 → 标题条 的顺序依次覆盖，
    // 后面的判断覆盖前面的，形成固定的叠放优先级。
    // 颜色不是直接输出，而是作为 effect_color 交给 blend() 与底图按比例混合，
    // 只有 solid=1 的像素（波形线、峰值标记、标题条）才是纯色覆盖。
    reg [23:0] effect_color;
    reg quarter_mix,solid;
    always @* begin
        selected_sample=0;previous_sample=0;displacement=0;previous_displacement=0;
        sample_y=CENTER;previous_y=CENTER;trace_y=CENTER;amplitude=0;
        delta=0;interpolated_delta=0;
        distance=local_y>=CENTER ? local_y-CENTER : CENTER-local_y;
        level=display_peak>WAVE_HEIGHT-8 ? WAVE_HEIGHT-8 : display_peak;
        marker=held_peak>WAVE_HEIGHT-8 ? WAVE_HEIGHT-8 : held_peak;
        trace=0;glow=0;fill=0;grid=0;border=0;meter=0;
        effect_color=24'h142c4c;quarter_mix=0;solid=0;
        if(panel) begin
            // 边框：面板四边各 1 像素；网格：横向每 64 像素一条、纵向每 16 行一条。
            border=local_y==0 || local_y==WAVE_HEIGHT-1 || local_x==0 || local_x==WAVE_WIDTH+23;
            grid=local_x<WAVE_WIDTH && (local_x[5:0]==0 || local_y[3:0]==0);
            if(local_x<WAVE_WIDTH && display_valid) begin
                selected_sample=display_bank ? sample_bank1[sample_index] : sample_bank0[sample_index];
                previous_sample=display_bank ? sample_bank1[previous_index] : sample_bank0[previous_index];
                // 样本是 8bit 有符号，右移 1 位当作纵向偏移（满幅约占面板一半高度）；
                // 超界时钳到 DISP_MAX/DISP_MIN，保证波形不画到边框外；
                // silence_shift 的右移就是静音衰减：移位越多波形越贴零轴。
                displacement=$signed(selected_sample) >>> 1;
                previous_displacement=$signed(previous_sample) >>> 1;
                if(displacement>DISP_MAX) displacement=DISP_MAX;
                else if(displacement<DISP_MIN) displacement=DISP_MIN;
                if(previous_displacement>DISP_MAX) previous_displacement=DISP_MAX;
                else if(previous_displacement<DISP_MIN) previous_displacement=DISP_MIN;
                displacement=displacement >>> silence_shift;
                previous_displacement=previous_displacement >>> silence_shift;
                sample_y=CENTER-displacement;previous_y=CENTER-previous_displacement;
                // Eight-pixel linear interpolation uses three shift/add terms.
                // Sample spacing is fixed at eight pixels in the production panel.
                delta=$signed({1'b0,sample_y})-$signed({1'b0,previous_y});
                interpolated_delta=(local_x[0] ? {{3{delta[9]}},delta} : 13'sd0)+
                    (local_x[1] ? ({{3{delta[9]}},delta} <<< 1) : 13'sd0)+
                    (local_x[2] ? ({{3{delta[9]}},delta} <<< 2) : 13'sd0);
                trace_y=$signed({1'b0,previous_y})+(interpolated_delta >>> 3);
                // amplitude 是当前像素到零轴的距离，fill 表示"零轴与波形线之间"的填充区；
                // trace 是线本体（±1 像素），glow 是更宽的辉光（±3 像素）。
                amplitude=trace_y<CENTER ? CENTER-trace_y : trace_y-CENTER;
                fill=distance<=amplitude && local_x[2:0]!=7;
                trace=local_y>=trace_y-1 && local_y<=trace_y+1;
                glow=local_y>=trace_y-3 && local_y<=trace_y+3;
            end
            meter=local_x>=WAVE_WIDTH+8 && local_x<WAVE_WIDTH+18 &&
                local_y>=4 && local_y<WAVE_HEIGHT-4;
            if(grid) effect_color=24'h233747;
            if(local_x<WAVE_WIDTH && local_y==CENTER && local_x[2:0]<4) effect_color=24'h3c6675;
            if(fill) begin
                effect_color=distance>16 ? 24'h197b86 : distance>8 ? 24'h145361 : 24'h103b4d;
                quarter_mix=1;
            end
            if(glow) begin effect_color=24'h237f8a;quarter_mix=1;end
            if(trace) begin effect_color=local_y<CENTER ? 24'h70efff : 24'h42e6b5;solid=1;end
            if(meter) begin
                effect_color=24'h1b3442;
                if(local_y>=WAVE_HEIGHT-4-level && local_y[2:0]!=0) begin
                    effect_color=local_y<12 ? 24'hff7868 : local_y<24 ? 24'hffc669 : 24'h42e6b5;
                    quarter_mix=1;
                end
                if(marker!=0 && local_y==WAVE_HEIGHT-4-marker) begin effect_color=24'hfff1bf;solid=1;end
            end
            if(border) begin effect_color=24'h365468;quarter_mix=0;end
            if(local_y==0 && local_x>=8 && local_x<96) begin effect_color=24'h42e6b5;solid=1;end
        end
        color=solid ? effect_color : blend(rgb_in,effect_color,quarter_mix);
    end
    generate if(PIPELINE_OUTPUT) begin:g_output_stage
        reg [23:0] photo_q,effect_q;
        reg panel_q,quarter_q,solid_q;
        always @(posedge clk or negedge rst_n)
            if(!rst_n) begin photo_q<=0;effect_q<=0;panel_q<=0;quarter_q<=0;solid_q<=0;end
            else begin
                photo_q<=rgb_in;effect_q<=effect_color;panel_q<=panel;
                quarter_q<=quarter_mix;solid_q<=solid;
            end
        assign waveform_active=panel_q;
        assign rgb_out=panel_q ? (solid_q ? effect_q : blend(photo_q,effect_q,quarter_q)) : photo_q;
    end else begin:g_combinational
        assign waveform_active=panel;
        assign rgb_out=panel ? color : rgb_in;
    end endgenerate
endmodule
