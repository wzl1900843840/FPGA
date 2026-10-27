`timescale 1ns/1ps
module tb_rescue_ack #(parameter integer BIT_CYCLES=8);
reg clk=0,rst=0,alarm=0,rxv=0;reg[7:0]rxd=0;always #5 clk=~clk;
wire ack,reply_valid,reply_last,reply_ready,tx,ov,oe;wire[7:0]reply_data,out_byte;
wire[15:0]ack_id,event_id;wire[1:0]comm;
reg[3:0]floor_tens=0,floor_ones=5;reg[1:0]dir=1,door=2;
reg [84:0] metrics={5'h1f,16'd101,16'd220,16'd830,16'd850,16'd1500};
subtitle_uart_controller #(.APPLIED_STATUS_INPUTS(1)) parser(.clk(clk),.rst_n(rst),
 .rx_data(rxd),.rx_valid(rxv),.rx_framing_error(1'b0),.service_ready(1'b1),
 .save_done(1'b0),.save_failed(1'b0),.request_dropped(1'b0),.live_text(96'd0),.live_length(6'd0),.live_enable(1'b0),
 .reply_valid(reply_valid),.reply_data(reply_data),.reply_last(reply_last),.reply_ready(reply_ready),
 .rescue_ack_valid(ack),.rescue_ack_id(ack_id),.rescue_event_id(event_id),.rescue_comm_state(comm),
 .applied_alert(alarm),.applied_floor_basement(1'b0),.applied_floor_tens(floor_tens),.applied_floor_ones(floor_ones),
 .applied_direction(dir),.applied_door(door),.boot_metrics(metrics));
uart_status_reporter #(.CLKS_PER_BIT(BIT_CYCLES),.ACK_TIMEOUT_CYCLES(BIT_CYCLES*1000)) report(.clk(clk),.rst_n(rst),.enable(1'b0),
 .media_id(2'd0),.volume(8'd0),.period_ms(32'd5000),.auto_enabled(1'b0),.switch_event(1'b0),
 .menu_event(1'b0),.menu_kind(2'd0),.error_code(8'd0),.bright_event(1'b0),.bright_value(8'd0),
 .alert_request(alarm),.alert_sources(2'd2),.floor_valid(1'b1),.floor_basement(1'b0),
 .floor_tens(floor_tens),.floor_ones(floor_ones),.direction(dir),.door(door),.rescue_overflow(),
 .reply_valid(reply_valid),.reply_data(reply_data),.reply_last(reply_last),.reply_ready(reply_ready),.uart_tx(tx),
 .rescue_ack_valid(ack),.rescue_ack_id(ack_id),.rescue_event_id(event_id),.rescue_comm_state(comm));
uart_rx_byte #(.CLKS_PER_BIT(BIT_CYCLES)) monitor(clk,rst,tx,out_byte,ov,oe);
string lines[0:63];string partial="";integer count=0,checked=0;
always @(negedge clk)if(ov)begin partial={partial,out_byte};if(out_byte==10)begin lines[count]=partial;count=count+1;partial="";end end
always @(negedge clk)if(oe)$fatal(1,"framing error");
task command;input string line;integer i;begin
 for(i=0;i<line.len();i=i+1)begin @(negedge clk);rxd=line[i];rxv=1;@(negedge clk);rxv=0;end
 @(negedge clk);rxd=13;rxv=1;@(negedge clk);rxv=0;repeat(3)@(negedge clk);
end endtask
task expect_line;input string expected;string full_line;begin full_line={expected,8'h0d,8'h0a};wait(count>checked);if(lines[checked]!=full_line)$fatal(1,"got[%s] expected[%s]",lines[checked],expected);checked=checked+1;end endtask
task settle_line;begin wait(report.state==0);repeat(8)@(negedge clk);end endtask
integer before_count;string snapshot;
initial begin
 #21;rst=1;repeat(10)@(negedge clk);
 command("BOOT?");wait(report.state==2);metrics=0;
 expect_line("BOOT,SD=0065,SC=00DC,P1=033E,TF=0352,P5=05DC,V=1F");settle_line;
 command("RESCUE?");expect_line("RESCUE,ID=0000,A=0,C=IDLE");
 settle_line;alarm=1;
 expect_line("RESCUE,ID=0001,A=1,F=05,D=U,DO=C,S=L,E=00");settle_line;
 if(comm!=1 || report.rescue_attempts!=1 || !report.ack_timer_running)$fatal(1,"first-send timer boundary");
 command("ACK=FFFF");if(comm!=1)$fatal(1,"wrong ACK accepted");
 command("ELEV?");wait(report.state==2);floor_ones=9;dir=2;door=1;
 command("ACK=0001");if(comm!=2 || !alarm)$fatal(1,"ACK lost while reply busy / cleared alarm");
 expect_line("ELEV=F05,D=U,DO=C,A=1");settle_line;
 command("RESCUE?");expect_line("RESCUE,ID=0001,A=1,C=ACKED");settle_line;
 command("ACK=0001");before_count=count;repeat(BIT_CYCLES*1500)@(negedge clk);
 if(comm!=2 || count!=before_count)$fatal(1,"duplicate ACK / cancelled retry");
 alarm=0;expect_line("RESCUE,ID=0002,A=0,F=09,D=D,DO=O,S=L,E=00");settle_line;
 command("ACK=0001");if(comm!=0)$fatal(1,"late ACK after clear");
 floor_ones=6;alarm=1;expect_line("RESCUE,ID=0003,A=1,F=06,D=D,DO=O,S=L,E=00");
 floor_ones=7;
 expect_line("RESCUE,ID=0003,A=1,F=06,D=D,DO=O,S=L,E=00");
 expect_line("RESCUE,ID=0003,A=1,F=06,D=D,DO=O,S=L,E=00");
 wait(comm==3);if(report.rescue_attempts!=3)$fatal(1,"retry count");settle_line;
 command("RESCUE?");expect_line("RESCUE,ID=0003,A=1,C=TIMEOUT");settle_line;
 alarm=0;expect_line("RESCUE,ID=0004,A=0,F=07,D=D,DO=O,S=L,E=00");settle_line;
 alarm=1;expect_line("RESCUE,ID=0005,A=1,F=07,D=D,DO=O,S=L,E=00");
 expect_line("RESCUE,ID=0005,A=1,F=07,D=D,DO=O,S=L,E=00");
 command("ACK=0005");if(comm!=2)$fatal(1,"delayed matching ACK");settle_line;
 alarm=0;expect_line("RESCUE,ID=0006,A=0,F=07,D=D,DO=O,S=L,E=00");settle_line;
 alarm=1;expect_line("RESCUE,ID=0007,A=1,F=07,D=D,DO=O,S=L,E=00");settle_line;
 alarm=0;expect_line("RESCUE,ID=0008,A=0,F=07,D=D,DO=O,S=L,E=00");settle_line;
 command("ACK=0007");before_count=count;repeat(BIT_CYCLES*3500)@(negedge clk);
 if(comm!=0 || count!=before_count)$fatal(1,"clear did not cancel retries");
 command("ACK=aBcD");if(ack_id!==16'habcd || comm!=0)$fatal(1,"hex ID width/case parsing");
 $display("PASS rescue ACK: timer after LF, three attempts, frozen retry/query, wrong/duplicate/late ACK, busy-reply ACK, delayed ACK and clear cancellation");$finish;
end
initial begin #(BIT_CYCLES*3000000);$fatal(1,"rescue ACK timeout");end
endmodule
