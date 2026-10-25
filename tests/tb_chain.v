`timescale 1ns/1ps
// All production RTL from sector interface through HDMI symbols. Only the SD
// medium and SDRAM array are behavioral devices, not replacement player logic.
module tb_chain;
reg sc=0,mc=0,pc=0,rst=0,prst=0,start=0,run_pc=0;
always #10 sc=~sc;always #12.5 mc=~mc;always #20 if(run_pc)pc=~pc;
wire idone,req,sw,full,overflow,idle,mw;wire[31:0]lba,swdata,mwdata;wire[20:0]swa,mwa;
wire[3:0]mask,mmask,complete,resources;wire[7:0]error,detail;
reg busy=0,sv=0,sd=0;reg[7:0]sbyte=0;reg[8:0]bi=0;
media_ingest_frontend front(.clk(sc),.rst_n(rst),.start(start),.done(idone),.ingest_error(error),.ingest_detail_error(detail),
.resource_valid(resources),.image_complete(complete),.reader_req(req),.reader_lba(lba),.reader_busy(busy),
.reader_valid(sv),.reader_byte(sbyte),.reader_byte_index(bi),.reader_done(sd),.reader_error(8'd0),
.controller_init_done(!full),.controller_busy(1'b0),.refresh_active(1'b0),.app_wr_en(sw),.app_wr_addr(swa),.app_wr_mask(mask),.app_wr_data(swdata));
media_sdram_write_cdc cdc(sc,rst,sw,swa,mask,swdata,full,overflow,mc,rst,mw,mwa,mmask,mwdata,idle,1'b0,1'b0,1'b1,);
reg[31:0]memory[0:1843199];integer writes=0,bank,pos,x,y;reg[23:0]expected;
function[23:0]pixel;input integer bank,x,y;begin pixel={x[7:0],y[7:0],8'd5+bank[7:0]*8'd40};end endfunction
always @(posedge mc)if(mw)begin
bank=mwa/307200;pos=mwa%307200;x=pos%640;y=pos/640;expected=pixel(bank,x,y);
if(mwdata[23:0]!==expected)$fatal(1,"load bank%d x%d y%d got%h exp%h",bank,x,y,mwdata,expected);
memory[mwa]<=mwdata;writes=writes+1;end
// A FAT32 sector source with four valid BMPs, alternate top-down/bottom-up.
function[7:0]diskbyte;input integer sector,idx;integer cl,b,o,fatval,height,sz,px,py,ch,dent;begin
diskbyte=0;
if(sector==0)begin
case(idx)0:diskbyte=8'heb;12:diskbyte=2;13:diskbyte=1;14:diskbyte=32;16:diskbyte=1;
32:diskbyte=8'h20;33:diskbyte=8'h4e;36:diskbyte=128;44:diskbyte=2;510:diskbyte=8'h55;511:diskbyte=8'haa;endcase
end else if(sector>=32 &&sector<160)begin
cl=(sector-32)*128+idx/4;fatval=32'h0fffffff;
for(b=0;b<4;b=b+1)if(cl>=10+b*4000&&cl<1810+b*4000)fatval=cl+1;
diskbyte=(fatval>>(8*(idx%4)))&255;
end else if(sector==160)begin
dent=idx/32;o=idx%32;
if(dent<4)begin cl=10+dent*4000;sz=921654;
case(o)0:diskbyte="P";1:diskbyte="I";2:diskbyte="C";3:diskbyte="1"+dent;
4,5,6,7:diskbyte=" ";8:diskbyte="B";9:diskbyte="M";10:diskbyte="P";11:diskbyte=8'h20;
26:diskbyte=cl&255;27:diskbyte=cl>>8;28,29,30,31:diskbyte=sz>>(8*(o-28));endcase
end
end else begin
cl=sector-160+2;b=(cl-10)/4000;o=(cl-(10+b*4000))*512+idx;height=b%2?-480:480;sz=921654;
if(b<0 ||b>3 ||o<0)$fatal(1,"bad SD address %d",sector);
if(o<54)begin case(o)
0:diskbyte="B";1:diskbyte="M";2,3,4,5:diskbyte=sz>>(8*(o-2));10:diskbyte=54;14:diskbyte=40;
18:diskbyte=8'h80;19:diskbyte=2;22,23,24,25:diskbyte=height>>(8*(o-22));26:diskbyte=1;28:diskbyte=24;
endcase end else if(o<sz)begin px=((o-54)/3)%640;py=(o-54)/1920;ch=(o-54)%3;
if(b%2==0)py=479-py;
case(ch)0:diskbyte=5+b*40;1:diskbyte=py;2:diskbyte=px;endcase end
end end endfunction
integer i,requests=0;reg[31:0]a;
initial forever begin wait(req);a=lba;requests=requests+1;@(posedge sc);#1;busy=1;
for(i=0;i<512;i=i+1)begin @(negedge sc);sv=1;bi=i;sbyte=diskbyte(a,i);end
@(negedge sc);sv=0;sd=1;@(negedge sc);sd=0;busy=0;end
wire re,rvout;wire[20:0]ra;reg rv=0;reg[31:0]rd=0;
always @(posedge mc)begin rv<=re;if(re)rd<=memory[ra];end
reg select=0;reg[1:0]target=0;wire[1:0]active;wire hs,vs,de,fs,underflow;wire[23:0]rgb;wire[9:0]vx,vy;wire[7:0]verr;
media_video_pipeline #(.FADE_FRAMES(0),.ENABLE_COLOR_ADJUST(1)) video(.ctrl_clk(pc),.ctrl_rst_n(prst),.next_event(1'b0),.previous_event(1'b0),
.select_valid(select),.select_index(target),.view_mode(1'b0),.mode_transition(1'b0),.focus_index(2'd0),.video_y(vy),.toggle_auto_event(1'b0),
.period_cfg_valid(1'b0),.period_cfg_cycles(32'd0),.auto_cfg_valid(1'b0),.auto_cfg_enabled(1'b0),.image_complete(complete),
.player_enable(prst),.mem_clk(mc),.mem_rst_n(rst),.controller_init_done(prst),.controller_busy(1'b0),.refresh_active(1'b0),
.app_rd_en(re),.app_rd_addr(ra),.sdram_rd_valid(rv),.sdram_rd_data(rd),.brightness(8'd255),.contrast(8'd128),.pix_clk(pc),.pix_rst_n(prst),
.video_hs(hs),.video_vs(vs),.video_de(de),.video_rgb(rgb),.video_x(vx),.active_index(active),.frame_start(fs),.reader_underflow(underflow),.video_error(verr));
wire tap;wire wreq,wtick,wvalid,wready,wactive;wire[31:0]wlba;
reg wbusy=0,wbvalid=0,wdone=0;reg[8:0]wbi=0;reg[7:0]wb=0;wire signed[15:0]wsample,tapsample;
wav_stream_player wav(.wr_clk(sc),.wr_rst_n(rst),.play_enable(prst),.start_lba(32'd32768),.total_sectors(32'd32),
.sd_req(wreq),.sd_lba(wlba),.sd_busy(wbusy),.sd_valid(wbvalid),.sd_byte(wb),.sd_byte_index(wbi),.sd_done(wdone),.sd_error(8'd0),
.rd_clk(pc),.rd_rst_n(prst),.sample_tick(wtick),.sample_out(wsample),.sample_valid(wvalid),.sample_ready(wready),.stream_active(wactive));
integer wi,wa,wvalue;
initial forever begin wait(wreq);wa=wlba;@(negedge sc);wbusy=1;
for(wi=0;wi<512;wi=wi+1)begin @(negedge sc);wbvalid=1;wbi=wi;
wvalue=(((wa-32768)*256+wi/2)%200)*100-10000;wb=wi%2 ? (wvalue>>8)&255:wvalue&255;end
@(negedge sc);wbvalid=0;wdone=1;@(negedge sc);wdone=0;wbusy=0;end
reg[15:0]sample_queue[0:16383];integer qw=0,qr=0;
always @(posedge pc)if(prst)begin
if(wvalid&&wready)begin sample_queue[qw]=wsample;qw=qw+1;end
if(tap)begin if(qr==qw || tapsample!==sample_queue[qr])$fatal(1,"PCM chain lost or changed sample %d",qr);qr=qr+1;end
end
wire[9:0]ch0,ch1,ch2;wire seqerr,toneerr,contracterr;
media_hdmi_audio_bridge audio(.pixel_clk(pc),.pixel_rst_n(prst),.video_hsync(hs),.video_vsync(vs),.video_de(de),.video_x(vx),.video_rgb(rgb),
.media_id(active),.volume(8'd255),.wav_valid(wvalid),.wav_active(wactive),.force_test(1'b0),.wav_sample(wsample),.wav_ready(wready),.sample_tick(wtick),.fade_gain(8'd255),
.channel0_symbol(ch0),.channel1_symbol(ch1),.channel2_symbol(ch2),.sequence_error(seqerr),.tone_overflow(toneerr),.pcm_contract_error(contracterr),.pcm_tap_valid(tap),.pcm_tap_left(tapsample));
integer frames=0,pixels=0,checked=0,samples=0,packets=0,slots=0;reg check_pixels=0;
always @(posedge pc)if(prst)begin
if(fs)begin frames=frames+1;if(check_pixels &&pixels!=307200)$fatal(1,"frame pixels %d",pixels);pixels=0;end
if(tap)samples=samples+1;
if(audio.u_symbol_core.packet_ready)packets=packets+1;
if(vx==652)slots=slots+1;
if(seqerr||toneerr||contracterr||underflow||verr)$fatal(1,"video/audio status %h %b%b%b",verr,seqerr,toneerr,contracterr);
if(de &&check_pixels)begin pixels=pixels+1;checked=checked+1;
if(rgb!==pixel(active,vx,vy))$fatal(1,"display bank%d x%d y%d got%h exp%h",active,vx,vy,rgb,pixel(active,vx,vy));end
end
integer f;
task next_frame;begin @(posedge pc);while(!fs)@(posedge pc);#1;end endtask
initial begin
#51;rst=1;
if($test$plusargs("VIDEO_ONLY")) begin
for(f=0;f<1228800;f=f+1) memory[f]=pixel(f/307200,(f%307200)%640,(f%307200)/640);
force complete=15;
end else begin
@(negedge sc);start=1;@(negedge sc);start=0;
wait(idone);repeat(1000)@(negedge mc);
if(error||detail||complete!=15||writes!=1228800||overflow||!idle)$fatal(1,"ingest %h %h complete%h words%d overflow%b",error,detail,complete,writes,overflow);
$display("CHAIN loaded four full BMPs, verified 1228800 SDRAM words; start video");$fflush();
end
run_pc=1;repeat(8)@(negedge pc);prst=1;next_frame;check_pixels=1;
for(f=0;f<4;f=f+1)begin
if(f!=0)begin @(negedge pc);target=f;select=1;@(negedge pc);select=0;wait(active==f);end
next_frame;
$display("CHAIN checked bank %d, pixels=%d",f,checked);$fflush();
end
if(samples<1000||packets<250||slots<1000||checked<1228800)$fatal(1,"no HDMI audio %d %d",samples,packets);
$display("PASS CHAIN: FAT32/BMP/replay/loader/50->40MHz CDC/SDRAM/25MHz reader/four banks/HDMI video+audio. pixels=%d samples=%d packets=%d",checked,samples,packets);$finish;
end
initial begin #900000000;$fatal(1,"chain watchdog state %d err%h/%h words%d",front.u_ingest_pipeline.state,error,detail,writes);end
endmodule
