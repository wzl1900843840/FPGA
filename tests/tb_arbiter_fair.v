`timescale 1ns/1ps
module tb_arbiter_fair;
reg clk=0,rst_n=0,urgent=0,refresh=0;
always #5 clk=~clk;
wire vg,wg,cg,vr,cr,dr,fault;
wire [1:0] owner;
wire [21:0] vw,ww,cw;
wire app_write=(owner==2 || owner==3) && !refresh;
wire app_read=owner==1 && !refresh;
media_sdram_arbiter #(.BURST_SIZE(4),.DRAIN_CYCLES(2),.STALL_LIMIT(1000)) dut(
 .clk(clk),.rst_n(rst_n),.controller_busy(1'b0),.refresh_active(refresh),
 .video_request(1'b1),.video_urgent(urgent),.write_request(1'b1),
 .cache_request(1'b1),.cache_write(1'b1),.app_read(app_read),
 .app_write(app_write),.rd_valid(app_read),.video_grant(vg),.write_grant(wg),
 .cache_grant(cg),.owner(owner),.video_return(vr),.cache_return(cr),
 .write_drained(dr),.fault(fault),.diagnostic_max_wait(vw),
 .diagnostic_write_wait(ww),.diagnostic_cache_wait(cw));
integer background=0,video=0,cycles=0;
reg expected_write=1;
always @(posedge clk) if(rst_n) begin
 if(wg || cg) begin
  if(background<4 && (wg!==expected_write || cg===expected_write))
   $fatal(1,"background not round robin at %0d owner %0d",background,owner);
  background=background+1;expected_write=~expected_write;
 end
 if(vg) video=video+1;
 if(vg+wg+cg>1)$fatal(1,"multiple grants");
 if(vr && cr)$fatal(1,"read return crossed owners");
end
initial begin
 #21;rst_n=1;
 while(background<4 && cycles<200)begin @(posedge clk);cycles=cycles+1;end
 if(background<4)$fatal(1,"background starved");
 @(negedge clk);urgent=1;
 while(video<1 && cycles<300)begin @(posedge clk);cycles=cycles+1;end
 if(video!=1)$fatal(1,"urgent video starved");
 @(negedge clk);urgent=0;
 repeat(80)@(posedge clk);
 if(background<6 || vw==0 || ww==0 || cw==0 || fault)$fatal(1,"fairness or wait diagnostics failed b=%0d v=%0d w=%0d c=%0d",background,video,ww,cw);
 $display("PASS arbiter fair: alternating background grants, urgent video, wait counters and exclusive returns");$finish;
end
endmodule
