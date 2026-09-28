`timescale 1ns/1ps
module tb_cdc;
reg sc=0,dc=0,rst=0,fs=0;always #5 sc=~sc;always #7 dc=~dc;
reg[31:0]src=0;wire[31:0]dst;
frame_config_cdc #(.WIDTH(32)) dut(sc,rst,src,dc,rst,fs,dst);
reg[31:0]last=0;reg oldfs;integer n=0;
always @(negedge dc)begin n=n+1;fs=n%19==0;end
always @(posedge dc)begin oldfs=fs;#1;if(rst&&dst!=last&&!oldfs)$fatal(1,"midframe change");last=dst;end
initial begin #17;rst=1;#11;src=32'haaaa5555;#23;src=32'h5555aaaa;#51;src=32'h12345678;
#2000;if(dst!==32'h12345678)$fatal(1,"latest update lost");$display("PASS CDC: stable bundle, busy coalescing, frame-only commit");$finish;end
endmodule
