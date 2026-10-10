`timescale 1ns/1ps
module tb_thumbnail_layout;
reg de=1;
reg [11:0] x=4095,y=4095;
reg [1:0] focus=0;
reg [3:0] complete=15;
wire td,border;
wire [1:0] bank;
wire [9:0] sx,sy;
integer px,py,f,b,lx,ly,visible,edge_pixel;
thumbnail_layout dut(de,x,y,focus,complete,td,bank,sx,sy,border);
initial begin
 for(f=0;f<4;f=f+1)begin
  focus=f;
  for(py=0;py<480;py=py+1)for(px=0;px<640;px=px+1)begin
   x=px;y=py;#1;
   visible=px>=160 && px<480 && py>=120 && py<360;
   if(td!==visible[0])$fatal(1,"visibility x%0d y%0d",px,py);
   if(visible)begin
    b=((py-120)/120)*2+(px-160)/160;
    lx=(px-160)%160;ly=(py-120)%120;
    edge_pixel=b==f && (lx<2 || lx>=158 || ly<2 || ly>=118);
    if(bank!==b[1:0] || sx!==lx*4 || sy!==ly*4 || border!==edge_pixel[0])
     $fatal(1,"layout x%0d y%0d focus%0d",px,py,f);
   end else if(border)$fatal(1,"border outside centered grid");
  end
 end
 complete=4'b0101;
 x=320;y=120;#1;if(td || border)$fatal(1,"missing bank visible");
 x=160;y=240;#1;if(!td || bank!=2)$fatal(1,"valid bank hidden");
 de=0;#1;if(td || border)$fatal(1,"blanking visible");
 x=640;y=480;de=1;#1;if(td || border)$fatal(1,"outside display visible");
 $display("PASS thumbnail layout: centered grid, all pixels/foci, source coordinates, missing bank, blanking");
 $finish;
end
endmodule
