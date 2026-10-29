`timescale 1ns/1ps
module tb_emergency_osd;
reg clk=0,rst=0,vs=1,alarm=0;always #20 clk=~clk;
reg[1:0]comm=0;reg scale=0;reg[9:0]x=0,y=0;wire[23:0]rgb;wire active;
promax_text_overlay d(.clk(clk),.rst_n(rst),.vsync(vs),.de(1'b1),.rgb_in(24'h203040),
 .pixel_x(x),.pixel_y(y),.enable(1'b1),.show_info(1'b0),.subtitle_enable(1'b0),.subtitle_text(96'd0),.subtitle_length(6'd0),
 .contrast(8'd128),.brightness(8'd255),.volume(8'd0),.period_ms(32'd5000),.auto_enabled(1'b1),
 .source_scale_2x(scale),.active_index(3'd0),.loading(1'b0),.error_code(8'h83),.error_detail(8'h10),
 .elevator_status_valid(1'b1),.elevator_signal_lost(1'b0),.elevator_floor_basement(1'b0),
 .elevator_floor_tens(4'd0),.elevator_floor_ones(4'd5),.elevator_direction(2'd1),.elevator_door(2'd2),
 .elevator_alert(alarm),.rgb_out(rgb),.overlay_active(active),.rescue_event_id(16'h1a2b),.rescue_comm_state(comm));
task frame;begin vs=1;repeat(3)@(negedge clk);vs=0;repeat(3)@(negedge clk);vs=1;end endtask
integer i,j,k,fd,ink_count,status_ink,hint_ink,id_ink;
reg[1023:0]path;
task render;input integer state_id;begin
 $sformat(path,"tests/results/emergency_osd_%0d.ppm",state_id);fd=$fopen(path,"w");
 $fwrite(fd,"P3\n640 480\n255\n");ink_count=0;status_ink=0;hint_ink=0;id_ink=0;
 for(j=0;j<480;j=j+1)for(k=0;k<640;k=k+1)begin
  x=k;y=j;#1;$fwrite(fd,"%0d %0d %0d\n",rgb[23:16],rgb[15:8],rgb[7:0]);
  if(active && j>=104 && j<169)$fatal(1,"emergency text remains over background instructions x%0d y%0d",k,j);
  if(active && j>=340 && j<405)begin
   if(k<144 || k>288 || j>402)$fatal(1,"emergency text outside blank area x%0d y%0d",k,j);
   if(rgb!==24'h244536 && rgb!==24'hfffdf3)$fatal(1,"emergency contrast color");
   ink_count=ink_count+1;
   if(j<359)status_ink=status_ink+1;
   else if(j>=364 && j<383)hint_ink=hint_ink+1;
   else if(j>=388)id_ink=id_ink+1;
  end
 end
 $fclose(fd);
 if(ink_count<200)$fatal(1,"no emergency glyphs in state %0d",state_id);
 if(status_ink<100 || id_ink<30)$fatal(1,"missing status or event ID in state %0d",state_id);
 if(alarm && hint_ink<100)$fatal(1,"missing calm hint in state %0d",state_id);
 if(!alarm && hint_ink!=0)$fatal(1,"calm hint remains after clear");
end endtask
initial begin
 #61;rst=1;frame;
 alarm=1;comm=1;frame;
 if(d.rescue_status_char(0)!==8'h89 || d.rescue_status_char(3)!==8'h8c)$fatal(1,"WAIT label");render(1);
 comm=2;scale=1;#1;if(d.rescue_status_char(0)!==8'h89)$fatal(1,"midframe changed");frame;
 if(d.rescue_status_char(0)!==8'h8d || d.rescue_status_char(4)!==8'h91)$fatal(1,"ACK label");render(2);
 comm=3;frame;if(d.rescue_status_char(4)!==8'h96)$fatal(1,"TIMEOUT label");render(3);
 alarm=0;comm=0;frame;if(d.clear_frames!=120 || d.rescue_status_char(3)!==8'h99)$fatal(1,"clear label");render(0);
 for(i=0;i<120;i=i+1)frame;
 if(d.clear_frames!=0)$fatal(1,"clear text never expires");
 for(i=9;i<31;i=i+1)begin ink_count=0;for(j=0;j<16;j=j+1)ink_count=ink_count+($countones(d.chinese_glyph_row(i,j)));if(ink_count<20)$fatal(1,"empty glyph %0d",i);end
 $display("PASS emergency OSD: WAIT/ACKED/TIMEOUT/clear in lower blank area, no old-position overlay, both source scales, frame snapshot, status/hint/ID");$finish;
end
endmodule
