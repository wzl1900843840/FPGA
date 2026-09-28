`timescale 1ns/1ps
module tb_card;
reg clk=0,rst=0,start=0;always #5 clk=~clk;
wire req,done;wire[31:0]lba;wire[7:0]err;wire[3:0]valid;
reg busy=0,sv=0,sd=0;reg[7:0]b=0;reg[8:0]bi=0;
fat32_volume_scanner d(.clk(clk),.rst_n(rst),.scan_start(start),.scan_done(done),.fs_error(err),.resource_valid(valid),
.sector_req(req),.sector_lba(lba),.sector_busy(busy),.sector_valid(sv),.sector_byte(b),.sector_byte_index(bi),.sector_done(sd),.sector_error(8'd0));
reg[7:0]sectors[0:3583];integer i,j,slot;reg[31:0]a;
initial begin $readmemh("D:/FPGA/anlu/example_code111/lab_ex4_tf/tests/card_snapshot/sectors.hex",sectors);#21;rst=1;
@(negedge clk);start=1;@(negedge clk);start=0;wait(done);#1;
if(err||valid!=15)$fatal(1,"real card metadata scan error=%h valid=%h",err,valid);
$display("PASS card metadata: production FAT32 scanner found all four PIC files");
for(j=512;j<3584;j=j+32)
if(sectors[j]=="P" && sectors[j+1]=="I" && sectors[j+2]=="C")sectors[j]="X";
@(negedge clk);start=1;@(negedge clk);start=0;wait(done);#1;
if(err!=8'h22 ||valid!=0)$fatal(1,"original names should fail 22, got %h %h",err,valid);
$display("PASS original filenames reproduce fs_error=22 (top-level error80)");$finish;end
initial forever begin wait(req);a=lba;slot=-1;case(a)
32'd0:slot=0;
32'd16384:slot=1;
32'd16385:slot=2;
32'd16386:slot=3;
32'd16387:slot=4;
32'd16388:slot=5;
32'd16389:slot=6;
endcase
if(slot<0)$fatal(1,"snapshot lacks requested LBA %d",a);
@(negedge clk);busy=1;for(i=0;i<512;i=i+1)begin @(negedge clk);sv=1;bi=i;b=sectors[slot*512+i];end
@(negedge clk);sv=0;sd=1;@(negedge clk);sd=0;busy=0;end
initial begin #1000000;$fatal(1,"card watchdog");end
endmodule
