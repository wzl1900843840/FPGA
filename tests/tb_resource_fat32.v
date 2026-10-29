`timescale 1ns/1ps
module tb_resource_fat32;
reg clk=0;always #5 clk=~clk;reg rst=0,start=0;
wire done,req;wire[31:0]lba,part,fat,data,maxcl,c0,c1,c2,c3,z0,z1,z2,z3;wire[7:0]spc,err;wire[4:0]valid;
reg busy=0,sv=0,sd=0;reg [7:0] sector_error=0;reg[7:0]byte_in=0;reg[8:0]bi=0;
fat32_volume_scanner dut(.clk(clk),.rst_n(rst),.scan_start(start),.scan_done(done),.fs_error(err),
.partition_lba(part),.sectors_per_cluster(spc),.fat_start_lba(fat),.data_start_lba(data),.max_cluster(maxcl),
.resource_valid(valid),.resource0_cluster(c0),.resource1_cluster(c1),.resource2_cluster(c2),.resource3_cluster(c3),
.resource0_size(z0),.resource1_size(z1),.resource2_size(z2),.resource3_size(z3),
.sector_req(req),.sector_lba(lba),.sector_busy(busy),.sector_valid(sv),.sector_byte(byte_in),.sector_byte_index(bi),.sector_done(sd),.sector_error(sector_error));
wire done_ref,req_ref;wire [31:0] lba_ref,part_ref,fat_ref,data_ref,maxcl_ref,c0_ref,c1_ref,c2_ref,c3_ref,z0_ref,z1_ref,z2_ref,z3_ref;wire [7:0]spc_ref,err_ref;wire [4:0]valid_ref;
fat32_volume_scanner_baseline reference(.clk(clk),.rst_n(rst),.scan_start(start),.scan_done(done_ref),.fs_error(err_ref),
.partition_lba(part_ref),.sectors_per_cluster(spc_ref),.fat_start_lba(fat_ref),.data_start_lba(data_ref),.max_cluster(maxcl_ref),
.resource_valid(valid_ref),.resource0_cluster(c0_ref),.resource1_cluster(c1_ref),.resource2_cluster(c2_ref),.resource3_cluster(c3_ref),
.resource0_size(z0_ref),.resource1_size(z1_ref),.resource2_size(z2_ref),.resource3_size(z3_ref),
.sector_req(req_ref),.sector_lba(lba_ref),.sector_busy(busy),.sector_valid(sv),.sector_byte(byte_in),.sector_byte_index(bi),.sector_done(sd),.sector_error(sector_error));

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
// Repeated raw scans exercise fresh fields, signature/BPB errors and read faults.
for(scenario=5;scenario<=10;scenario=scenario+1)begin
part_base=0;requests=0;disk[511]=8'haa;disk[12]=2;sector_error=0;
case(scenario)
5:disk[511]=0;
6:disk[12]=4;
7:sector_error=8'h10;
default:;
endcase
@(negedge clk);start=1;@(negedge clk);start=0;wait(done);#1;
if(scenario==5&&err!=8'h20)$fatal(1,"bad signature accepted");
if(scenario==6&&err!=8'h21)$fatal(1,"bad BPB accepted");
if(scenario==7&&err!=8'h10)$fatal(1,"sector error lost");
if(scenario>=8&&(err||valid!=15))$fatal(1,"rescan stale fields");
end
$display("PASS resource FAT32: cycle-accurate I baseline match, four MBR slots, fragmented chain, repeated scans and error paths");$finish;
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
always @(posedge clk)begin #1;if(rst)begin
if({done,req,lba,part,fat,data,maxcl,c0,c1,c2,c3,z0,z1,z2,z3,spc,err,valid}!==
   {done_ref,req_ref,lba_ref,part_ref,fat_ref,data_ref,maxcl_ref,c0_ref,c1_ref,c2_ref,c3_ref,z0_ref,z1_ref,z2_ref,z3_ref,spc_ref,err_ref,valid_ref})
$fatal(1,"FAT32 baseline cycle mismatch scenario%0d",scenario);end end
initial begin #1000000;$fatal(1,"watchdog");end
endmodule
