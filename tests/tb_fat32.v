`timescale 1ns/1ps
module tb_fat32;
reg clk=0;always #5 clk=~clk;reg rst=0,start=0;
wire done,req;wire[31:0]lba,part,fat,data,maxcl,c0,c1,c2,c3,z0,z1,z2,z3;wire[7:0]spc,err;wire[4:0]valid;
reg busy=0,sv=0,sd=0;reg[7:0]byte_in=0;reg[8:0]bi=0;
fat32_volume_scanner dut(.clk(clk),.rst_n(rst),.scan_start(start),.scan_done(done),.fs_error(err),
.partition_lba(part),.sectors_per_cluster(spc),.fat_start_lba(fat),.data_start_lba(data),.max_cluster(maxcl),
.resource_valid(valid),.resource0_cluster(c0),.resource1_cluster(c1),.resource2_cluster(c2),.resource3_cluster(c3),
.resource0_size(z0),.resource1_size(z1),.resource2_size(z2),.resource3_size(z3),
.sector_req(req),.sector_lba(lba),.sector_busy(busy),.sector_valid(sv),.sector_byte(byte_in),.sector_byte_index(bi),.sector_done(sd),.sector_error(8'd0));
reg[7:0]disk[0:4607];integer i,j,base,requests=0,part_base=0,scenario=0;reg[31:0]address;
task entry;input integer offset,id,cluster;begin
disk[offset]="P";disk[offset+1]="I";disk[offset+2]="C";disk[offset+3]="1"+id;
for(j=4;j<8;j=j+1)disk[offset+j]=" ";disk[offset+8]="B";disk[offset+9]="M";disk[offset+10]="P";
disk[offset+11]=8'h20;disk[offset+26]=cluster;disk[offset+28]=8'h36;disk[offset+29]=8'h10;
end endtask
initial begin
for(i=0;i<4608;i=i+1)disk[i]=0;
disk[0]=8'heb;disk[12]=2;disk[13]=2;disk[14]=1;disk[16]=1;disk[32]=8'he8;disk[33]=3;disk[36]=1;disk[44]=2;disk[510]=8'h55;disk[511]=8'haa;
// root cluster2 spans LBA2,3. No zero end marker until chained cluster5.
for(i=0;i<32;i=i+1)disk[1024+i*32]=8'he5;
entry(1536,0,10);entry(1568,1,11);disk[512+8]=5;
entry(4096,2,12);entry(4128,3,13);
#12;rst=1;@(negedge clk);start=1;@(negedge clk);start=0;
wait(done);#1;
if(err ||valid!=15 ||c0!=10||c1!=11||c2!=12||c3!=13||fat!=1||data!=2||requests!=5)$fatal(1,"scan err%h valid%h requests%d",err,valid,requests);
for(scenario=1;scenario<=4;scenario=scenario+1)begin
part_base=2048;requests=0;
@(negedge clk);start=1;@(negedge clk);start=0;wait(done);#1;
if(err || valid!=15 || part!=2048 ||fat!=2049||data!=2050||requests!=6)
$fatal(1,"MBR slot%d err%h valid%h part%d requests%d",scenario,err,valid,part,requests);
end
part_base=0;requests=0;
disk[17]=1;
@(negedge clk);start=1;@(negedge clk);start=0;wait(done);#1;
if(err!=8'h21 || valid!=0)$fatal(1,"invalid root-entry BPB accepted");
disk[17]=0;disk[22]=1;
@(negedge clk);start=1;@(negedge clk);start=0;wait(done);#1;
if(err!=8'h21 || valid!=0)$fatal(1,"FAT16 BPB accepted");
disk[22]=0;disk[510]=0;
@(negedge clk);start=1;@(negedge clk);start=0;wait(done);#1;
if(err!=8'h20 || valid!=0)$fatal(1,"bad boot signature accepted");
$display("PASS FAT32: raw BPB, MBR with EB jump and FAT32 in each of four slots, fragmented root chain");$finish;
end
initial forever begin
wait(req);address=lba;requests=requests+1;@(posedge clk);#1;busy=1;
if(address!=0 && (address<part_base || address>part_base+8))$fatal(1,"unexpected lba%d",address);
for(i=0;i<512;i=i+1)begin @(negedge clk);sv=1;bi=i;if(part_base!=0 && address==0)begin
byte_in=0;
if(i==0)byte_in=8'heb;
if(i==510)byte_in=8'h55;
if(i==511)byte_in=8'haa;
if(i==450+(scenario-1)*16)byte_in=8'h0c;
if(i==455+(scenario-1)*16)byte_in=8'h08;
if(i==459+(scenario-1)*16)byte_in=8'h04;
end else byte_in=disk[(address-part_base)*512+i];end
@(negedge clk);sv=0;sd=1;@(negedge clk);sd=0;busy=0;
end
initial begin #1000000;$fatal(1,"watchdog");end
endmodule
