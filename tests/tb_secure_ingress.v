`timescale 1ns/1ps
module tb_secure_ingress;
reg clk=0,rst_n=0,tick_ms=0,rx_valid=0,rx_framing_error=0;
reg [7:0] rx_data=0;
always #5 clk=~clk;
wire [7:0] parser_data;
wire parser_valid,status_valid,status_ok;
wire [31:0] session_id;
uart_secure_ingress_bram dut(.clk(clk),.rst_n(rst_n),.tick_ms(tick_ms),.rx_data(rx_data),
 .rx_valid(rx_valid),.rx_framing_error(rx_framing_error),.parser_data(parser_data),
 .parser_valid(parser_valid),.status_valid(status_valid),.status_ok(status_ok),.session_id(session_id));
string parsed[0:15];string partial="";integer parsed_count=0,status_count=0;
reg last_status=0;
always @(negedge clk) begin
 if(parser_valid) begin
  if(parser_data==13) begin parsed[parsed_count]=partial;parsed_count=parsed_count+1;partial="";end
  else partial={partial,parser_data};
 end
 if(status_valid) begin status_count=status_count+1;last_status=status_ok;end
end
task byte_in;input [7:0] c;begin
 @(negedge clk);rx_data=c;rx_valid=1;
 @(negedge clk);rx_valid=0;
end endtask
task text_in;input string s;integer k;begin for(k=0;k<s.len();k=k+1)byte_in(s[k]);end endtask
task finish_line;begin byte_in(13);repeat(55)@(negedge clk);end endtask
task line_in;input string s;begin text_in(s);finish_line;end endtask
task expect_status;input integer n;input ok;begin
 if(status_count!=n || last_status!==ok)$fatal(1,"status count=%0d last=%b expected %0d/%b",status_count,last_status,n,ok);
end endtask
initial begin
 #21;rst_n=1;repeat(5)@(negedge clk);
 line_in("ALERT=ON");expect_status(1,0);
 line_in("@1234ABCD:0001:FLOOR=F05,D=U,DO=C*EFF9");expect_status(2,0);
 line_in("@1234ABCD:0000:HELLO*9228");expect_status(3,1);
 if(session_id!==32'h1234abcd)$fatal(1,"HELLO session");
 line_in("@1234ABCD:0001:FLOOR=F05,D=U,DO=C*EFF9");
 if(parsed_count!=1 || parsed[0]!="FLOOR=F05,D=U,DO=C")$fatal(1,"floor replay %0d %s",parsed_count,parsed[0]);
 line_in("@1234ABCD:0001:FLOOR=F05,D=U,DO=C*EFF9");expect_status(4,1);
 if(parsed_count!=1)$fatal(1,"duplicate executed");
 line_in("@1234ABCD:0001:FLOOR=F06,D=U,DO=C*5E36");expect_status(5,0);
 line_in("@1234ABCD:0002:ALERT=ON*80FD");
 if(parsed_count!=2 || parsed[1]!="ALERT=ON")$fatal(1,"alert replay");
 line_in("@1234ABCD:0003:ACK=0001*DFBB");expect_status(6,0);
 line_in("@1234ABCD:0003:ACK=001*DFBA");expect_status(7,0);
 text_in("@1234ABCD:0003:ACK=");
 @(negedge clk);rx_framing_error=1;@(negedge clk);rx_framing_error=0;
 text_in("0001*DFBA");finish_line;expect_status(8,0);
 text_in("@1234ABCD:0003:");
 repeat(51)begin @(negedge clk);tick_ms=1;@(negedge clk);tick_ms=0;end
 text_in("ACK=0001*DFBA");finish_line;expect_status(9,0);
 line_in("@1234ABCD:0003:ACK=0001*DFBA");
 if(parsed_count!=3 || parsed[2]!="ACK=0001")$fatal(1,"valid ACK replay");
 line_in("@1234ABCD:0004:ELEV=F05*20EE");expect_status(10,0);
 line_in("@1234ABCD:0004:BRT=80*B7DB");expect_status(11,0);
 line_in("@1234ABCD:0000:HELLO*9228");expect_status(12,0);
 line_in("@1234ABCD:0005:SUB=OFF*BEFE");expect_status(13,0);
 line_in("@1234ABCD:0004:SUB=ON*BD82");
 if(parsed_count!=4 || parsed[3]!="SUB=ON")$fatal(1,"SUB replay");
 @(negedge clk);rst_n=0;repeat(4)@(negedge clk);rst_n=1;
 line_in("@1234ABCD:0005:SUB=OFF*BEFE");expect_status(14,0);
 if(parsed_count!=4)$fatal(1,"cross-reset write accepted");
 line_in("INFO?");expect_status(15,0);
 line_in("STAT?");expect_status(16,0);
 line_in("RESCUE?");
 if(parsed_count!=5 || parsed[4]!="RESCUE?")
  $fatal(1,"legacy read-only query replay");
 line_in("@1234ABCD:0001:FLOOR=F06,D=U,DO=C*EFF9");expect_status(17,0);
 line_in("@1234ABCD:0001:FLOOR=F05,D=U,DO=C*EFF");expect_status(18,0);
 text_in("@1234ABCD:0001:SUB=ABCDEFGHIJKLMNOPQRSTUVWX*0000");finish_line;expect_status(19,0);
 line_in("BOOT?");
 if(parsed_count!=6 || parsed[5]!="BOOT?")$fatal(1,"overflow poisoned next line");
 $display("PASS secure ingress: CRC, missing byte, framing, timeout, duplicate, conflict, command whitelist, ordering and reset quarantine");$finish;
end
initial begin #10000000;$fatal(1,"watchdog");end
endmodule
