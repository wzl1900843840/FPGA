`timescale 1ns/1ps
module tb_recovery_top;
reg clk=0,rst=0,fs=0,fault=0,manual=0;always #10 clk=~clk;
reg[4:0]images=1;reg done=0,cache_done=0;
top #(.UI_CLKS_PER_MS(10)) d(.clk(clk),.rst_n(rst),.key1(1'b1),.key2(1'b1),.key3(1'b1),
 .sw(4'd0),.uart_rx(1'b1),.sd_miso(1'b1),.flash_miso(1'b1));
integer i,frames=0;
task cycles;input integer n;begin repeat(n)@(negedge clk);end endtask
task frame;begin
 repeat(15)@(negedge d.pixel_clk);fs=1;@(negedge d.pixel_clk);fs=0;repeat(10)@(negedge d.pixel_clk);frames=frames+1;
end endtask
task complete_boot;begin
 wait(d.boot_state==1);$display("CHECK boot start t%0t",$time);cycles(10);done=1;cycles(1);done=0;
 wait(d.boot_state==3);$display("CHECK cache start t%0t",$time);cycles(1);cache_done=1;cycles(1);cache_done=0;wait(d.boot_state==4);cycles(12);
end endtask
initial begin
 force d.frame_start=fs;force d.image_complete=images;
 force d.ingest_done=done;force d.cache_done_sys=cache_done;
 force d.cache_failed_sys=1'b0;force d.arbiter_fault=fault;
 force d.cdc_idle_sys=1'b1;force d.write_drained_sys=1'b1;force d.source_wr=1'b0;
 force d.reload_request=manual;
 #233;rst=1;complete_boot;frame;frame;$display("CHECK initial ready t%0t",$time);
 fault=1;cycles(12);fault=0;
 if(!d.recovery_fallback || !d.media_mem_reset_n || d.reload_display_pix)$fatal(1,"reset before fallback frame");
 fork
 begin frame;frame;end
 begin wait(!d.media_mem_reset_n);images=0;end
 join
 $display("CHECK fallback t%0t state%0d reset%b ack%b",$time,d.u_recovery.state,d.media_mem_reset_n,d.recovery_ack);
 if(!d.reload_display_pix || !d.pix_reset_n || !d.sys_reset_n || !d.serial_reset_n)$fatal(1,"shared reset damages display/UI");
 wait(d.media_mem_reset_n);images=1;complete_boot;
 frame;frame;frame;
 if(d.recovery_fallback || d.reload_display_pix || d.recovery_retries!=1)$fatal(1,"first recovery failed");
 // A second fault is contained in an operable fallback; no endless reset loop.
 fault=1;cycles(10);fault=0;frame;frame;cycles(10);
 wait(d.recovery_failed);cycles(10);
 if(d.reload_busy || d.media_mem_reset_n || d.recovery_retries!=1)$fatal(1,"STOP loop or UI locked");
 manual=1;cycles(1);manual=0;images=0;
 wait(d.recovery_retries==2);wait(d.media_sys_reset_n);images=1;complete_boot;frame;frame;frame;
 if(d.recovery_failed || d.reload_display_pix)$fatal(1,"manual recovery failed");
 // UART parser output boundary supplies real floor data; missing updates go stale.
 force d.elev_floor_value=8'd12;force d.elev_floor_basement=1'b0;
 force d.elev_direction=2'd1;force d.elev_door=2'd2;force d.elev_alert_value=1'b0;
 force d.elev_update_valid=1'b1;cycles(1);release d.elev_update_valid;
 if(d.elev_signal_lost_sys || d.elev_floor_sys!=12)$fatal(1,"floor update");
 i=0;while(i<4990)begin @(posedge clk);if(d.tick_ms)i=i+1;end
 if(d.elev_signal_lost_sys)$fatal(1,"floor stale too early");
 i=0;while(i<15)begin @(posedge clk);if(d.tick_ms)i=i+1;end
 if(!d.elev_signal_lost_sys || d.elev_floor_sys!=12)$fatal(1,"floor stale handling");
 $display("PASS recovery top: frame fallback before shared reset, HDMI/UI reset continuity, finite auto retry, STOP manual reload and 5s floor expiry");$finish;
end
initial begin #2000000;$fatal(1,"recovery top timeout state%0d boot%0d",d.u_recovery.state,d.boot_state);end
endmodule
