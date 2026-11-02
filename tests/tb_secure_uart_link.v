`timescale 1ns/1ps
module tb_secure_uart_link;
reg clk=0,rst_n=0,rx_valid=0,rx_error=0;
reg [7:0] rx_data=0;
always #5 clk=~clk;
wire [7:0] parser_data;wire parser_valid,status_valid,status_ok;
wire [31:0] session_id;
uart_secure_ingress_bram ingress(.clk(clk),.rst_n(rst_n),.tick_ms(1'b0),
 .rx_data(rx_data),.rx_valid(rx_valid),.rx_framing_error(rx_error),
 .parser_data(parser_data),.parser_valid(parser_valid),.status_valid(status_valid),
 .status_ok(status_ok),.session_id(session_id));
wire elev_update_valid,alert_command_valid,alert_command_value;
wire elev_alert_update_valid,rescue_ack_valid,cfg_update_valid;
wire [7:0] elev_floor_value;wire elev_floor_basement;
wire [3:0] elev_floor_tens,elev_floor_ones;
wire [1:0] elev_direction,elev_door;
wire [15:0] rescue_ack_id;
subtitle_uart_controller #(.APPLIED_STATUS_INPUTS(1),.MAX_LINE(18),
 .ENABLE_LEGACY_ELEV(0)) parser(.clk(clk),.rst_n(rst_n),
 .rx_data(parser_data),.rx_valid(parser_valid),.rx_framing_error(1'b0),
 .secure_status_valid(status_valid),.secure_status_ok(status_ok),
 .service_ready(1'b1),.save_done(1'b0),.save_failed(1'b0),.request_dropped(1'b0),
 .live_text(96'd0),.live_length(6'd0),.live_enable(1'b0),
 .cfg_update_valid(cfg_update_valid),.elev_update_valid(elev_update_valid),
 .elev_floor_value(elev_floor_value),.elev_floor_tens(elev_floor_tens),
 .elev_floor_ones(elev_floor_ones),.elev_floor_basement(elev_floor_basement),
 .elev_direction(elev_direction),.elev_door(elev_door),
 .elev_alert_update_valid(elev_alert_update_valid),
 .alert_command_valid(alert_command_valid),.alert_command_value(alert_command_value),
 .reply_ready(1'b1),.rescue_ack_valid(rescue_ack_valid),.rescue_ack_id(rescue_ack_id),
 .rescue_event_id(16'h0001),.rescue_comm_state(2'd1),.applied_alert(1'b0),
 .applied_floor_basement(1'b0),.applied_floor_tens(4'd0),.applied_floor_ones(4'd0),
 .applied_direction(2'd0),.applied_door(2'd0),.boot_metrics(85'd0));
integer floors=0,alerts=0,acks=0;
always @(negedge clk)begin
 if(elev_update_valid)begin
  floors=floors+1;
  if(elev_floor_value!=5 || elev_floor_tens!=0 || elev_floor_ones!=5 ||
     elev_floor_basement || elev_direction!=1 || elev_door!=2)
   $fatal(1,"floor payload incorrect");
 end
 if(elev_alert_update_valid)$fatal(1,"floor changed remote alarm");
 if(alert_command_valid)begin
  alerts=alerts+1;
  if(!alert_command_value)$fatal(1,"alert value");
 end
 if(rescue_ack_valid)begin
  acks=acks+1;
  if(rescue_ack_id!=16'h0001)$fatal(1,"ACK id");
 end
end
task byte_in;input [7:0] c;begin
 @(negedge clk);rx_data=c;rx_valid=1;
 @(negedge clk);rx_valid=0;
end endtask
task line_in;input string s;integer k;begin
 for(k=0;k<s.len();k=k+1)byte_in(s[k]);
 byte_in(13);repeat(80)@(negedge clk);
end endtask
initial begin
 #21;rst_n=1;
 line_in("ALERT=ON");
 if(alerts!=0)$fatal(1,"legacy write accepted");
 line_in("@1234ABCD:0000:HELLO*9228");
 line_in("@1234ABCD:0001:FLOOR=F05,D=U,DO=C*EFF9");
 if(floors!=1 || alerts!=0)$fatal(1,"floor integration");
 line_in("@1234ABCD:0002:ALERT=ON*80FD");
 line_in("@1234ABCD:0002:ALERT=ON*80FD");
 if(alerts!=1)$fatal(1,"duplicate alert executed");
 line_in("@1234ABCD:0003:ACK=0001*DFBB");
 if(acks!=0)$fatal(1,"bad CRC ACK accepted");
 line_in("@1234ABCD:0003:ACK=0001*DFBA");
 if(acks!=1)$fatal(1,"valid ACK not forwarded");
 $display("PASS secure UART link: HELLO, floor, independent alert, duplicate, CRC and ACK through parser");$finish;
end
initial begin #20000000;$fatal(1,"watchdog");end
endmodule
