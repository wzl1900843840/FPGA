`timescale 1ns/1ps
module tb_emergency_top;
reg clk=0,rst=0;always #10 clk=~clk;reg[3:0]sw=0;reg fs=0;
reg [4:0] images=31; reg [63:0] cfg={4'd0,4'd0,8'd128,8'd255,8'd0,32'd5000};
reg uart_alarm=0,right=0;
top #(.SW_DEBOUNCE_CYCLES(100),.UI_CLKS_PER_MS(10)) d(.clk(clk),.rst_n(rst),.key1(1'b1),.key2(1'b1),.key3(1'b1),
 .sw(sw),.uart_rx(1'b1),.sd_miso(1'b1),.flash_miso(1'b1));
task frame;begin repeat(20)@(negedge d.pixel_clk);fs=1;@(negedge d.pixel_clk);fs=0;repeat(4)@(negedge d.pixel_clk);end endtask
integer i;reg[1:0]saved_focus;
initial begin
 force d.frame_start=fs;force d.complete_pix=images;force d.config_pix=cfg;
 force d.cache_ready_pix=1'b1;force d.player_enable=1'b0;force d.elev_alert_sys=uart_alarm;
 force d.next_pix=right;
 #233;rst=1;repeat(140)@(negedge clk);frame;frame;frame;
 `ifdef BOOT_METRICS_TEST
 force d.card_ready=1'b0;force d.scan_complete=1'b0;force d.image_complete=5'd0;force d.first_tf_pixel=1'b0;
 force d.boot_elapsed_ms=16'd100;@(negedge clk);force d.card_ready=1'b1;repeat(3)@(negedge clk);
 force d.boot_elapsed_ms=16'd200;force d.scan_complete=1'b1;repeat(3)@(negedge clk);
 force d.boot_elapsed_ms=16'd300;force d.image_complete=5'd1;repeat(3)@(negedge clk);
 force d.boot_elapsed_ms=16'd320;force d.first_tf_pixel=1'b1;repeat(12)@(negedge clk);
 force d.boot_elapsed_ms=16'd600;force d.image_complete=5'd17;repeat(3)@(negedge clk);
 if(d.boot_metrics!=={5'd31,16'd100,16'd200,16'd300,16'd320,16'd600})$fatal(1,"boot milestone snapshot");
 force d.boot_elapsed_ms=16'd900;repeat(10)@(negedge clk);
 if(d.boot_sd_ms!=100 || d.boot_tf_ms!=320)$fatal(1,"milestones overwritten");
 release d.boot_elapsed_ms;@(negedge clk);
 if(d.boot_elapsed_ms!=900)$fatal(1,"counter advanced after all captures");
 force d.boot_milestone_valid=5'd0;force d.boot_ms_div=16'd49999;force d.boot_elapsed_ms=16'd65534;
 @(negedge clk);release d.boot_elapsed_ms;release d.boot_ms_div;
 @(negedge clk);
 if(d.boot_elapsed_ms!=65535 || d.boot_ms_div!=0)$fatal(1,"millisecond carry/saturation");
 repeat(10)@(negedge clk);if(d.boot_elapsed_ms!=65535)$fatal(1,"elapsed counter wrapped");
 $display("PASS boot milestones: five sticky timestamps, synchronized first TF pixel, freeze after capture");$finish;
 `endif
 // Exercise the new K4 action at its pixel command boundary. Physical
 // debounce/long press is covered separately by tb_demo_ui.
 force d.command_valid_pix=1'b1;force d.command_pix=3'd4;
 @(negedge d.pixel_clk);release d.command_valid_pix;release d.command_pix;
 frame;frame;frame;
 if(!d.display_view || !d.effective_display_view)$fatal(1,"thumbnail entry failed pending%b visible%b cancel%b alert%b reload%b",d.u_thumbnail.pending_mode,d.view_mode,d.thumb_cancel,d.elevator_alert_pix,d.reload_display_pix);
 right=1;@(negedge d.pixel_clk);right=0;frame;saved_focus=d.focus_index;
 uart_alarm=1;repeat(5)@(negedge d.pixel_clk);frame;
 if(!d.elevator_alert_pix_state || d.effective_display_view || d.show_info_pix)$fatal(1,"thumbnail emergency takeover failed");
 frame;if(d.active_index!==4)$fatal(1,"emergency picture >2 frames");
 right=1;repeat(2)@(negedge d.pixel_clk);right=0;frame;
 if(d.focus_index!==saved_focus || !d.display_view)$fatal(1,"thumbnail context not saved");
 uart_alarm=0;repeat(5)@(negedge d.pixel_clk);frame;frame;frame;
 if(!d.effective_display_view || d.focus_index!==saved_focus)$fatal(1,"thumbnail context restore failed");
 // Service menu remains subordinate to an active UART alarm.
 cfg[63:60]=2;frame;frame;uart_alarm=1;repeat(5)@(negedge d.pixel_clk);frame;
 if(d.show_info_pix || !d.elevator_alert_pix_state)$fatal(1,"menu covered emergency");
 uart_alarm=0;repeat(5)@(negedge d.pixel_clk);frame;frame;frame;
 if(!d.show_info_pix)$fatal(1,"menu restore failed");
 // Local SW4: reject high and low bounces; UART/local are an OR.
 sw=4;repeat(120)@(negedge clk);sw=12;repeat(30)@(negedge clk);sw=4;repeat(120)@(negedge clk);
 if(d.local_alert_latched)$fatal(1,"short high bounce accepted");
 sw=12;repeat(120)@(negedge clk);if(!d.local_alert_latched)$fatal(1,"stable SW4 not accepted");
 uart_alarm=1;sw=4;repeat(30)@(negedge clk);sw=12;repeat(120)@(negedge clk);
 if(!d.local_alert_latched)$fatal(1,"short low bounce cleared alarm");
 sw=4;repeat(120)@(negedge clk);if(d.local_alert_latched || !d.elev_alert_request_sys)$fatal(1,"OR lost UART source");
 uart_alarm=0;repeat(5)@(negedge clk);if(d.elev_alert_request_sys)$fatal(1,"both cleared but alarm stuck");
 sw=12;repeat(120)@(negedge clk);sw=14;repeat(120)@(negedge clk);
 if(!d.local_alert_latched)$fatal(1,"menu mode silently cleared SW4 alarm");
 sw=2;repeat(120)@(negedge clk);if(d.local_alert_latched)$fatal(1,"stable low did not clear");
 $display("PASS emergency top: thumbnail/menu takeover and restore, saved focus, two-edge debounce, overlapping sources, mode-change latch");$finish;
end
initial begin #500000;$fatal(1,"emergency top timeout");end
endmodule
