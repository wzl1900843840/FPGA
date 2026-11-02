`timescale 1ns/1ps
module tb_font_pipeline;
reg clk=0,r=0,vs=1,de=0;always #5 clk=~clk;
reg [9:0] x=0,y=0;reg [23:0] bg=24'h203040;
reg [2:0] field=0;reg alarm=0,confirm=0,show_info=1,scale=1;
wire [23:0] reference_rgb,pipelined_rgb;
promax_text_overlay #(.MENU_ENABLE(1),.FONT_BRAM(0)) ref_osd(.clk(clk),.rst_n(r),.vsync(vs),.de(de),.rgb_in(bg),.pixel_x(x),.pixel_y(y),.enable(1'b1),.show_info(show_info),.subtitle_enable(1'b0),.subtitle_text(96'd0),.subtitle_length(6'd0),.contrast(8'd144),.brightness(8'd223),.volume(8'd64),.period_ms(32'd10000),.auto_enabled(1'b0),.source_scale_2x(scale),.active_index(3'd2),.loading(1'b0),.error_code(8'd0),.error_detail(8'd0),.elevator_status_valid(1'b0),.elevator_signal_lost(1'b1),.elevator_floor_basement(1'b0),.elevator_floor_tens(4'd0),.elevator_floor_ones(4'd0),.elevator_direction(2'd0),.elevator_door(2'd0),.elevator_alert(alarm),.rgb_out(reference_rgb),.rescue_event_id(16'd0),.rescue_comm_state(2'd0),.menu_field(field),.menu_diag(2'd0),.menu_confirm(confirm),.menu_dirty(1'b1),.menu_feedback(4'd0),.memory_volume(8'd192),.diagnostic_data(64'h0123456789abcdef));
promax_text_overlay #(.MENU_ENABLE(1),.FONT_BRAM(1)) ram_osd(.clk(clk),.rst_n(r),.vsync(vs),.de(de),.rgb_in(bg),.pixel_x(x),.pixel_y(y),.enable(1'b1),.show_info(show_info),.subtitle_enable(1'b0),.subtitle_text(96'd0),.subtitle_length(6'd0),.contrast(8'd144),.brightness(8'd223),.volume(8'd64),.period_ms(32'd10000),.auto_enabled(1'b0),.source_scale_2x(scale),.active_index(3'd2),.loading(1'b0),.error_code(8'd0),.error_detail(8'd0),.elevator_status_valid(1'b0),.elevator_signal_lost(1'b1),.elevator_floor_basement(1'b0),.elevator_floor_tens(4'd0),.elevator_floor_ones(4'd0),.elevator_direction(2'd0),.elevator_door(2'd0),.elevator_alert(alarm),.rgb_out(pipelined_rgb),.rescue_event_id(16'd0),.rescue_comm_state(2'd0),.menu_field(field),.menu_diag(2'd0),.menu_confirm(confirm),.menu_dirty(1'b1),.menu_feedback(4'd0),.memory_volume(8'd192),.diagnostic_data(64'h0123456789abcdef));
reg [23:0] expected;
integer xx,yy,mode,fd,addr,header_ink,timer_ink,resolution_ink;
task frame;begin
 @(negedge clk);de=0;vs=0;repeat(3)@(negedge clk);vs=1;repeat(3)@(negedge clk);
end endtask
initial begin
 #12;r=1;repeat(40)@(negedge clk);
 for(addr=0;addr<4096;addr=addr+1)begin
   if(addr>=2048)begin
     if(ram_osd.g_font_bram.font_rom[addr]!==ref_osd.chinese_glyph_row((addr>>4)-128,addr&15))$fatal(1,"CN ROM init %0d",addr);
   end else if(ram_osd.g_font_bram.font_rom[addr]!==ref_osd.ascii_font_word(addr>>4,addr&15))$fatal(1,"ASCII ROM init %0d",addr);
 end
 for(mode=0;mode<5;mode=mode+1)begin
   alarm=(mode==2);field=mode==1?5:0;confirm=(mode==1);show_info=(mode<3);scale=(mode!=4);
   repeat(40)@(negedge clk);frame;
   if(ram_osd.numbers_frame!=={12'h144,12'h223,12'h064,20'h10000} || ram_osd.memory_frame!==12'h192)
     $fatal(1,"paired BCD value/field order");
   if({ram_osd.status_char(18),ram_osd.status_char(19),ram_osd.status_char(20),ram_osd.status_char(21),
       ram_osd.status_char(22),ram_osd.status_char(23),ram_osd.status_char(24),ram_osd.status_char(25)}
       !== (scale ? "1280X960" : "640X480 "))$fatal(1,"source resolution label");
   header_ink=0;timer_ink=0;resolution_ink=0;
   if(mode==0)begin fd=$fopen("build_out/demo_menu_bram.ppm","w");$fwrite(fd,"P3\n640 480\n255\n");end
   if(mode==3)begin fd=$fopen("build_out/daily_header.ppm","w");$fwrite(fd,"P3\n640 480\n255\n");end
   if(mode==4)begin fd=$fopen("build_out/daily_header_640.ppm","w");$fwrite(fd,"P3\n640 480\n255\n");end
   for(yy=0;yy<480;yy=yy+1)begin
     for(xx=0;xx<640;xx=xx+1)begin
       @(negedge clk);x=xx;y=yy;de=1;bg=24'h203040+(xx&15);#1;expected=reference_rgb;
       @(posedge clk);#1;
       if(pipelined_rgb!==expected)$fatal(1,"font alignment mode%0d x%0d y%0d got%h expected%h",mode,x,y,pipelined_rgb,expected);
       if(mode>=3)begin
         if(yy>=24 && yy<40 && pipelined_rgb===24'heef6fa)begin
           if(xx>=96 && xx<368)header_ink=header_ink+1;
           if(xx>=384 && xx<512)resolution_ink=resolution_ink+1;
           if(xx>=552 && xx<632)timer_ink=timer_ink+1;
         end
         if(xx==32 && yy==76 && pipelined_rgb!==bg)$fatal(1,"menu card visible on daily page");
       end
       if(mode==0 || mode>=3)$fwrite(fd,"%0d %0d %0d\n",pipelined_rgb[23:16],pipelined_rgb[15:8],pipelined_rgb[7:0]);
     end
     @(negedge clk);de=0;repeat(5)@(negedge clk);
   end
   if(mode==0 || mode>=3)$fclose(fd);
   if(mode>=3 && (header_ink<100 || timer_ink<20 || resolution_ink<30))$fatal(1,"daily header/timer/resolution missing: %0d/%0d/%0d",header_ink,timer_ink,resolution_ink);
 end
 $display("PASS font_pipeline: 4096 ROM entries and 1536000 pixels match one-cycle alignment across menu, confirm, alarm and both daily source resolutions; header/timer/resolution visible");$finish;
end
initial begin #30000000;$fatal(1,"font timeout");end
endmodule
