`timescale 1ns/1ps
module tb_waveform;
reg clk=0,rst=0,vs=1,de=0,enable=1,valid=0;
always #20 clk=~clk;
reg [23:0] in_rgb=24'h305070;
reg [9:0] x=0;
reg signed [15:0] sample=0;
wire [23:0] rgb;wire active;
promax_audio_waveform dut(clk,rst,vs,de,in_rgb,x,enable,valid,sample,rgb,active);
reg [23:0] background[0:307199];reg [15:0] samples[0:63];
reg [1023:0] background_file,sample_file,output_file;
integer i,j,y,fd,peak,held,first_bank;
task frame;begin
 @(negedge clk);vs=0;de=0;repeat(2)@(negedge clk);vs=1;@(negedge clk);
end endtask
task capture;input integer mode;begin
 for(i=0;i<512;i=i+1)begin
  @(negedge clk);valid=1;
  case(mode)0:sample=samples[i/8];1:sample=(i/8)%2 ? -16'sd32768:16'sd32767;
  2:sample=0;default:sample=16'sd4096;endcase
 end
 @(negedge clk);valid=0;
 if(dut.capture_count!=64)$fatal(1,"decimation/capture count");
end endtask
task scan_line;input integer ly;input integer save;begin
 for(j=0;j<640;j=j+1)begin
  de=1;x=j;in_rgb=background[ly*640+j];#1;
  if((^rgb)===1'bx)$fatal(1,"unknown rendered color x%d y%d",j,ly);
  if(!active && rgb!==in_rgb)$fatal(1,"out of panel RGB changed");
  if(active && !(j>=64 && j<600 && ly>=400 && ly<464))$fatal(1,"panel escaped bounds");
  if(save)$fwrite(fd,"%c%c%c",rgb[23:16],rgb[15:8],rgb[7:0]);
  @(negedge clk);
 end
 de=0;repeat(2)@(negedge clk);
end endtask
initial begin
 if(!$value$plusargs("BACKGROUND=%s",background_file) ||
    !$value$plusargs("SAMPLES=%s",sample_file) || !$value$plusargs("OUTPUT=%s",output_file))
  $fatal(1,"fixture paths required");
 $readmemh(background_file,background);$readmemh(sample_file,samples);
 #51;rst=1;frame;capture(0);
 if(dut.display_valid)$fatal(1,"capture published mid-frame");
 frame;
 if(!dut.display_valid || dut.display_bank==dut.write_bank)$fatal(1,"bank publication");
 first_bank=dut.display_bank;peak=dut.display_peak;
 // Capturing into the other bank must not alter the visible bank or VU.
 capture(1);
 if(dut.display_bank!=first_bank || dut.display_peak!=peak)$fatal(1,"mid-frame visible update");
 fd=$fopen(output_file,"wb");$fwrite(fd,"P6\n640 480\n255\n");
 for(y=0;y<480;y=y+1)scan_line(y,1);
 $fclose(fd);
 frame;
 if(dut.display_peak!=128 || dut.held_peak!=128)$fatal(1,"negative full-scale peak");
 // Full-scale samples must clamp within the panel; interpolated trace stays bounded.
 for(y=0;y<400;y=y+1)begin de=1;@(negedge clk);de=0;repeat(2)@(negedge clk);end
 de=1;x=72;#1;if(dut.sample_y!=59)$fatal(1,"negative displacement clamp %d",dut.sample_y);
 x=80;#1;if(dut.sample_y!=5)$fatal(1,"positive displacement clamp %d",dut.sample_y);
 enable=0;#1;if(rgb!==in_rgb || active)$fatal(1,"enable bypass");enable=1;de=0;
 capture(2);frame;
 if(dut.display_peak!=126 || dut.held_peak!=128 || dut.hold_frames!=11)$fatal(1,"peak release/hold");
 if(dut.silence_shift!=1 || dut.display_bank==dut.write_bank)$fatal(1,"silence visual decay / bank ownership");
 for(y=0;y<400;y=y+1)begin de=1;@(negedge clk);de=0;repeat(2)@(negedge clk);end
 de=1;x=72;#1;if(dut.sample_y!=46)$fatal(1,"negative visual decay");
 x=80;#1;if(dut.sample_y!=19)$fatal(1,"positive visual decay");de=0;
 held=dut.held_peak;
 repeat(12)begin capture(2);frame;end
 if(dut.held_peak!=held-1)$fatal(1,"held peak release");
 // Silence remains centered after publishing and has no stale samples.
 for(y=0;y<400;y=y+1)begin de=1;@(negedge clk);de=0;repeat(2)@(negedge clk);end
 de=1;x=128;#1;if(dut.sample_y!=32 || dut.trace_y!=32)$fatal(1,"silence center");
 $display("PASS waveform: bank isolation, decimation, signed clipping, silence, peak hold/release, panel bounds, rendered RTL");
 $finish;
end
initial begin #30000000;$fatal(1,"waveform watchdog");end
endmodule
