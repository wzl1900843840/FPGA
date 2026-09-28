`timescale 1ns/1ps
module tb_local_pattern;
reg clk=0,rst=0,key2=0;
`ifdef FIFO_DIAG
reg[3:0]sw=12;
`else
reg[3:0]sw=8;
`endif
always #10 clk=~clk;
top d(.clk(clk)
,.rst_n(rst),.key1(1'b1),.key2(key2),.key3(1'b1),.sw(sw),
.uart_rx(1'b1),.sd_miso(1'b1),.flash_miso(1'b1));
integer pixels=0,frames=0;reg checking=0;reg[23:0]expected;integer x,y;
always @(posedge d.pixel_clk) if(checking) begin
 if(d.diag_local_pix!==1'b1 || d.player_enable!==0 || d.u_storage.start!==0 ||
    d.U3.App_rd_en!==0 || d.U3.App_wr_en!==0 || d.video_rd!==0 ||
    d.u_video.u_reader.issued_count_mem!==0 || d.u_video.u_reader.returned_count_mem!==0 ||
    d.u_video.u_reader.inflight_count_mem!==0 ||
    (!d.diag_fifo_pix && (d.u_video.u_reader.fifo_write_enable!==0 || d.u_video.u_reader.pixel_consume!==0)))
    $fatal(1,"diagnostic isolation broken");
 if(d.de_adjust) begin
 x=d.x_adjust;y=d.y_adjust;
 if(y<240) case(x/80)
 0:expected=24'hffffff;1:expected=24'hffff00;2:expected=24'h00ffff;3:expected=24'h00ff00;
 4:expected=24'hff00ff;5:expected=24'hff0000;6:expected=24'h0000ff;7:expected=0;
 default:$fatal(1,"bad x");endcase
 else if(y<360) expected=(x%256)*24'h010101;
 else if(x<512) expected=((x%256)<<16)|((y%256)<<8)|((x^y)%256);
 else expected=(((x/8)^(y/8))%2)?24'hffffff:0;
 if(d.u_audio.video_rgb!==expected) $fatal(1,"pattern mismatch x=%d y=%d",x,y);
 pixels=pixels+1;
 end
end
initial begin
 #200;rst=1;
 wait(d.diag_local_pix);key2=1;sw=0;
`ifdef FIFO_DIAG
 wait(d.diag_fifo_mem);
 // Inject returns directly at reader: synth mode must reject them itself.
 force d.u_video.u_reader.sdram_rd_valid=1'b1;
 force d.u_video.u_reader.sdram_rd_data=32'hdeadbeef;
`endif
 @(posedge d.frame_start);checking=1;
 @(posedge d.frame_start);checking=0;
`ifdef FIFO_DIAG
 if(d.u_video.reader_underflow || d.u_video.u_reader.reader_error ||
    d.u_video.u_reader.diag_written_count_mem!=307200)$fatal(1,"FIFO diagnostic count/underflow");
 release d.u_video.u_reader.sdram_rd_valid;
 release d.u_video.u_reader.sdram_rd_data;
`endif
 if(pixels!=307200)$fatal(1,"frame pixels %d",pixels);
 // Normal reset exits diagnostic and permits storage boot again.
 rst=0;#200;rst=1;

 wait(d.ingest_start);
 if(d.diag_local_sys!==0 || d.diag_local_pix!==0)$fatal(1,"normal boot stuck in diagnostic");
 $display("PASS local_pattern: 307200 RGB pixels; no TF start or SDRAM R/W; diagnostic isolation and normal reboot verified");$finish;
end
initial begin #40000000;$fatal(1,"timeout");end
endmodule
// Boundary devices only. Force unsolicited SDRAM returns to verify they are ignored.
module sys_pll_promax_40(input refclk,reset,output clk0_out,output reg clk1_out=0,
 output reg clk2_out=0,output reg clk3_out=0,output reg clk4_out=0,output locked);
assign clk0_out=clk4_out;assign locked=!reset;
always #12.5 clk1_out=~clk1_out;
always #12.5 clk2_out=~clk2_out;
always #20 clk3_out=~clk3_out;
always #4 clk4_out=~clk4_out;
endmodule
module sdram(input Clk,Clk_sft,Rst,output Sdr_init_done,Sdr_init_ref_vld,Sdr_busy,
 input App_wr_en,input[20:0]App_wr_addr,input[3:0]App_wr_dm,input[31:0]App_wr_din,
 input App_rd_en,input[20:0]App_rd_addr,output Sdr_rd_en,output[31:0]Sdr_rd_dout);
assign Sdr_init_done=!Rst;assign Sdr_init_ref_vld=0;assign Sdr_busy=0;
assign Sdr_rd_en=!Rst;assign Sdr_rd_dout=32'hdeadbeef;
endmodule
module EG_LOGIC_ODDR(input clk,rst,d0,d1,output reg q);
always @(clk or posedge rst) if(rst) q=0;else q=clk?d0:d1;
endmodule
