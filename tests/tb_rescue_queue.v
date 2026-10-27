`timescale 1ns/1ps
module tb_rescue_queue;
reg clk=0,rst=0,alert=0;always #5 clk=~clk;
reg [1:0] source=2,dir=0,door=0;reg floor_valid=0,basement=0;
reg [3:0] tens=0,ones=0;reg [7:0] error=0;
wire tx,overflow,valid,framing;wire [7:0]ch;
uart_status_reporter #(.CLKS_PER_BIT(8)) dut(.clk(clk),.rst_n(rst),.enable(1'b0),
 .media_id(2'd0),.volume(8'd0),.period_ms(32'd5000),.auto_enabled(1'b0),
 .switch_event(1'b0),.menu_event(1'b0),.menu_kind(2'd0),.error_code(error),
 .bright_event(1'b0),.bright_value(8'd0),.alert_request(alert),.alert_sources(source),
 .floor_valid(floor_valid),.floor_basement(basement),.floor_tens(tens),.floor_ones(ones),
 .direction(dir),.door(door),.rescue_overflow(overflow),
 .reply_valid(1'b0),.reply_data(8'd0),.reply_last(1'b0),.reply_ready(),.uart_tx(tx));
uart_rx_byte #(.CLKS_PER_BIT(8)) monitor(clk,rst,tx,ch,valid,framing);
string lines[0:31];string partial="";integer count=0,n;
always @(negedge clk)begin
 if(framing)$fatal(1,"framing");
 if(valid)begin partial={partial,ch};if(ch==10)begin lines[count]=partial;count=count+1;partial="";end end
end
task edge_alert;input value;begin @(negedge clk);alert=value;repeat(6)@(negedge clk);end endtask
task wait_count;input integer target;integer timeout;begin
 timeout=0;while(count<target && timeout<60000)begin @(negedge clk);timeout=timeout+1;end
 if(count<target)$fatal(1,"queue stalled");repeat(10)@(negedge clk);
end endtask
initial begin
 #21;rst=1;repeat(10)@(negedge clk);
 edge_alert(1);
 floor_valid=1;tens=9;ones=9;dir=2;door=2;
 edge_alert(0);edge_alert(1);edge_alert(0);
 wait_count(4);
 if(lines[0]!="RESCUE,ID=0001,A=1,F=--,D=S,DO=M,S=L,E=00\015\012")$fatal(1,"snapshot [%s]",lines[0]);
 if(lines[1]!="RESCUE,ID=0002,A=0,F=99,D=D,DO=C,S=L,E=00\015\012")$fatal(1,"queued clear [%s]",lines[1]);
 if(lines[2]!="RESCUE,ID=0003,A=1,F=99,D=D,DO=C,S=L,E=00\015\012" ||
    lines[3]!="RESCUE,ID=0004,A=0,F=99,D=D,DO=C,S=L,E=00\015\012")$fatal(1,"FIFO order");
 if(overflow)$fatal(1,"false overflow");
 edge_alert(1);for(n=0;n<6;n=n+1)edge_alert(!alert);
 if(!overflow)$fatal(1,"missing overflow flag");
 wait_count(9);repeat(6000)@(negedge clk);
 if(count!=9)$fatal(1,"full FIFO count %0d",count);
 if(lines[8]!="RESCUE,ID=0009,A=1,F=99,D=D,DO=C,S=L,E=00\015\012")$fatal(1,"overflow damaged events [%s]",lines[8]);
 if(!overflow)$fatal(1,"overflow not sticky");
 @(negedge clk);rst=0;alert=0;repeat(5)@(negedge clk);rst=1;
 repeat(10)@(negedge clk);if(overflow)$fatal(1,"overflow reset");
 edge_alert(1);wait_count(10);
 if(lines[9]!="RESCUE,ID=0001,A=1,F=99,D=D,DO=C,S=L,E=00\015\012")$fatal(1,"reset/rearm");
 $display("PASS rescue queue: unknown floor, snapshots, short pulses, ordered FIFO, sticky overflow, reset");$finish;
end
initial begin #10000000;$fatal(1,"watchdog");end
endmodule
