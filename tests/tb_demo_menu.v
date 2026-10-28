`timescale 1ns/1ps
module tb_demo_menu;
reg clk=0,r=0,vs=1,de=0;always #5 clk=~clk;reg [9:0] x=0,y=0;reg [2:0] field=0;reg confirm=0;wire [23:0] rgb;integer xx,yy,fd,inks=0;
promax_text_overlay #(.MENU_ENABLE(1)) d(.clk(clk),.rst_n(r),.vsync(vs),.de(de),.rgb_in(24'h203040),.pixel_x(x),.pixel_y(y),.enable(1'b1),.show_info(1'b1),.subtitle_enable(1'b0),.subtitle_text(96'd0),.subtitle_length(6'd0),.contrast(8'd144),.brightness(8'd223),.volume(8'd64),.period_ms(32'd10000),.auto_enabled(1'b0),.source_scale_2x(1'b1),.active_index(3'd2),.loading(1'b0),.error_code(8'd0),.error_detail(8'd0),.elevator_status_valid(1'b0),.elevator_signal_lost(1'b1),.elevator_floor_basement(1'b0),.elevator_floor_tens(4'd0),.elevator_floor_ones(4'd0),.elevator_direction(2'd0),.elevator_door(2'd0),.elevator_alert(1'b0),.rgb_out(rgb),.rescue_event_id(16'd0),.rescue_comm_state(2'd0),.menu_field(field),.menu_diag(2'd0),.menu_confirm(confirm),.menu_dirty(1'b1),.menu_feedback(4'd0),.memory_volume(8'd192),.diagnostic_data(64'h0123456789abcdef));
initial begin #12;r=1;repeat(40)@(negedge clk);vs=0;repeat(3)@(negedge clk);vs=1;
 if(d.menu_char(1,14)!="2" || d.menu_char(1,15)!="2" || d.menu_char(1,16)!="3")$fatal(1,"brightness text");
 if(d.menu_char(2,14)!="1" || d.menu_char(3,15)!="6" || d.menu_char(4,14)!="1")$fatal(1,"numeric labels");
 for(xx=0;xx<33;xx=xx+1)if(d.menu_char(10,xx)!=" ")$fatal(1,"secondary footer remains");
 if(d.menu_char(11,2)!="+" || d.glyph_row("+",3)!=31)$fatal(1,"save chord plus missing");
 for(xx=1;xx<=6;xx=xx+1)if(d.menu_char(xx,0)<128)$fatal(1,"missing Chinese field");
 fd=$fopen("build_out/demo_menu.ppm","w");$fwrite(fd,"P3\n640 480\n255\n");
 for(yy=0;yy<480;yy=yy+1)begin for(xx=0;xx<640;xx=xx+1)begin @(negedge clk);x=xx;y=yy;de=1;#1;if(^rgb===1'bx)$fatal(1,"unknown pixel x%0d y%0d",x,y);$fwrite(fd,"%0d %0d %0d\n",rgb[23:16],rgb[15:8],rgb[7:0]);if(d.ink)inks=inks+1;end @(negedge clk);de=0;end
 $fclose(fd);if(inks<3000)$fatal(1,"menu empty");de=1;
 for(field=0;field<6;field=field+1)begin
   x=45;y=125+field*32;#1;if(rgb!=24'hffdc40)$fatal(1,"selection position");
   x=80;y=150+field*32;#1;if(rgb!=24'h30495c)$fatal(1,"selection padding");
 end
 field=5;confirm=1;#1;if(d.menu_char(6,14)<128)$fatal(1,"confirm missing");
 $display("PASS demo menu: six aligned Chinese fields, spaced rows, removed footer, save chord and 307200 known RGB pixels");$finish;end
initial begin #10000000;$fatal(1,"menu timeout");end
endmodule
