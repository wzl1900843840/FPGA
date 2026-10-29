`timescale 1ns/1ps
module tb_resource_uart;
reg clk=0,rst=1;
uart_status_reporter dut(.clk(clk),.rst_n(rst));
uart_status_reporter_baseline reference(.clk(clk),.rst_n(rst));
integer n,k,i,count=0;
reg [7:0] expected,actual;
initial begin
 for(n=0;n<128;n=n+1)begin
  dut.pic_id_q=$random;dut.pic_auto_q=$random;dut.val8_q=$random;dut.val32_q=$random;
  dut.rescue_snapshot={$random,$random};
  reference.pic_id_q=dut.pic_id_q;reference.pic_auto_q=dut.pic_auto_q;
  reference.val8_q=dut.val8_q;reference.val32_q=dut.val32_q;reference.rescue_snapshot=dut.rescue_snapshot;
  for(k=0;k<7;k=k+1)begin
   dut.kind_q=k;reference.kind_q=k;
   for(i=0;i<64;i=i+1)begin
    dut.send_index=i;reference.send_index=i;#1;
    actual=dut.msg_char(k,i);expected=reference.msg_char(k,i);
    if(actual!==expected)$fatal(1,"UART byte mismatch vector=%0d kind=%0d idx=%0d actual=%h expected=%h",n,k,i,actual,expected);
    count=count+1;
   end
  end
 end
 $display("PASS resource UART: %0d report bytes exactly match I baseline across every message kind/index",count);$finish;
end
endmodule
