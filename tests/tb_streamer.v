`timescale 1ns/1ps
module tb_streamer;
reg clk=0;always #5 clk=~clk;reg rst=0,start=0;
wire done,fv,req;wire[7:0]fb,err;wire[31:0]off,lba;
reg busy=0,sv=0,sd=0;reg[7:0]b=0;reg[8:0]bi=0;
fat32_file_streamer dut(clk,rst,start,32'd3,32'd700,8'd1,32'd1,32'd100,32'd200, ,done,fv,fb,off,err,req,lba,busy,sv,b,bi,sd,8'd0);
integer i,count=0,requests=0;reg[31:0]a;
always @(posedge clk)if(fv)begin
if(off!=count ||fb!==(count&255))$fatal(1,"file byte %d %d %d",count,off,fb);count=count+1;end
initial begin #12;rst=1;@(negedge clk);start=1;@(negedge clk);start=0;wait(done);#1;
if(err ||count!=700||requests!=4)$fatal(1,"finish %h count%d requests%d",err,count,requests);
$display("PASS streamer: fragmented 3->7 chain, 700-byte EOF, terminal FAT check");$finish;end
initial forever begin wait(req);a=lba;requests=requests+1;@(posedge clk);#1;busy=1;
if(a!=101 &&a!=105 &&a!=1)$fatal(1,"lba%d",a);
for(i=0;i<512;i=i+1)begin @(negedge clk);sv=1;bi=i;b=0;
if(a==1)begin if(i==12)b=7;if(i>=28&&i<=31)b=8'hff;end else b=i;end
@(negedge clk);sv=0;sd=1;@(negedge clk);sd=0;busy=0;end
initial begin #1000000;$fatal(1,"watchdog");end
endmodule
