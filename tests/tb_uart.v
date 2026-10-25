`timescale 1ns/1ps
module tb_uart;
reg clk=0,rst=0,rx=1;always #5 clk=~clk;
wire[7:0]byte_in,reply_byte,byte_out;wire valid,framing,tx,ov,oe,update,save,reply_valid,reply_last,reply_ready;
wire elev_update,elev_basement,elev_alert_update,alert_command;
wire [7:0]elev_floor;wire [1:0]elev_direction,elev_door;wire elev_alert_value,alert_command_value;
reg[95:0]live_text=0;reg[5:0]live_len=0;reg live_en=1;
wire[95:0]text;wire[5:0]len;wire en;
reg alert_seen=0;reg alert_seen_value=0;
uart_rx_byte #(.CLKS_PER_BIT(8)) receiver(clk,rst,rx,byte_in,valid,framing);
subtitle_uart_controller parser(.clk(clk),.rst_n(rst),.rx_data(byte_in),.rx_valid(valid),.rx_framing_error(framing),
.service_ready(1'b1),.save_done(1'b0),.save_failed(save),.request_dropped(1'b0),.live_text(live_text),.live_length(live_len),.live_enable(live_en),
.cfg_update_valid(update),.cfg_text(text),.cfg_length(len),.cfg_enable(en),.save_request(save),
.elev_update_valid(elev_update),.elev_floor_value(elev_floor),.elev_floor_basement(elev_basement),
.elev_direction(elev_direction),.elev_door(elev_door),.elev_alert_value(elev_alert_value),
.elev_alert_update_valid(elev_alert_update),.alert_command_valid(alert_command),.alert_command_value(alert_command_value),
.reply_valid(reply_valid),.reply_data(reply_byte),.reply_last(reply_last),.reply_ready(reply_ready));
always @(posedge clk)if(update)begin live_text<=text;live_len<=len;live_en<=en;end
always @(posedge clk)if(alert_command)begin alert_seen<=1'b1;alert_seen_value<=alert_command_value;end
uart_status_reporter #(.CLKS_PER_BIT(8)) report(.clk(clk),.rst_n(rst),.enable(1'b0),.media_id(2'd0),.volume(8'd255),.period_ms(32'd5000),
.auto_enabled(1'b0),.switch_event(1'b0),.menu_event(1'b0),.menu_kind(2'd0),.error_code(8'd0),.bright_event(1'b0),.bright_value(8'd255),
.reply_valid(reply_valid),.reply_data(reply_byte),.reply_last(reply_last),.reply_ready(reply_ready),.uart_tx(tx));
uart_rx_byte #(.CLKS_PER_BIT(8)) monitor(clk,rst,tx,byte_out,ov,oe);
string response="";
always @(negedge clk)begin if(oe||framing)$fatal(1,"UART framing");if(ov)begin response={response,byte_out};end end
task send_byte;input[7:0]ch;integer bitno;begin
@(negedge clk);rx=0;repeat(8)@(negedge clk);
for(bitno=0;bitno<8;bitno=bitno+1)begin rx=ch[bitno];repeat(8)@(negedge clk);end
rx=1;repeat(8)@(negedge clk);
end endtask
task command;input string line;integer i;begin
response="";for(i=0;i<line.len();i=i+1)send_byte(line[i]);send_byte(13);send_byte(10);
repeat(6000)@(negedge clk);
end endtask
initial begin
#21;rst=1;command("SUB=HELLO");
if(live_len!=5 ||live_text[39:0]!=40'h4f4c4c4548 ||response!="OK\015\012")$fatal(1,"set reply [%s] len%d",response,live_len);
command("SUB?");if(response!="SUB=1:HELLO\015\012")$fatal(1,"query reply [%s]",response);
command("SUB=OFF");if(live_en)$fatal(1,"off reply [%s]",response);
command("SUB=ON");if(!live_en)$fatal(1,"on reply [%s]",response);
command("SUB=ABCDEFGHIJKLM");
if(live_len!=5)$fatal(1,"long changed text");
command("SUB=CN");if(live_len!=4 || live_text[31:0]!=32'h83828180)$fatal(1,"neutral Chinese phrase");
command("SUB=照片音乐");if(live_len!=4 || response!="OK\015\012")$fatal(1,"UTF8 Chinese phrase");
command("SUB=米醋电子工作室忧郁");if(response!="ERR\015\012" || live_len!=4)$fatal(1,"removed signature alias");
command("ELEV=F05,D=U,DO=C,A=0");
if(elev_floor!=5 || elev_basement || elev_direction!=2'd1 || elev_door!=2'd2 || elev_alert_value || response!="OK\015\012")
    $fatal(1,"elevator status parse [%s] floor=%d dir=%d door=%d",response,elev_floor,elev_direction,elev_door);
command("ELEV?");
if(response!="ELEV=F05,D=U,DO=C,A=0\015\012")$fatal(1,"elevator query [%s]",response);
command("ELEV=FB1,D=S,DO=M,A=1");
if(elev_floor!=1 || !elev_basement || elev_direction!=2'd0 || elev_door!=2'd0 || !elev_alert_value)
    $fatal(1,"basement elevator parse [%s]",response);
command("ALERT=ON");
if(!alert_seen || !alert_seen_value || response!="OK\015\012")$fatal(1,"alert on [%s]",response);
alert_seen=0;alert_seen_value=1;
command("ALERT=OFF");
if(!alert_seen || alert_seen_value || response!="OK\015\012")$fatal(1,"alert off [%s]",response);
command("ELEV=BAD,D=X,DO=Z,A=2");
if(response!="ERR ELEV\015\012")$fatal(1,"invalid elevator command [%s]",response);
$display("PASS uart: subtitle compatibility, elevator ASCII status/query, alert commands and validation");$finish;
end
initial begin #2000000000;$fatal(1,"UART watchdog");end
endmodule

