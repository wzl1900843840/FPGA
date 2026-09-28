`timescale 1ns/1ps
module spi_sd_model(input wire cs,sclk,mosi,input wire bad_crc,output reg miso=1);
reg[7:0]shift=0,tx=255,command[0:5],response[0:519];
integer bitpos=0,pos=0,q=0,len=0,j,k,attempts=0;reg[15:0]crc;reg[7:0]rx;
always @(negedge cs)begin bitpos=0;pos=0;q=0;len=0;shift=0;tx=255;miso=1;end
always @(posedge cs)miso=1;
always @(posedge sclk)if(!cs)begin
shift={shift[6:0],mosi};
if(bitpos==7)begin bitpos=0;rx=shift;
if(len!=0)begin q=q+1;if(q>=len)begin len=0;tx=255;end else tx=response[q];end
else if(pos!=0 ||rx[7:6]==2'b01)begin
command[pos]=rx;pos=pos+1;
if(pos==6)begin pos=0;q=0;len=1;response[0]=255;
case(command[0]&8'h3f)
0:response[0]=1;
8:begin len=5;response[0]=1;response[1]=0;response[2]=0;response[3]=1;response[4]=8'haa;end
55:response[0]=1;
41:begin attempts=attempts+1;response[0]=attempts<2?1:0;end
58:begin len=5;response[0]=0;response[1]=8'hc0;response[2]=8'hff;response[3]=8'h80;response[4]=0;end
17:begin
if({command[1],command[2],command[3],command[4]}!=1234)$fatal(1,"CMD17 address");
len=516;response[0]=0;response[1]=8'hfe;crc=0;
for(j=0;j<512;j=j+1)begin response[j+2]=j;for(k=7;k>=0;k=k-1)crc=(crc<<1)^((crc[15]^response[j+2][k])?16'h1021:16'd0);end
response[514]=crc[15:8];response[515]=crc[7:0]^(bad_crc?8'h01:0);
end
default:$fatal(1,"unexpected SD command %d",command[0]&63);
endcase tx=response[0];end
end else tx=255;
end else bitpos=bitpos+1;
end
always @(negedge sclk)if(!cs)miso=tx[7-bitpos];
endmodule
