`timescale 1ns/1ps
module tb_photo_ui;
    reg clk=0;always #20 clk=~clk;
    reg rst=0,vs=1,hs=1,de=0,valid=0;
    reg [9:0] x=0,y=0;
    reg [23:0] rgb_in=0;
    reg [7:0] volume=0,brightness=255,contrast=128,error=0,detail=0;
    reg [31:0] period=5000;
    reg scale=0,auto_mode=0,loading=0,subtitle_on=1;
    reg [1:0] index=0;
    reg signed [15:0] sample=0;
    // IDs 80..88 exercise all nine existing Chinese short-phrase glyphs.
    wire [23:0] text_rgb,final_rgb;
    wire ink_active,wave_active;
    promax_text_overlay text_layer(.clk(clk),.rst_n(rst),.vsync(vs),.de(de),.rgb_in(rgb_in),
        .pixel_x(x),.pixel_y(y),.enable(1'b1),.show_info(1'b1),.subtitle_enable(subtitle_on),
        .subtitle_text(96'h202020888786858483828180),.subtitle_length(6'd9),
        .contrast(contrast),.brightness(brightness),.volume(volume),.period_ms(period),
        .auto_enabled(auto_mode),.source_scale_2x(scale),.active_index(index),
        .loading(loading),.error_code(error),.error_detail(detail),.rgb_out(text_rgb),.overlay_active(ink_active));
    reg [23:0] stage_rgb;
    reg [9:0] stage_x,stage_y;
    reg stage_hs,stage_vs,stage_de,stage_ink;
    always @(posedge clk or negedge rst)
        if(!rst) begin stage_rgb<=0;stage_x<=0;stage_y<=0;stage_hs<=1;stage_vs<=1;stage_de<=0;stage_ink<=0;end
        else begin stage_rgb<=text_rgb;stage_x<=x;stage_y<=y;stage_hs<=hs;stage_vs<=vs;stage_de<=de;stage_ink<=ink_active;end
    promax_audio_waveform #(.PIPELINE_OUTPUT(1)) wave_layer(.clk(clk),.rst_n(rst),.vsync(stage_vs),.de(stage_de),
        .rgb_in(stage_rgb),.pixel_x(stage_x),.enable(1'b1),.pcm_tap_valid(valid),
        .pcm_tap_left(sample),.rgb_out(final_rgb),.waveform_active(wave_active));
    reg [9:0] wave_x,wave_y;
    reg wave_hs,wave_vs,wave_de,wave_ink;
    always @(posedge clk or negedge rst)
        if(!rst) begin wave_x<=0;wave_y<=0;wave_hs<=1;wave_vs<=1;wave_de<=0;wave_ink<=0;end
        else begin
            wave_x<=stage_x;wave_y<=stage_y;wave_hs<=stage_hs;wave_vs<=stage_vs;
            wave_de<=stage_de;wave_ink<=stage_ink;
        end
    reg [23:0] photo[0:307199];
    reg [15:0] samples[0:63];
    reg [1023:0] background_file,sample_file,output_file;
    integer i,j,row,fd,changed=0,subtitle_passthrough=0;
    reg [55:0] previous_numbers;
    task frame;begin
        @(negedge clk);vs=0;de=0;repeat(3)@(negedge clk);vs=1;repeat(3)@(negedge clk);
    end endtask
    task check_number;
        input [31:0] p;
        input [7:0] v,b,c;
        input s;
        input [55:0] expected;
        begin
            previous_numbers=text_layer.numbers_frame;
            period=p;volume=v;brightness=b;contrast=c;scale=s;
            repeat(40)@(negedge clk);
            if(text_layer.numbers_frame!==previous_numbers)$fatal(1,"numeric tearing before frame");
            frame;
            if(text_layer.numbers_frame!==expected || text_layer.scale_frame!==s)
                $fatal(1,"actual numeric display %h != %h",text_layer.numbers_frame,expected);
        end
    endtask
    function [23:0] reference_blend;
        input [23:0] p,e;
        input integer weight;
        reg [7:0] r,g,b;
        begin
            r=(p[23:16]*weight+e[23:16])/(weight+1);
            g=(p[15:8]*weight+e[15:8])/(weight+1);
            b=(p[7:0]*weight+e[7:0])/(weight+1);
            reference_blend={r,g,b};
        end
    endfunction
    initial begin
        if(!$value$plusargs("BACKGROUND=%s",background_file) || !$value$plusargs("SAMPLES=%s",sample_file) ||
           !$value$plusargs("OUTPUT=%s",output_file))$fatal(1,"fixtures required");
        $readmemh(background_file,photo);$readmemh(sample_file,samples);
        if($value$plusargs("INDEX=%d",i)) index=i;
        #51;rst=1;repeat(40)@(negedge clk);frame;
        check_number(12345,111,222,99,1,{12'h099,12'h222,12'h111,20'h12345});
        if(text_layer.param_char(18)!="." || text_layer.param_char(16)!="1" || text_layer.param_char(21)!="5")
            $fatal(1,"actual period text");
        check_number(60000,255,0,255,0,{12'h255,12'h000,12'h255,20'h60000});
        check_number(1000,0,255,128,0,{12'h128,12'h255,12'h000,20'h01000});
        // Input changed while converting: the second snapshot must eventually win.
        period=59123;repeat(3)@(negedge clk);period=23456;volume=192;
        repeat(40)@(negedge clk);frame;
        if(text_layer.numbers_frame[31:0]!=={12'h192,20'h23456})$fatal(1,"lost concurrent numeric update");
        error=8'h86;detail=8'h42;frame;
        if(text_layer.status_char(16)!="8" || text_layer.status_char(17)!="6" ||
           text_layer.status_char(20)!="4" || text_layer.status_char(21)!="2")$fatal(1,"error/detail display");
        error=0;detail=0;auto_mode=1;
        if($test$plusargs("NO_SUBTITLE")) subtitle_on=0;
        if($test$plusargs("MUTED")) begin
            volume=0;for(i=0;i<64;i=i+1)samples[i]=0;
        end else volume=64;
        period=5000;repeat(40)@(negedge clk);frame;
        for(i=0;i<512;i=i+1)begin valid=1;sample=samples[i/8];@(negedge clk);end
        valid=0;frame;
        fd=$fopen(output_file,"wb");$fwrite(fd,"P6\n640 480\n255\n");
        for(row=0;row<480;row=row+1) begin
            for(j=0;j<800;j=j+1) begin
                x=j;y=row;de=j<640;hs=!(j>=656 && j<752);
                rgb_in=j<640 ? photo[row*640+j] : 24'd0;
                @(posedge clk);#1;
                if(stage_x!==x || stage_y!==y || stage_hs!==hs || stage_vs!==vs || stage_de!==de)
                    $fatal(1,"video bundle skew");
                if(wave_de) begin
                    if((^final_rgb)===1'bx)$fatal(1,"unknown UI pixel (%d,%d)",j,row);
                    if(wave_hs!==1 || wave_vs!==1 || wave_y!=row || wave_x!=j-1)$fatal(1,"wave pipeline companion skew");
                    if(!wave_ink && !wave_active && final_rgb!==photo[wave_y*640+wave_x])$fatal(1,"photo passthrough changed");
                    if(wave_x>=16 && wave_x<80 && wave_y>=16 && wave_y<57 && final_rgb!==photo[wave_y*640+wave_x])$fatal(1,"Logo occluded");
                    if(wave_y>=72 && wave_y<92 && wave_x>=300 && wave_x<632) begin
                        if(final_rgb!==photo[wave_y*640+wave_x])$fatal(1,"subtitle has opaque band");
                        subtitle_passthrough=subtitle_passthrough+1;
                    end
                    if(!subtitle_on && wave_y>=72 && wave_y<92 && final_rgb!==photo[wave_y*640+wave_x])
                        $fatal(1,"disabled subtitle left visible lettering");
                    if(wave_active && !wave_layer.g_output_stage.solid_q &&
                       final_rgb!==reference_blend(photo[wave_y*640+wave_x],wave_layer.g_output_stage.effect_q,wave_layer.g_output_stage.quarter_q ? 3 : 7))
                        $fatal(1,"blend overflow/weight mismatch");
                    if(final_rgb!==photo[wave_y*640+wave_x])changed=changed+1;
                    $fwrite(fd,"%c%c%c",final_rgb[23:16],final_rgb[15:8],final_rgb[7:0]);
                end
                @(negedge clk);
            end
        end
        $fclose(fd);
        if(changed<3000 || subtitle_passthrough!=6640)$fatal(1,"UI disappeared/bounds");
        $display("PASS photo UI: actual periods, frame commits, concurrent updates, error/detail, all Chinese glyphs, Logo clear, subtitle passthrough, exact blends, RGB/HS/VS/DE/XY alignment; pixels=307200");
        $finish;
    end
    initial begin #30000000;$fatal(1,"UI watchdog");end
endmodule
