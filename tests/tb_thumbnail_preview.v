`timescale 1ns/1ps
module tb_thumbnail_preview;
reg clk=0;always #5 clk=~clk;
reg rst=0,start=0;
wire busy,done,re,we;
wire [7:0] error;
wire [20:0] ra,wa;
wire [31:0] wd;
reg rv=0;
reg [31:0] rd=0;
reg [23:0] photo[0:1228799];
reg [11:0] px=4095,py=4095;
wire td,border;
wire [1:0] bank;
wire [9:0] sx,sy;
reg [1023:0] input_file,output_file;
integer fd,count=0,pos,x,y,b,address;
reg [23:0] expected,rendered;
thumbnail_cache_builder dut(clk,rst,start,4'b1111,busy,done,error,re,ra,rv,rd,we,wa,wd,1'b0,1'b0,1'b1,,);
thumbnail_layout layout(1'b1,px,py,2'd0,4'b1111,td,bank,sx,sy,border);
always @(posedge clk)begin
 rv<=re;
 if(re)rd<={8'd0,photo[ra]};
end
always @(negedge clk)if(we)begin
 if(wa!==1228800+count)$fatal(1,"nonsequential cache write");
 pos=count;x=pos%640;y=pos/640;expected=0;
 if(x>=160 && x<480 && y>=120 && y<360)begin
  b=((y-120)/120)*2+(x-160)/160;
  address=b*307200+((y-120)%120)*4*640+((x-160)%160)*4;
  expected=photo[address];
 end
 if(wd!=={8'd0,expected})$fatal(1,"photo sample x%0d y%0d",x,y);
 px=x;py=y;#1;
 if(td && photo[bank*307200+sy*640+sx]!==expected)$fatal(1,"layout/cache misalignment");
 rendered=border?24'hffff00:wd[23:0];
 $fwrite(fd,"%c%c%c",rendered[23:16],rendered[15:8],rendered[7:0]);
 count=count+1;
end
initial begin
 if(!$value$plusargs("PHOTOS=%s",input_file) || !$value$plusargs("OUTPUT=%s",output_file))$fatal(1,"missing fixture paths");
 $readmemh(input_file,photo);
 fd=$fopen(output_file,"wb");if(!fd)$fatal(1,"preview output");
 $fwrite(fd,"P6\n640 480\n255\n");
 #12;rst=1;@(negedge clk);start=1;@(negedge clk);start=0;
 wait(done);#2;
 if(error || count!=307200)$fatal(1,"incomplete thumbnail preview");
 $fclose(fd);
 $display("PASS thumbnail preview: all four real photos, 307200 cache pixels, layout/cache alignment");
 $finish;
end
initial begin #30000000;$fatal(1,"preview watchdog");end
endmodule
