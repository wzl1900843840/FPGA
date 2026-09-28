`timescale 1ns/1ps
// Behavioral model of the board W25X64 command subset. Enforces the two
// configuration sectors; the test never accesses a real programmer or device.
module spi_flash_model(input wire clk,cs,sclk,mosi,output reg miso=1);
reg[7:0]mem[0:8191];reg[7:0]cmd=0,shift=0,tx=255;reg[23:0]addr=0;
integer bits=0,bytes=0,k,wip=0,writes=0;reg wel=0;reg[7:0]rx;
initial for(k=0;k<8192;k=k+1)mem[k]=255;
always @(posedge clk) if(wip>0)wip=wip-1;
always @(negedge cs)begin bits=0;bytes=0;cmd=0;shift=0;tx=255;miso=1;addr=0;end
always @(posedge sclk)if(!cs)begin
shift={shift[6:0],mosi};
if(bits==7)begin
rx=shift;bits=0;bytes=bytes+1;
if(bytes==1)begin cmd=rx;case(rx)8'h9f:tx=8'hef;8'h05:tx={6'd0,wel,wip!=0};default:tx=255;endcase end
else case(cmd)
8'h9f:case(bytes)2:tx=8'h30;3:tx=8'h17;default:tx=255;endcase
8'h05:tx={6'd0,wel,wip!=0};
8'h03,8'h02,8'h20:begin
if(bytes<=4)begin addr={addr[15:0],rx};if(bytes==4)begin
if(addr<24'h7fe000 ||addr>=24'h800000)$fatal(1,"Flash outside configuration slots %h",addr);
if(cmd==3)tx=mem[addr&8191];end end
else if(cmd==3)begin addr=addr+1;tx=mem[addr&8191];end
else if(cmd==2)begin if(!wel||wip!=0)$fatal(1,"program without WEL");mem[addr&8191]=mem[addr&8191]&rx;addr=addr+1;end
end
8'h35,8'h15:$fatal(1,"unsupported W25X64 status command");
default:tx=255;
endcase
end else bits=bits+1;
end
always @(negedge sclk)if(!cs)miso=tx[7-bits];
always @(posedge cs)begin miso=1;
case(cmd)
8'h06:if(wip==0)wel=1;
8'h20:begin if(!wel||wip!=0)$fatal(1,"erase without WEL");for(k=0;k<4096;k=k+1)mem[(addr&4096)+k]=255;wel=0;wip=500;end
8'h02:begin wel=0;wip=500;writes=writes+1;end
endcase end
endmodule
