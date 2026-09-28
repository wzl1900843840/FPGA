`timescale 1ns/1ps
module tb_wav;
reg wc=0,rc=0;always #5 wc=~wc;always #7 rc=~rc;
reg rst=0,play=0,busy=0,sv=0,done=0,tick=0,ready=0;reg [7:0] sb=0;reg [8:0]bi=0;
wire req,valid,active,ended,low;wire [31:0]lba,counter;wire signed[15:0]sample;
wav_stream_player #(.ADDR_WIDTH(9)) dut(wc,rst,play,32'd100,32'd10,req,lba,busy,sv,sb,bi,done,8'd0,rc,rst,tick,sample,valid,ready,counter,active,ended,low);
integer sectors=0,i,n,cycles=0,received=0;reg stalled=0;reg[15:0]held;
initial begin #30;rst=1;play=1;
 for(sectors=0;sectors<10;sectors=sectors+1)begin
  wait(req);if(lba!=100+sectors)$fatal(1,"lba got %d sector %d",lba,sectors);@(posedge wc);#1;busy=1;@(negedge wc);
  for(i=0;i<512;i=i+1)begin n=sectors*256+i/2+1;sv=1;bi=i;sb=i%2?n>>8:n;@(negedge wc);end
  sv=0;done=1;@(negedge wc);done=0;busy=0;
 end
 wait(ended);if(received!=2560 ||counter!=2560)$fatal(1,"tail count %d",received);
 $display("PASS wav: ten sectors, ring wraps, LE pairing, backpressure, tail drain");$finish;
end
always @(negedge rc)begin cycles=cycles+1;tick=cycles%5==0;ready=cycles%17>5;end
always @(posedge rc)if(rst)begin
 if(stalled && (!valid ||sample!==held))$fatal(1,"unstable valid/ready");
 stalled=valid && !ready;held=sample;
 if(valid && ready && sample!=0)begin received=received+1;if(sample!==received)$fatal(1,"sample got%d exp%d",sample,received);end
end
initial begin #10000000;$fatal(1,"watchdog");end
endmodule
