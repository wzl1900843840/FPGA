`timescale 1ns/1ps
module tb_early_ingest;
reg sc=0,mc=0,rst=0,start=0;
always #10 sc=~sc;always #12.5 mc=~mc;
wire req,done,sw,full,overflow,idle,mw;
wire [31:0] lba,swdata,mwdata;
wire [20:0] swa,mwa;wire [3:0] mask,mmask,complete,ready;
wire [7:0] error,detail;
reg busy=0,sv=0,sd=0;reg [7:0] sb=0;reg [8:0] bi=0;
reg [7:0] physical_delay=0;
wire physical_idle=physical_delay==0;
media_ingest_frontend #(.IMAGE_WIDTH(16),.IMAGE_HEIGHT(8),.EARLY_DISPLAY(1)) front(
 .clk(sc),.rst_n(rst),.start(start),.done(done),.ingest_error(error),.ingest_detail_error(detail),
 .image_complete(complete),.image_ready(ready),.write_drain_idle(idle && physical_idle && !sw),
 .reader_req(req),.reader_lba(lba),.reader_busy(busy),.reader_valid(sv),.reader_byte(sb),
 .reader_byte_index(bi),.reader_done(sd),.reader_error(8'd0),
 .controller_init_done(!full),.controller_busy(1'b0),.refresh_active(1'b0),
 .app_wr_en(sw),.app_wr_addr(swa),.app_wr_mask(mask),.app_wr_data(swdata));
media_sdram_write_cdc cdc(sc,rst,sw,swa,mask,swdata,full,overflow,mc,rst,
 mw,mwa,mmask,mwdata,idle,1'b0,1'b0,1'b1,);
integer writes[0:3];integer k,bank,pos;reg [3:0] previous_ready=0;
reg saw_early=0;reg tail_bad,abort_bad;
reg abort_injected=0;integer aborts=0;
always @(negedge sc) if(rst && abort_bad) begin
 if(front.u_ingest_pipeline.state==2) begin
   release front.u_ingest_pipeline.bmp_error;abort_injected=0;
 end else if(!abort_injected && front.u_ingest_pipeline.current_image==0 && sw && swa==31)begin
   // An upstream failure after 32 words of a buffered 128-word write.
   force front.u_ingest_pipeline.bmp_error=8'h55;abort_injected=1;aborts=aborts+1;
 end
end
function [23:0] pixel;input integer bank,pos;begin pixel={8'(pos%16),8'(pos/16),8'(bank*40+5)};end endfunction
always @(posedge mc) begin
 if(mw) begin
   bank=mwa/128;pos=mwa%128;
   if(mwdata[23:0]!==pixel(bank,pos)) $fatal(1,"image pixel mismatch");
   if(ready[bank]) $fatal(1,"write to already published image");
   writes[bank]=writes[bank]+1;physical_delay<=80;
 end else if(physical_delay!=0) physical_delay<=physical_delay-1'b1;
end
always @(posedge sc) if(rst) begin
 if(ready!=previous_ready) begin
   if(!idle || !physical_idle) $fatal(1,"published before write drain");
   for(k=0;k<4;k=k+1) if(ready[k] && !previous_ready[k]) begin
     if(writes[k]!=128) $fatal(1,"published incomplete image %d words=%d",k,writes[k]);
     if((tail_bad || abort_bad) && k==0) $fatal(1,"published a failed image");
   end
   if(!done && ready!=15) saw_early=1;
   previous_ready<=ready;
 end
 if(overflow) $fatal(1,"CDC overflow");
end
function [7:0] diskbyte;
input integer sector,idx;integer cl,v,n,o,b,offset,sz,h;begin
 diskbyte=0;sz=438;h=-8;
 if(sector==0) begin
   case(idx)0:diskbyte=8'heb;12:diskbyte=2;13:diskbyte=1;14:diskbyte=32;16:diskbyte=1;
   32:diskbyte=8'h20;33:diskbyte=8'h4e;36:diskbyte=128;44:diskbyte=2;510:diskbyte=8'h55;511:diskbyte=8'haa;endcase
 end else if(sector>=32 && sector<160) begin
   cl=(sector-32)*128+idx/4;v=(tail_bad && cl==10)?1:32'h0fffffff;diskbyte=v>>(8*(idx%4));
 end else if(sector==160) begin
   n=idx/32;o=idx%32;cl=10+n;
   if(n<4) case(o)
   0:diskbyte="P";1:diskbyte="I";2:diskbyte="C";3:diskbyte="1"+n;4,5,6,7:diskbyte=" ";
   8:diskbyte="B";9:diskbyte="M";10:diskbyte="P";11:diskbyte=8'h20;
   26:diskbyte=cl;28,29,30,31:diskbyte=sz>>(8*(o-28));endcase
 end else if(sector>=168 && sector<=171) begin
   b=sector-168;
   if(idx<54) case(idx)
   0:diskbyte="B";1:diskbyte="M";2,3,4,5:diskbyte=sz>>(8*(idx-2));10:diskbyte=54;14:diskbyte=40;
   18:diskbyte=16;22,23,24,25:diskbyte=h>>(8*(idx-22));26:diskbyte=1;28:diskbyte=24;endcase
   else if(idx<sz) begin offset=idx-54;
     case(offset%3)0:diskbyte=b*40+5;1:diskbyte=offset/48;2:diskbyte=(offset/3)%16;endcase
   end
 end else $fatal(1,"bad LBA %d",sector);
end endfunction
integer i;reg [31:0] a;
initial forever begin
 wait(req);a=lba;@(negedge sc);busy=1;
 for(i=0;i<512;i=i+1) begin @(negedge sc);sv=1;bi=i;sb=diskbyte(a,i);end
 @(negedge sc);sv=0;sd=1;@(negedge sc);sd=0;busy=0;
end
initial begin
 tail_bad=$test$plusargs("BAD_TAIL");abort_bad=$test$plusargs("ABORT_BURST");for(k=0;k<4;k=k+1)writes[k]=0;
 #51;rst=1;@(negedge sc);start=1;@(negedge sc);start=0;
 wait(done);#1;
 if(!saw_early || ready!=((tail_bad || abort_bad)?14:15)) $fatal(1,"early publish missing ready=%h",ready);
 if(abort_bad && (aborts!=2 || writes[0]!=256 || !idle))$fatal(1,"failed burst did not finish/recover");
 $display("PASS early ingest: verified before final done, CDC/physical drain, bad-tail=%b aborted-burst=%b",tail_bad,abort_bad);
 $finish;
end
initial begin #2000000;$fatal(1,"early ingest timeout state=%d ready=%h",front.u_ingest_pipeline.state,ready);end
endmodule
