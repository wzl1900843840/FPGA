`timescale 1ns/1ps
module tb_elevator;
reg clk=0,rst=0,frame_start=0,startup_ready=0,media_fault=0,alert_request=0,alert_page_available=0;
wire alert_active,alert_fallback;wire [2:0] alert_page_index,state_code;
always #5 clk=~clk;
elevator_demo_controller dut(.clk(clk),.rst_n(rst),.frame_start(frame_start),
 .startup_ready(startup_ready),.media_fault(media_fault),.alert_request(alert_request),
 .alert_page_available(alert_page_available),.alert_active(alert_active),.alert_fallback(alert_fallback),
 .alert_page_index(alert_page_index),.state_code(state_code));
task frame;begin @(negedge clk);frame_start=1;@(negedge clk);frame_start=0;end endtask
initial begin
 #12;rst=1; if(state_code!==0)$fatal(1,"reset state");
 startup_ready=1;frame; if(state_code!==1 || alert_active)$fatal(1,"startup to normal");
 alert_request=1;frame; if(state_code!==2 || !alert_active || alert_page_index!==4 || !alert_fallback)$fatal(1,"alert entry/fallback");
 alert_page_available=1; #1; if(!alert_active || alert_fallback)$fatal(1,"alert page availability");
 alert_request=0;frame; if(state_code!==3 || alert_active)$fatal(1,"recovery state");
 frame; if(state_code!==1)$fatal(1,"recovery to normal");
 alert_request=1;frame;media_fault=1;frame; if(state_code!==4 || alert_active)$fatal(1,"fault state");
 media_fault=0;alert_request=0;frame; if(state_code!==1)$fatal(1,"fault recovery");
 $display("PASS elevator demo: startup, alert, fallback, recovery and fault states");$finish;
end
initial begin #100000;$fatal(1,"watchdog");end
endmodule

