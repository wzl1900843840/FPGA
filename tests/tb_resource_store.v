`timescale 1ns/1ps
module tb_resource_store;
parameter N=12;
reg clk=0;always #5 clk=~clk;reg rst=0,start=0,write=0;
reg [23:0] address=24'h7fe000;reg [N*8-1:0] payload=0;
wire busy,done,error,dropped,cs,sck,mosi,miso,wp,hold;wire [3:0] code;wire [N*8-1:0] data;
reg [1:0] response_mode=0;wire model_miso;
assign miso=response_mode==1 ? 1'b1 : response_mode==2 ? 1'b0 : model_miso;
w25q64_record_store #(.RECORD_BYTES(N),.CLK_DIV(2),.CS_HIGH_CYCLES(4),.POLL_INTERVAL_CYCLES(4),
 .ERASE_TIMEOUT_CYCLES(2048),.PROGRAM_TIMEOUT_CYCLES(1024),.ALLOWED_BASE(24'h7fe000),.ALLOWED_LIMIT(24'h800000)) dut(
 .clk(clk),.rst_n(rst),.start(start),.op_write(write),.address(address),.write_data(payload),
 .busy(busy),.done(done),.error(error),.error_code(code),.read_data(data),.request_dropped(dropped),
 .spi_cs_n(cs),.spi_sclk(sck),.spi_mosi(mosi),.spi_miso(miso),.spi_wp_n(wp),.spi_hold_n(hold));
spi_flash_model flash(clk,cs,sck,mosi,model_miso);
integer i,j,timeout;reg [N*8-1:0] expected;reg seen_dropped=0;
always @(posedge clk)if(dropped)seen_dropped<=1;
task request;input wr;input [23:0] addr;begin
 @(negedge clk);write=wr;address=addr;start=1;@(negedge clk);start=0;end endtask
task finish;input [3:0] expected_code;begin
 timeout=0;while(!done&&timeout<50000)begin @(negedge clk);timeout=timeout+1;end
 if(!done||code!==expected_code||error!==(expected_code!=0)||busy)$fatal(1,"store N%0d timeout%0d code%h expected%h",N,timeout,code,expected_code);
 @(negedge clk);end endtask
initial begin
 #12;rst=1;
 for(j=0;j<3;j=j+1)begin
  for(i=0;i<N;i=i+1)payload[i*8 +:8]=$random;expected=payload;
  request(1,24'h7fe000);payload=~payload;
  repeat(4)@(negedge clk);start=1;@(negedge clk);start=0;
  finish(0);if(data!==expected||!seen_dropped)$fatal(1,"write snapshot or dropped request");
  request(0,24'h7fe000);finish(0);if(data!==expected)$fatal(1,"readback");
 end
 request(1,24'h7fe001);finish(2);
 request(0,24'h7fdfff);finish(1);
 request(0,24'h800000);finish(1);
 response_mode=1;request(0,24'h7fe000);finish(11);
 response_mode=2;request(1,24'h7fe000);finish(3);
 response_mode=0;request(0,24'h7fe000);finish(0);if(data!==expected)$fatal(1,"recovery after fault");
 $display("PASS resource store N=%0d: random records, circular reuse/readback, input snapshot, busy rejection, address protection, timeout, WEL and recovery",N);$finish;
end
initial begin #5000000;$fatal(1,"store watchdog N%0d",N);end
endmodule
