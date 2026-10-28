`timescale 1ns/1ps
module tb_bmp_fullsize;
reg clk=0,rst=0,start=0,valid=0,last=0;always #5 clk=~clk;
reg [31:0] size=0,off=0;reg [7:0] b=0;
wire pv,commit,done,scaled;wire [23:0] rgb;wire [15:0] x,y;wire [7:0] error;
bmp24_decoder #(.ALLOW_2X_SOURCE(1)) d(.clk(clk),.rst_n(rst),.file_start(start),.file_size(size),
 .file_valid(valid),.file_byte(b),.file_byte_offset(off),.file_end(last),.upstream_error(8'd0),
 .pixel_valid(pv),.pixel_rgb(rgb),.pixel_x(x),.pixel_y(y),.frame_commit(commit),.bmp_done(done),
 .bmp_error(error),.source_scale_2x(scaled));
reg [7:0] header[0:53];integer factor=1,height,width,signed_h,orientation;
integer count=0,commits=0,i,j,sx,sy,ox,oy,channel;reg [23:0] expected;reg [7:0] er,eg,eb;
always @(negedge clk) begin
 if(pv)begin
   ox=count%640;oy=orientation ? count/640 : 479-count/640;
   er=(ox%128)+(factor==2);eg=(oy%128)+(factor==2);eb=(ox^oy)%128;expected={er,eg,eb};
   if(x!==ox || y!==oy || rgb!==expected)$fatal(1,"fullsize factor%0d orient%0d pixel%0d (%0d,%0d) got%h expected%h",factor,orientation,count,x,y,rgb,expected);
   count=count+1;
 end
 if(commit)commits=commits+1;
end
task run_image;input integer scale,topdown;begin
 factor=scale;orientation=topdown;width=640*factor;height=480*factor;
 signed_h=topdown ? -height : height;size=54+width*height*3;count=0;commits=0;
 for(i=0;i<54;i=i+1)header[i]=0;
 header[0]="B";header[1]="M";header[10]=54;header[14]=40;header[26]=1;header[28]=24;
 for(i=0;i<4;i=i+1)begin header[2+i]=(size>>(8*i))&255;header[18+i]=(width>>(8*i))&255;header[22+i]=(signed_h>>(8*i))&255;end
 @(negedge clk);start=1;@(negedge clk);start=0;
 for(j=0;j<size;j=j+1)begin
  @(negedge clk);valid=1;off=j;
  if(j<54)b=header[j];else begin
   sx=((j-54)/3)%width;sy=(j-54)/(3*width);if(!topdown)sy=height-1-sy;channel=(j-54)%3;
   case(channel)0:b=((sx/factor)^(sy/factor))%128;1:b=(sy/factor)%128+(sy%factor)*2;2:b=(sx/factor)%128+(sx%factor)*2;endcase
  end
  @(negedge clk);valid=0;
 end
 repeat(10)@(negedge clk);last=1;@(negedge clk);last=0;repeat(10)@(negedge clk);
 if(error || count!=307200 || commits!=1 || scaled!=(factor==2))$fatal(1,"fullsize end error%h count%0d commits%0d",error,count,commits);
 $display("CHECK fullsize %0dx%0d orientation%0d: 307200 pixels exact, one commit",width,height,topdown);
end endtask
initial begin #12;rst=1;run_image(1,0);run_image(1,1);run_image(2,0);run_image(2,1);
 $display("PASS bmp_fullsize: actual 640x480 and 1280x960, both BMP orientations, all 1228800 output pixels verified");$finish;end
endmodule
