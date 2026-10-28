`timescale 1ns/1ps
module tb_fix_burst_abort;
reg mc=0,pc=0,rst=0,fs=0;always #12.5 mc=~mc;always #20 pc=~pc;
wire app_read,valid,busy,req,urgent,grant,ret,drained;wire [20:0]addr;
wire [1:0] owner;wire [7:0]error;reg rv=0;reg[31:0]data=0;
integer commands=0;always @(posedge mc)begin rv<=app_read;data<=addr;if(rst&&app_read)commands=commands+1;end
media_frame_reader #(.IMAGE_WORDS(256),.SHARED_MEMORY(1)) reader(
 .diag_synth_stream(1'b0),.mem_clk(mc),.mem_rst_n(rst),.controller_init_done(1'b1),
 .controller_busy(1'b0),.refresh_active(1'b0),.app_rd_en(app_read),.app_rd_addr(addr),
 .sdram_rd_valid(rv&&ret),.sdram_rd_data(data),.pix_clk(pc),.pix_rst_n(rst),
 .frame_start(fs),.active_index(3'd0),.pixel_consume(1'b0),.pixel_rgb(),.pixel_valid(valid),.underflow(),
 .reader_busy(busy),.frame_read_done(),.reader_index(),.reader_error(error),
 .burst_grant(grant),.burst_request(req),.read_urgent(urgent));
media_sdram_arbiter arb(.clk(mc),.rst_n(rst),.controller_busy(1'b0),.refresh_active(1'b0),
 .video_request(req),.video_urgent(urgent),.write_request(1'b0),.cache_request(1'b0),.cache_write(1'b0),
 .app_read(app_read),.app_write(1'b0),.rd_valid(rv),.video_grant(grant),.write_grant(),.cache_grant(),
 .owner(owner),.video_return(ret),.cache_return(),.write_drained(drained));
initial begin
 #103;rst=1;repeat(10)@(negedge pc);fs=1;@(negedge pc);fs=0;
 wait(commands>=20);@(negedge pc);fs=1;@(negedge pc);fs=0;
 repeat(5000)@(negedge mc);
 if(commands>=384 && owner==0 && !req)
  $display("PASS frame-overrun authorized transaction completes: commands=%0d returns=%0d owner=%0d request=%0d grant=%0d",commands,arb.returns,owner,req,grant);
 else $fatal(1,"burst-abort hazard not reproduced commands=%0d owner=%0d req=%0d grant=%0d retiring=%0d",commands,owner,req,grant,arb.retiring);
 $finish;
end
initial begin #1000000;$fatal(1,"audit timeout");end
endmodule
