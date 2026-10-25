`timescale 1ns/1ps
module tb_vendor_shared;
reg sc=0,mc=0,ms=0,pc=0,rst=0;
always #10 sc=~sc;always #12.5 mc=~mc;always #20 pc=~pc;
initial begin #10;forever #12.5 ms=~ms;end
wire init,busy,refresh,rv;wire [31:0] rd;
reg sw=0;reg [20:0] swa=0;reg [31:0] swd=0;
wire full,overflow,idle,we;wire [20:0] wa;wire [31:0] wd;wire [3:0] wm;
wire wrq,wgrant,vrq,vgrant,urgent,crq,cgrant;wire [1:0] owner;
wire vreturn,creturn,drained;
media_sdram_write_cdc #(.SHARED_MEMORY(1)) cdc(.src_clk(sc),.src_rst_n(rst),
 .src_wr_en(sw),.src_wr_addr(swa),.src_wr_mask(4'd0),.src_wr_data(swd),
 .src_full(full),.src_overflow(overflow),.dst_clk(mc),.dst_rst_n(rst),
 .dst_app_wr_en(we),.dst_app_wr_addr(wa),.dst_app_wr_mask(wm),.dst_app_wr_data(wd),
 .dst_idle(idle),.controller_busy(busy),.refresh_active(refresh),.burst_grant(wgrant),.burst_request(wrq));
reg fs=0,consume=0;reg run_video=0;
wire vre,pvalid,underflow,rbusy;wire [20:0] vra;wire [23:0] rgb;wire [7:0] err;
media_frame_reader #(.IMAGE_WORDS(128),.SHARED_MEMORY(1)) reader(
 .diag_synth_stream(1'b0),.mem_clk(mc),.mem_rst_n(rst),.controller_init_done(init),
 .controller_busy(busy),.refresh_active(refresh),.app_rd_en(vre),.app_rd_addr(vra),
 .sdram_rd_valid(rv && vreturn),.sdram_rd_data(rd),.pix_clk(pc),.pix_rst_n(rst),
 .frame_start(fs),.active_index(3'd0),.pixel_consume(consume),.pixel_rgb(rgb),.pixel_valid(pvalid),
 .underflow(underflow),.reader_busy(rbusy),.reader_error(err),.burst_grant(vgrant),.burst_request(vrq),.read_urgent(urgent));
reg [2:0] cs=0;reg [7:0] ci=0;reg cw=0,cre=0,cwe=0;reg [20:0] ca=0;reg [31:0] cd=0;
integer cache_round=0,cache_got=0;
assign crq=cs==1;
wire are=(owner==1 && vre)||(owner==3 && cre);
wire awe=(owner==2 && we)||(owner==3 && cwe);
wire [20:0] ara=owner==3 ? ca : vra;
wire [20:0] awa=owner==3 ? ca : wa;
wire [31:0] awd=owner==3 ? cd : wd;
media_sdram_arbiter arb(.clk(mc),.rst_n(rst),.controller_busy(busy),.refresh_active(refresh),
 .video_request(vrq),.video_urgent(urgent),.write_request(wrq),.cache_request(crq),.cache_write(cw),
 .app_read(are),.app_write(awe),.rd_valid(rv),.video_grant(vgrant),.write_grant(wgrant),.cache_grant(cgrant),
 .owner(owner),.video_return(vreturn),.cache_return(creturn),.write_drained(drained));
sdram mem(.Clk(mc),.Clk_sft(ms),.Rst(!rst),.Sdr_init_done(init),.Sdr_busy(busy),.Sdr_init_ref_vld(refresh),
 .App_wr_en(awe),.App_wr_addr(awa),.App_wr_dm(4'd0),.App_wr_din(awd),
 .App_rd_en(are),.App_rd_addr(ara),.Sdr_rd_en(rv),.Sdr_rd_dout(rd));
function [31:0] pattern;input integer addr;begin pattern=32'h005ac300 ^ addr;end endfunction
always @(posedge mc) begin
 if(awe && are) $fatal(1,"mixed interface read/write");
 if(rv && !(vreturn || creturn)) $fatal(1,"unrouted return");
 if(we && owner!=2) $fatal(1,"write client lost ownership");
 if(vre && owner!=1) $fatal(1,"video client lost ownership");
 if(run_video && overflow) $fatal(1,"CDC overflow");
 if(rv && creturn) begin
   if(rd!==pattern(3000+cache_got)) $fatal(1,"cache read mismatch %d got %h",cache_got,rd);
   cache_got=cache_got+1;
 end
 cre<=0;cwe<=0;
 case(cs)
 0: if(run_video) begin cs<=1;cw<=1;ci<=0;end
 1: if(cgrant) begin ci<=0;cs<=2;end
 2: begin ca<=3000+ci;cd<=pattern(3000+ci);cre<=!cw;cwe<=cw;
     if(ci==127) cs<=3;else ci<=ci+1'b1;end
 3: if(owner==0) begin
      if(cw) begin cw<=0;ci<=0;cs<=1;end
      else begin cache_round=cache_round+1;cs<=4;end
    end
 default: ;
 endcase
end
integer frames=0,checked=0,p;
initial forever begin
 wait(run_video);@(negedge pc);fs=1;@(negedge pc);fs=0;
 repeat(160)@(negedge pc);
 for(p=0;p<128;p=p+1)begin
   consume=1;#1;
   if(!pvalid || rgb!==pattern(p)) $fatal(1,"video mismatch frame%d word%d got%h valid%b",frames,p,rgb,pvalid);
   checked=checked+1;@(negedge pc);
 end
 consume=0;frames=frames+1;
 if(underflow || err) $fatal(1,"reader failed %h",err);
 repeat(240)@(negedge pc);
end
integer i;
reg [31:0] stored;
initial begin
 #51;rst=1;wait(init);
 for(i=0;i<128;i=i+1)begin @(negedge sc);sw=1;swa=i;swd=pattern(i);end
 @(negedge sc);sw=0;wait(idle && drained);repeat(32)@(negedge mc);run_video=1;
 // Concurrent write bursts to other banks, with display and cache traffic.
 for(i=128;i<1152;i=i+1)begin
   repeat(8)@(negedge sc);while(full)@(negedge sc);
   sw=1;swa=i;swd=pattern(i);@(negedge sc);sw=0;
 end
 wait(idle && drained && cache_round==1);wait(frames>=10);
 if(cache_got!=128 || checked<1280 || overflow) $fatal(1,"missing shared traffic");
 for(i=0;i<1152;i=i+1)begin
   case((i>>2)&3)
    0:stored=mem.sdram.chip.Bank0[((i>>4)<<2)|(i&3)];
    1:stored=mem.sdram.chip.Bank1[((i>>4)<<2)|(i&3)];
    2:stored=mem.sdram.chip.Bank2[((i>>4)<<2)|(i&3)];
    3:stored=mem.sdram.chip.Bank3[((i>>4)<<2)|(i&3)];
   endcase
   if(stored!==pattern(i))$fatal(1,"background physical write mismatch %d %h",i,stored);
 end
 $display("PASS vendor shared: display pixels=%d, background writes=1152, cache write/read=128, refresh-safe ownership",checked);
 $finish;
end
initial begin #15000000;$fatal(1,"shared timeout owner%d cache%d frame%d",owner,cs,frames);end
endmodule
