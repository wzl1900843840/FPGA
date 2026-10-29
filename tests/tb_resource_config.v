`timescale 1ns/1ps
module tb_resource_config;
reg clk=0;always #5 clk=~clk;
reg rst=0,load=0,save=0,p0=0,p1=0;
reg [79:0] d0=0,d1=0;
reg [15:0] c0=0,c1=0;
reg [31:0] period=0;
reg [7:0] volume=0,mode=0;
wire ld,valid,slot,ready,target;
wire [31:0] av,ap,rv,rp;
wire [7:0] am,au,rm,ru;
wire [15:0] rc;
config_journal dut(.clk(clk),.rst_n(rst),.load_start(load),.slot0_present(p0),
 .slot0_version(d0[79:48]),.slot0_period(d0[47:16]),.slot0_volume(d0[15:8]),.slot0_mode(d0[7:0]),.slot0_crc(c0),
 .slot1_present(p1),.slot1_version(d1[79:48]),.slot1_period(d1[47:16]),.slot1_volume(d1[15:8]),.slot1_mode(d1[7:0]),.slot1_crc(c1),
 .load_done(ld),.config_valid(valid),.active_version(av),.active_period(ap),.active_volume(au),.active_mode(am),.active_slot(slot),
 .save_start(save),.save_period(period),.save_volume(volume),.save_mode(mode),.record_ready(ready),.target_slot(target),
 .record_version(rv),.record_period(rp),.record_volume(ru),.record_mode(rm),.record_crc(rc));
function [15:0] crc80;
 input [79:0] data;
 integer b;reg [15:0] c;
 begin c=16'hffff;for(b=79;b>=0;b=b-1)c=(c[15]^data[b]) ? (c<<1)^16'h1021 : c<<1;crc80=c;end
endfunction
integer n,timeout;reg good0,good1,expected_slot;reg [79:0] expected;
reg [31:0] delta;reg [79:0] original0,original1,save_data;
initial begin
 #12;rst=1;
 for(n=0;n<256;n=n+1)begin
  @(negedge clk);
  d0={$random,$random,$random};d1={$random,$random,$random};
  if(n<4)begin d0[79:48]=32'hfffffffe+n;d1[79:48]=d0[79:48]+1;end
  if(n==4)d1[79:48]=d0[79:48];
  p0=n[0];p1=n[1];c0=crc80(d0)^(n[2]?16'h1:16'h0);c1=crc80(d1)^(n[3]?16'h100:16'h0);
  good0=p0&&c0==crc80(d0);good1=p1&&c1==crc80(d1);
  delta=d1[79:48]-d0[79:48];
  expected_slot=good1&&(!good0||(d1[79:48]!=d0[79:48]&&!delta[31]));
  expected=expected_slot?d1:(good0?d0:80'd0);
  original0=d0;original1=d1;load=1;
  @(negedge clk);load=0;
  // Inputs may change after acceptance; the entire load must use its snapshot.
  d0=~original0;d1=~original1;c0=0;c1=0;p0=0;p1=0;
  timeout=0;while(!ld&&timeout<30)begin @(negedge clk);timeout=timeout+1;end
  if(!ld||valid!=(good0||good1)||slot!=expected_slot||{av,ap,au,am}!==expected)
   $fatal(1,"CRC load vector %0d mismatch timeout=%0d",n,timeout);
  @(negedge clk);if(ld)$fatal(1,"load_done not pulse");
  period=$random;volume=$random;mode=$random;
  save_data={av+32'd1,period,volume,mode};save=1;
  @(negedge clk);save=0;period=~period;volume=~volume;mode=~mode;
  timeout=0;while(!ready&&timeout<20)begin @(negedge clk);timeout=timeout+1;end
  if(!ready||{rv,rp,ru,rm}!==save_data||rc!==crc80(save_data)||target!==(valid?~slot:1'b0))
   $fatal(1,"CRC save vector %0d mismatch",n);
  @(negedge clk);if(ready)$fatal(1,"record_ready not pulse");
 end
 // Reset during CRC must cancel completion, then allow a clean new request.
 save=1;@(negedge clk);save=0;repeat(3)@(negedge clk);rst=0;
 @(negedge clk);rst=1;repeat(25)begin @(negedge clk);if(ld||ready)$fatal(1,"stale completion after reset");end
 $display("PASS resource config: 256 randomized load/save vectors, CRC compatibility, version wrap/tie, snapshots and reset cancellation");$finish;
end
initial begin #1000000;$fatal(1,"watchdog");end
endmodule
