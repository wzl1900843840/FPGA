`timescale 1ns/1ps
module tb_thumbnail;
reg clk=0;always #5 clk=~clk;
reg rst=0,r=0,l=0,c=0,m=0,fs=0;reg [3:0] complete=4'b0101;
wire mode,t,selected;wire[1:0]focus,active;
thumbnail_controller dut(clk,rst,r,l,c,m,complete,fs,mode,focus,active,t,selected);
task pulse;input integer kind;begin @(negedge clk);case(kind)0:m=1;1:r=1;2:l=1;3:c=1;4:fs=1;endcase
@(negedge clk);m=0;r=0;l=0;c=0;fs=0;end endtask
initial begin #12;rst=1;
pulse(0);if(mode)$fatal(1,"mode changed midframe");pulse(4);if(!mode)$fatal;
pulse(1);if(focus!=0)$fatal(1,"focus changed midframe");pulse(4);if(focus!=1)$fatal;
pulse(3);pulse(4);if(!mode||selected)$fatal(1,"invalid bank selected");
// 未加载焦点1 -> 同一帧移动到已加载焦点2并确认。
pulse(1);pulse(3);if(!mode)$fatal; pulse(4);if(mode ||active!=2||!t||!selected)$fatal(1,"selection commit");
pulse(0);pulse(4);pulse(2);pulse(2);pulse(2);pulse(4);if(focus!=3)$fatal(1,"wrap");
$display("PASS thumbnail: frame commit, unavailable bank, wrap");$finish;end
endmodule
