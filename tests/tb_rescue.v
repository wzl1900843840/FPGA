`timescale 1ns/1ps
module tb_rescue #(parameter integer BIT_CYCLES=8);
reg clk=0,rst=0,rx=1,local_alert=0; always #5 clk=~clk;
wire [7:0] rx_byte,reply_byte,out_byte;
wire rx_valid,rx_error,tx,out_valid,out_error,reply_valid,reply_last,reply_ready;
wire elev_update,basement,elev_alert_update,alert_command,alert_value,command_value;
wire [7:0] floor_value; wire [1:0] direction,door;
reg uart_alert=0,floor_valid=0,floor_basement=0;
reg [3:0] floor_tens=0,floor_ones=0; reg [1:0] floor_direction=0,floor_door=0;
reg [7:0] error_code=0; wire overflow;
uart_rx_byte #(.CLKS_PER_BIT(BIT_CYCLES)) receiver(clk,rst,rx,rx_byte,rx_valid,rx_error);
subtitle_uart_controller parser(.clk(clk),.rst_n(rst),.rx_data(rx_byte),.rx_valid(rx_valid),
 .rx_framing_error(rx_error),.service_ready(1'b1),.save_done(1'b0),.save_failed(1'b0),
 .request_dropped(1'b0),.live_text(96'd0),.live_length(6'd0),.live_enable(1'b0),
 .cfg_update_valid(),.cfg_text(),.cfg_length(),.cfg_enable(),.save_request(),
 .elev_update_valid(elev_update),.elev_floor_value(floor_value),.elev_floor_basement(basement),
 .elev_direction(direction),.elev_door(door),.elev_alert_value(alert_value),
 .elev_alert_update_valid(elev_alert_update),.alert_command_valid(alert_command),
 .alert_command_value(command_value),.reply_valid(reply_valid),.reply_data(reply_byte),
 .reply_last(reply_last),.reply_ready(reply_ready));
// The same system-domain latching and OR arbitration used by top.
always @(posedge clk or negedge rst) begin
 if(!rst) begin
  uart_alert<=0;floor_valid<=0;floor_basement<=0;floor_tens<=0;floor_ones<=0;
  floor_direction<=0;floor_door<=0;
 end else begin
  if(elev_update) begin
   floor_valid<=1;floor_basement<=basement;floor_tens<=floor_value/10;
   floor_ones<=floor_value%10;floor_direction<=direction;floor_door<=door;
  end
  if(elev_alert_update) uart_alert<=alert_value;
  if(alert_command) uart_alert<=command_value;
 end
end
uart_status_reporter #(.CLKS_PER_BIT(BIT_CYCLES)) report(.clk(clk),.rst_n(rst),.enable(1'b0),
 .media_id(2'd0),.volume(8'd0),.period_ms(32'd5000),.auto_enabled(1'b0),
 .switch_event(1'b0),.menu_event(1'b0),.menu_kind(2'd0),.error_code(error_code),
 .bright_event(1'b0),.bright_value(8'd0),.alert_request(uart_alert || local_alert),
 .alert_sources({local_alert,uart_alert}),.floor_valid(floor_valid),
 .floor_basement(floor_basement),.floor_tens(floor_tens),.floor_ones(floor_ones),
 .direction(floor_direction),.door(floor_door),.rescue_overflow(overflow),
 .reply_valid(reply_valid),.reply_data(reply_byte),.reply_last(reply_last),
 .reply_ready(reply_ready),.uart_tx(tx));
uart_rx_byte #(.CLKS_PER_BIT(BIT_CYCLES)) monitor(clk,rst,tx,out_byte,out_valid,out_error);
string lines[0:63]; string partial=""; integer line_count=0,checked=0;
always @(negedge clk) begin
 if(out_error || rx_error)$fatal(1,"serial framing error");
 if(out_valid) begin
  partial={partial,out_byte};
  if(out_byte==10) begin lines[line_count]=partial;line_count=line_count+1;partial="";end
 end
end
task send_byte; input [7:0] ch; integer b; begin
 @(negedge clk);rx=0;repeat(BIT_CYCLES)@(negedge clk);
 for(b=0;b<8;b=b+1)begin rx=ch[b];repeat(BIT_CYCLES)@(negedge clk);end
 rx=1;repeat(BIT_CYCLES)@(negedge clk);
end endtask
task command;input string cmd;integer n;begin
 for(n=0;n<cmd.len();n=n+1)send_byte(cmd[n]);send_byte(13);send_byte(10);
end endtask
task wait_lines; input integer n;integer timeout;begin
 timeout=0;while(line_count<checked+n && timeout<BIT_CYCLES*4000)begin @(negedge clk);timeout=timeout+1;end
 if(line_count<checked+n)$fatal(1,"missing lines count=%0d checked=%0d partial=%s",line_count,checked,partial);
end endtask
task expect_one;input string wanted;begin
 wait_lines(1);if(lines[checked]!=wanted)$fatal(1,"got [%s], wanted [%s]",lines[checked],wanted);
 checked=checked+1;repeat(8)@(negedge clk);
end endtask
task expect_alarm_reply;input string wanted;begin
 wait_lines(2);
 if(!((lines[checked]=="OK\015\012" && lines[checked+1]==wanted) ||
      (lines[checked+1]=="OK\015\012" && lines[checked]==wanted)))
  $fatal(1,"reply/report corrupted [%s][%s] expected [%s]",lines[checked],lines[checked+1],wanted);
 checked=checked+2;repeat(8)@(negedge clk);
end endtask
initial begin
 #21;rst=1;repeat(10)@(negedge clk);
 command("ELEV=F05,D=U,DO=C,A=0");expect_one("OK\015\012");
 command("ALERT=ON");expect_alarm_reply("RESCUE,ID=0001,A=1,F=05,D=U,DO=C,S=U,E=00\015\012");
 command("ALERT=ON");expect_one("OK\015\012");
 repeat(6000)@(negedge clk);if(line_count!=checked)$fatal(1,"held alert repeated report");
 local_alert=1;repeat(5)@(negedge clk);
 command("ALERT=OFF");expect_one("OK\015\012");
 repeat(5000)@(negedge clk);if(line_count!=checked)$fatal(1,"OR-source handover false clear");
 local_alert=0;expect_one("RESCUE,ID=0002,A=0,F=05,D=U,DO=C,S=L,E=00\015\012");
 command("ELEV=FB1,D=S,DO=M,A=1");
 expect_alarm_reply("RESCUE,ID=0003,A=1,F=B1,D=S,DO=M,S=U,E=00\015\012");
 command("ELEV=FB1,D=S,DO=O,A=0");
 expect_alarm_reply("RESCUE,ID=0004,A=0,F=B1,D=S,DO=O,S=U,E=00\015\012");
 command("ELEV=BAD,D=X,DO=Z,A=2");expect_one("ERR ELEV\015\012");
 // A local alarm arriving inside the longest ELEV? reply must wait for its LF.
 command("ELEV?");
 wait(report.state==2);repeat(140)@(negedge clk);local_alert=1;
 expect_one("ELEV=FB1,D=S,DO=O,A=0\015\012");
 expect_one("RESCUE,ID=0005,A=1,F=B1,D=S,DO=O,S=L,E=00\015\012");
 local_alert=0;expect_one("RESCUE,ID=0006,A=0,F=B1,D=S,DO=O,S=L,E=00\015\012");
 error_code=8'h86;expect_one("ERR 86\015\012");
 local_alert=1;expect_one("RESCUE,ID=0007,A=1,F=B1,D=S,DO=O,S=L,E=86\015\012");
 local_alert=0;expect_one("RESCUE,ID=0008,A=0,F=B1,D=S,DO=O,S=L,E=86\015\012");
 if(overflow)$fatal(1,"unexpected overflow");
 $display("PASS rescue: commands/local alarm, OR arbitration, floor context, fault independence, recovery, atomic replies");$finish;
end
initial begin #(BIT_CYCLES*2000000);$fatal(1,"watchdog");end
endmodule
