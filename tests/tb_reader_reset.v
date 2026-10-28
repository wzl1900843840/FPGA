`timescale 1ns/1ps
module tb_reader_reset;
reg mc=0,pc=0,mrst=0,prst=0,fs=0,consume=0;
always #12.5 mc=~mc;
always #20 pc=~pc;
reg [2:0] index=0;
wire re,valid,busy,done,underflow;
wire [20:0] addr;
wire [23:0] rgb;
wire [7:0] error;
reg rv=0; reg [31:0] rd=0;
media_frame_reader #(.IMAGE_WORDS(128)) dut(
 .diag_synth_stream(1'b0),.mem_clk(mc),.mem_rst_n(mrst),
 .controller_init_done(1'b1),.controller_busy(1'b0),.refresh_active(1'b0),
 .app_rd_en(re),.app_rd_addr(addr),.sdram_rd_valid(rv),.sdram_rd_data(rd),
 .pix_clk(pc),.pix_rst_n(prst),.frame_start(fs),.active_index(index),
 .pixel_consume(consume),.pixel_rgb(rgb),.pixel_valid(valid),.underflow(underflow),
 .reader_busy(busy),.frame_read_done(done),.reader_index(),.reader_error(error),
 .burst_grant(1'b1),.burst_request(),.read_urgent());
always @(posedge mc or negedge mrst)
 if(!mrst) begin rv<=0; rd<=0; end
 else begin rv<=re; rd<=32'h005a0000+addr; end
always @(negedge pc) begin
 if(dut.prefetch_reset_pix && (dut.fifo_raw_read_en || valid))
   $fatal(1,"read or valid during prefetch reset");
end
always @(negedge mc)
 if(dut.fifo_reset && dut.fifo_write_enable) $fatal(1,"write during common flush");
time last_pixel_edge=0;
always @(posedge pc) last_pixel_edge=$time;
always @(negedge dut.prefetch_reset_pix)
 if($time>0 && $time!=last_pixel_edge) $fatal(1,"asynchronous pixel reset release");
task start_frame; input [2:0] bank;
 begin
  @(negedge pc);index=bank;fs=1;
  @(negedge pc);fs=0;
  wait(busy);wait(done);repeat(30)@(negedge pc);
 end
endtask
task read_words;input integer bank;input integer n;integer k;reg [23:0] expected;
 begin
  for(k=0;k<n;k=k+1) begin
   expected=24'h5a0000+bank*128+k;
   if(!valid || rgb!==expected) $fatal(1,"bank%0d word%0d got%h expected%h valid%b",bank,k,rgb,expected,valid);
   consume=1;@(negedge pc);
  end
  consume=0;
 end
endtask
integer j;
initial begin
 #53;mrst=1;#13;prst=1;
 for(j=0;j<6;j=j+1)begin start_frame(j);read_words(j,128);end
 if(underflow || error) $fatal(1,"normal frames failed %h",error);
 // A live view/index change cannot retarget an already issued burst.
 @(negedge pc);index=5;fs=1;@(negedge pc);fs=0;
 wait(re);@(negedge pc);index=4;wait(done);repeat(30)@(negedge pc);
 read_words(5,128);
 // Flush a partially consumed old frame; no old pixels may survive.
 start_frame(1);read_words(1,9);start_frame(4);read_words(4,128);
 // Manual reset at a non-clock phase with prefetched pixels outstanding.
 start_frame(3);#7;mrst=0;prst=0;#57;prst=1;#11;mrst=1;
 repeat(8)@(negedge pc);start_frame(2);read_words(2,128);
 if(underflow || error) $fatal(1,"reset recovery failed %h",error);
 // A reset pulse shorter than either clock must still assert both hold
 // chains immediately. This fails if raw cross-domain reset is sampled as D.
 @(negedge mc);#2;prst=0;#1;
 if(dut.fifo_release_mem!==2'b00 || dut.fifo_release_pix!==2'b00)
   $fatal(1,"short pixel reset did not asynchronously assert both release chains");
 prst=1;repeat(8)@(negedge pc);
 @(negedge pc);#2;mrst=0;#1;
 if(dut.fifo_release_mem!==2'b00 || dut.fifo_release_pix!==2'b00)
   $fatal(1,"short memory reset did not asynchronously assert both release chains");
 mrst=1;repeat(8)@(negedge pc);
 // The common FIFO reset can fall between memory edges. Diagnostics must
 // remain frozen through both local release stages, even with a low count.
 @(negedge mc);mrst=0;prst=0;#57;mrst=1;#11;prst=1;
 force dut.diagnostic_started=1'b1;
 force dut.reload_pending_mem=1'b0;
 force dut.reader_busy=1'b1;
 force dut.issued_count_mem=0;
 force dut.fifo_wrusedw=9'd17;
 wait(!dut.fifo_reset);
 @(posedge mc);#1;
 if(dut.diagnostic_fifo_min!==9'd511) $fatal(1,"diagnostics sampled before local release stage 1");
 @(posedge mc);#1;
 if(dut.diagnostic_fifo_min!==9'd511) $fatal(1,"diagnostics sampled before local release stage 2");
 @(posedge mc);#1;
 if(dut.diagnostic_fifo_min!==9'd17) $fatal(1,"diagnostics did not resume after local release");
 release dut.diagnostic_started;release dut.reload_pending_mem;
 release dut.reader_busy;release dut.issued_count_mem;release dut.fifo_wrusedw;
 $display("PASS reader reset: destination release, read/write isolation, five media banks plus thumbnail bank, stale-pixel flush, manual reset");
 $finish;
end
initial begin #3000000;$fatal(1,"reader reset timeout");end
endmodule
