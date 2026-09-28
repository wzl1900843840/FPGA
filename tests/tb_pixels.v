`timescale 1ns/1ps
module tb_pixels;
reg clk=0; always #5 clk=~clk;
reg rst_n=0,de=0; reg [23:0] rgb;reg [7:0] b=255,c=128;
wire od;wire [23:0] out;
brightness_contrast_adjust dut(clk,rst_n,de,rgb,b,c,od,out);
integer i,j,k,v,expectation;
function integer model;
input integer v,b,c;
integer a;
begin a=b==255?v:(v*b)/256; a=((a-128)*c)>>>7; a=a+128;
model=a<0?0:a>255?255:a;end
endfunction
initial begin
 #12;rst_n=1;de=1;
 for(j=0;j<5;j=j+1) for(k=0;k<5;k=k+1) for(i=0;i<256;i=i+1) begin
  @(negedge clk);b=j==4?255:j*64;c=k==4?255:k*64;rgb={i[7:0],i[7:0],i[7:0]};
  @(posedge clk);#1;expectation=model(i,b,c);
  if(!od || out!=={expectation[7:0],expectation[7:0],expectation[7:0]}) $fatal(1,"RGB %d b%dc%d got%h exp%d",i,b,c,out,expectation);
 end
 @(negedge clk);de=0;@(posedge clk);#1;if(od || out!=0)$fatal(1,"blank");
 $display("PASS pixels: 6400 saturation/identity vectors and blanking");$finish;
end
endmodule
