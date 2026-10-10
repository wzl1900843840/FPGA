`timescale 1ns/1ps
// Real 25 MHz 640x480 display traffic while the production thumbnail builder
// reads/writes a complete cache through the encrypted 40 MHz SDRAM controller.
module tb_vendor_shared_cache;
reg mc=0,ms=0,pc=0,rst=0,start=0,run_video=0;
always #12.5 mc=~mc;always #20 pc=~pc;
initial begin #10;forever #12.5 ms=~ms;end
wire init,busy,refresh,rv;wire [31:0] rd;
wire vre,cre,cwe,vrequest,urgent,vgrant,crequest,cwrite,cgrant;
wire [20:0] va,cra,cwa;wire [31:0] cwd;
wire [1:0] owner;wire vreturn,creturn,cache_busy,cache_done;
wire [7:0] cache_error,reader_error;
reg fs=0,consume=0;wire [23:0] rgb;wire valid,underflow;
media_frame_reader #(.SHARED_MEMORY(1)) reader(
 .diag_synth_stream(1'b0),.mem_clk(mc),.mem_rst_n(rst),.controller_init_done(init),
 .controller_busy(busy),.refresh_active(refresh),.app_rd_en(vre),.app_rd_addr(va),
 .sdram_rd_valid(rv && vreturn),.sdram_rd_data(rd),.pix_clk(pc),.pix_rst_n(rst),
 .frame_start(fs),.active_index(2'd0),.pixel_consume(consume),.pixel_rgb(rgb),.pixel_valid(valid),
 .underflow(underflow),.reader_error(reader_error),.burst_grant(vgrant),.burst_request(vrequest),.read_urgent(urgent));
thumbnail_cache_builder #(.SHARED_MEMORY(1)) cache(
 .clk(mc),.rst_n(rst),.start(start),.image_complete(4'b1101),.busy(cache_busy),.done(cache_done),.error(cache_error),
 .app_rd_en(cre),.app_rd_addr(cra),.rd_valid(rv && creturn),.rd_data(rd),
 .app_wr_en(cwe),.app_wr_addr(cwa),.app_wr_data(cwd),.controller_busy(busy),.refresh_active(refresh),
 .burst_grant(cgrant),.burst_request(crequest),.burst_write(cwrite));
wire are=(owner==1 && vre)||(owner==3 && cre);
wire awe=owner==3 && cwe;
media_sdram_arbiter arb(.clk(mc),.rst_n(rst),.controller_busy(busy),.refresh_active(refresh),
 .video_request(vrequest),.video_urgent(urgent),.write_request(1'b0),.cache_request(crequest),.cache_write(cwrite),
 .app_read(are),.app_write(awe),.rd_valid(rv),.video_grant(vgrant),.cache_grant(cgrant),
 .owner(owner),.video_return(vreturn),.cache_return(creturn));
sdram mem(.Clk(mc),.Clk_sft(ms),.Rst(!rst),.Sdr_init_done(init),.Sdr_busy(busy),.Sdr_init_ref_vld(refresh),
 .App_wr_en(awe),.App_wr_addr(cwa),.App_wr_dm(4'd0),.App_wr_din(cwd),
 .App_rd_en(are),.App_rd_addr(owner==3 ? cra : va),.Sdr_rd_en(rv),.Sdr_rd_dout(rd));
integer cache_words=0,display_words=0,frames=0,refreshes=0,pos,x,y,bank,expected,n;
reg ref_q=0,finished=0;
always @(posedge mc)begin
 ref_q<=refresh;if(refresh && !ref_q)refreshes=refreshes+1;
 if(vre && owner!=1)$fatal(1,"video lost ownership");
 if((cre || cwe) && owner!=3)$fatal(1,"cache lost ownership");
 if(rv && !(vreturn || creturn))$fatal(1,"unrouted SDRAM return");
 if(awe)begin
  pos=cache_words;x=pos%640;y=pos/640;expected=0;
  if(x>=160 && x<480 && y>=120 && y<360)begin bank=((y-120)/120)*2+(x-160)/160;
   if(bank!=1)expected=bank*307200+((y-120)%120)*4*640+((x-160)%160)*4;end
  if(cwa!==1228800+cache_words || cwd!==expected)$fatal(1,"cache pixel %d got%h expected%h",pos,cwd,expected);
  cache_words=cache_words+1;
 end
end
integer line,column;
initial forever begin
 wait(run_video);@(negedge pc);fs=1;@(negedge pc);fs=0;
 // Vertical blank after frame request: 35 lines, 800 clocks per line.
 repeat(28000)@(negedge pc);
 for(line=0;line<480;line=line+1)begin
  for(column=0;column<640;column=column+1)begin
   consume=1;#1;
   if(!valid || rgb!==(line*640+column))$fatal(1,"display frame%d row%d col%d rgb%h valid%b",frames,line,column,rgb,valid);
   display_words=display_words+1;@(negedge pc);
  end
  consume=0;repeat(160)@(negedge pc);
 end
 if(underflow || reader_error)$fatal(1,"display error %h",reader_error);
 frames=frames+1;repeat(8000)@(negedge pc);
end
initial begin
 #51;rst=1;wait(init);
 for(n=0;n<1228800;n=n+1)case((n>>2)&3)
 0:mem.sdram.chip.Bank0[((n>>4)<<2)|(n&3)]=n;
 1:mem.sdram.chip.Bank1[((n>>4)<<2)|(n&3)]=n;
 2:mem.sdram.chip.Bank2[((n>>4)<<2)|(n&3)]=n;
 3:mem.sdram.chip.Bank3[((n>>4)<<2)|(n&3)]=n;
 endcase
 @(negedge mc);run_video=1;start=1;@(negedge mc);start=0;
 wait(cache_done);finished=1;
 if(cache_error || cache_words!=307200)$fatal(1,"cache incomplete %d %h",cache_words,cache_error);
 wait(frames>=2);
 if(refreshes<100)$fatal(1,"refresh coverage missing");
 $display("PASS vendor shared cache: all 307200 cache words, %d display pixels at 25 MHz, %d refreshes, no underflow",display_words,refreshes);
 $finish;
end
initial begin #200000000;$fatal(1,"shared cache watchdog cache%d frames%d state%d",cache_words,frames,cache.state);end
endmodule
