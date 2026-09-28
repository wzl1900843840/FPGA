`timescale 1ns/1ps
module tb_bmp;
reg clk=0,rst=0,start=0,valid=0,last=0;always #5 clk=~clk;
reg[31:0] size=246,off=0;reg[7:0]b=0,up=0;
wire pv,commit,done,accepted,scaled;wire[23:0]rgb;wire[15:0]x,y;wire[7:0]error;
bmp24_decoder #(.EXPECTED_WIDTH(4),.EXPECTED_HEIGHT(4),.ALLOW_2X_SOURCE(1)) d(
.clk(clk),.rst_n(rst),.file_start(start),.file_size(size),.file_valid(valid),.file_byte(b),.file_byte_offset(off),
.file_end(last),.upstream_error(up),.header_accepted(accepted),.pixel_valid(pv),.pixel_rgb(rgb),.pixel_x(x),.pixel_y(y),
.frame_commit(commit),.bmp_done(done),.bmp_error(error),.source_scale_2x(scaled));
reg[7:0]data[0:245];integer i,j,px,py,c,count=0,commits=0;reg check=0;reg[23:0]expected;reg[7:0]er,eg;
always @(negedge clk)begin
if(pv)begin count=count+1;
er=20*x+5;eg=40*y+10;expected={er,eg,8'd40};
if(check && rgb!==expected)$fatal(1,"box2x (%d,%d) %h != %h",x,y,rgb,expected);
end
if(commit)commits=commits+1;
end
task header;input integer height;begin
for(i=0;i<246;i=i+1)data[i]=0;
data[0]="B";data[1]="M";data[2]=246;data[10]=54;data[14]=40;data[18]=8;
for(i=0;i<4;i=i+1)data[22+i]=(height>>(8*i))&255;
data[26]=1;data[28]=24;
for(i=54;i<246;i=i+1)begin px=((i-54)/3)%8;py=(i-54)/24;if(height>0)py=7-py;
case((i-54)%3)0:data[i]=40;1:data[i]=py*20;2:data[i]=px*10;endcase end
end endtask
task send;input integer length;begin
count=0;commits=0;@(negedge clk);start=1;@(negedge clk);start=0;
for(j=0;j<length;j=j+1)begin
@(negedge clk);valid=1;off=j;b=data[j];@(negedge clk);valid=0;repeat(3)@(negedge clk);
end
repeat(10)@(negedge clk);last=1;@(negedge clk);last=0;repeat(10)@(negedge clk);
end endtask
initial begin
#21;rst=1;check=1;header(8);send(246);if(error||count!=16||commits!=1||!scaled)$fatal(1,"2x bottom up %h %d %d",error,count,commits);
header(-8);send(246);if(error||count!=16||commits!=1)$fatal(1,"2x top down");
check=0;header(8);data[26]=2;send(246);if(error!=8'h33||commits)$fatal(1,"planes");
header(8);data[28]=32;send(246);if(error!=8'h34||commits)$fatal(1,"bpp");
header(8);data[30]=1;send(246);if(error!=8'h35||commits)$fatal(1,"compression");
header(8);data[10]=30;send(246);if(error!=8'h36||commits)$fatal(1,"offset");
header(8);send(200);if(error!=8'h37||commits)$fatal(1,"truncation %h",error);
$display("PASS bmp: exact 2x box filter in both orientations; invalid planes/bpp/compression/offset/truncation never commit");$finish;
end
endmodule
