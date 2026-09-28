"""Read-only Windows FAT32 metadata snapshot for the production scanner test.
Never formats, writes, locks, dismounts or ejects the card.
"""
from pathlib import Path
import argparse,ctypes,struct,json
from ctypes import wintypes as w
ROOT=Path(__file__).resolve().parents[1]
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--drive',default='F');a=p.parse_args()
    drive=a.drive.rstrip(':\\/').upper()
    if len(drive)!=1 or not drive.isalpha():raise ValueError('Expected drive letter')
    k=ctypes.WinDLL('kernel32',use_last_error=True)
    k.CreateFileW.argtypes=[w.LPCWSTR,w.DWORD,w.DWORD,w.LPVOID,w.DWORD,w.DWORD,w.HANDLE];k.CreateFileW.restype=w.HANDLE
    k.DeviceIoControl.argtypes=[w.HANDLE,w.DWORD,w.LPVOID,w.DWORD,w.LPVOID,w.DWORD,ctypes.POINTER(w.DWORD),w.LPVOID]
    k.ReadFile.argtypes=[w.HANDLE,w.LPVOID,w.DWORD,ctypes.POINTER(w.DWORD),w.LPVOID]
    k.SetFilePointerEx.argtypes=[w.HANDLE,ctypes.c_longlong,ctypes.POINTER(ctypes.c_longlong),w.DWORD]
    k.CloseHandle.argtypes=[w.HANDLE]
    def open_read(path):
        h=k.CreateFileW(path,0x80000000,3,None,3,0,None)
        if h==ctypes.c_void_p(-1).value:raise ctypes.WinError(ctypes.get_last_error())
        return h
    def ioctl(h,code):
        b=ctypes.create_string_buffer(256);n=w.DWORD()
        if not k.DeviceIoControl(h,code,None,0,b,256,ctypes.byref(n),None):raise ctypes.WinError(ctypes.get_last_error())
        return b.raw[:n.value]
    volume=open_read('\\\\.\\'+drive+':')
    try:
        device=struct.unpack_from('<III',ioctl(volume,0x2d1080))[1]
        partition=struct.unpack_from('<q',ioctl(volume,0x70048),8)[0]//512
    finally:k.CloseHandle(volume)
    physical_partition=partition
    # Windows通常允许卷内只读访问，却拒绝物理盘访问。回退时直接验证
    # 真实卷BPB/目录/FAT，不伪造MBR，也不声称验证过卡的分区表。
    try:
        disk=open_read('\\\\.\\PhysicalDrive'+str(device));snapshot_scope='physical_disk_metadata'
    except PermissionError:
        disk=open_read('\\\\.\\'+drive+':');partition=0;snapshot_scope='volume_metadata_only'
    sectors={}
    def read(lba):
        if lba in sectors:return sectors[lba]
        b=ctypes.create_string_buffer(512);n=w.DWORD()
        if not k.SetFilePointerEx(disk,lba*512,None,0):raise ctypes.WinError(ctypes.get_last_error())
        if not k.ReadFile(disk,b,512,ctypes.byref(n),None) or n.value!=512:raise RuntimeError('Sector read failed')
        sectors[lba]=b.raw;return b.raw
    entries=[]
    try:
        mbr=read(0);boot=read(partition)
        le16=lambda o:struct.unpack_from('<H',boot,o)[0]
        le32=lambda o:struct.unpack_from('<I',boot,o)[0]
        if le16(11)!=512 or le16(17)!=0 or le16(22)!=0:raise ValueError('Not supported FAT32')
        spc=boot[13];fat=partition+le16(14);data=fat+boot[16]*le32(36);cluster=le32(44)
        seen=set();ended=False
        while not ended:
            if cluster in seen or len(seen)>=32:raise ValueError('Root chain loop/too large')
            seen.add(cluster)
            for offset in range(spc):
                block=read(data+(cluster-2)*spc+offset)
                for i in range(0,512,32):
                    e=block[i:i+32]
                    if e[0]==0:ended=True;break
                    if e[0]==0xe5 or e[11]==0x0f:continue
                    entries.append({'short_name':e[:11].decode('ascii',errors='replace'),'attribute':e[11],
                        'cluster':struct.unpack_from('<H',e,20)[0]*65536+struct.unpack_from('<H',e,26)[0],
                        'bytes':struct.unpack_from('<I',e,28)[0]})
                if ended:break
            if not ended:
                block=read(fat+cluster//128);cluster=struct.unpack_from('<I',block,(cluster%128)*4)[0]&0x0fffffff
                if cluster>=0x0ffffff8:ended=True
    finally:k.CloseHandle(disk)
    out=ROOT/'tests/card_snapshot';out.mkdir(exist_ok=True)
    manifest={'drive':drive,'physical_disk':device,'read_only':True,'partition_lba':physical_partition,
        'snapshot_scope':snapshot_scope,'snapshot_partition_lba':partition,
        'snapshot_sector0_first_byte':hex(mbr[0]),'spc':spc,'fat_lba':fat,'data_lba':data,'entries':entries,'sector_lbas':list(sectors)}
    (out/'metadata.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
    (out/'sectors.hex').write_text('\n'.join(f'{v:02x}' for data in sectors.values() for v in data)+'\n')
    case='\n'.join(f"32'd{lba}:slot={n};" for n,lba in enumerate(sectors))
    test=f'''`timescale 1ns/1ps
module tb_card;
reg clk=0,rst=0,start=0;always #5 clk=~clk;
wire req,done;wire[31:0]lba;wire[7:0]err;wire[3:0]valid;
reg busy=0,sv=0,sd=0;reg[7:0]b=0;reg[8:0]bi=0;
fat32_volume_scanner d(.clk(clk),.rst_n(rst),.scan_start(start),.scan_done(done),.fs_error(err),.resource_valid(valid),
.sector_req(req),.sector_lba(lba),.sector_busy(busy),.sector_valid(sv),.sector_byte(b),.sector_byte_index(bi),.sector_done(sd),.sector_error(8'd0));
reg[7:0]sectors[0:{len(sectors)*512-1}];integer i,j,slot;reg[31:0]a;
initial begin $readmemh("{(out/'sectors.hex').as_posix()}",sectors);#21;rst=1;
@(negedge clk);start=1;@(negedge clk);start=0;wait(done);#1;
if(err||valid!=15)$fatal(1,"real card metadata scan error=%h valid=%h",err,valid);
$display("PASS card metadata: production FAT32 scanner found all four PIC files");
for(j=512;j<{len(sectors)*512};j=j+32)
if(sectors[j]=="P" && sectors[j+1]=="I" && sectors[j+2]=="C")sectors[j]="X";
@(negedge clk);start=1;@(negedge clk);start=0;wait(done);#1;
if(err!=8'h22 ||valid!=0)$fatal(1,"original names should fail 22, got %h %h",err,valid);
$display("PASS original filenames reproduce fs_error=22 (top-level error80)");$finish;end
initial forever begin wait(req);a=lba;slot=-1;case(a)
{case}
endcase
if(slot<0)$fatal(1,"snapshot lacks requested LBA %d",a);
@(negedge clk);busy=1;for(i=0;i<512;i=i+1)begin @(negedge clk);sv=1;bi=i;b=sectors[slot*512+i];end
@(negedge clk);sv=0;sd=1;@(negedge clk);sd=0;busy=0;end
initial begin #1000000;$fatal(1,"card watchdog");end
endmodule
'''
    (out/'tb_card.v').write_text(test,encoding='utf-8');print(json.dumps(manifest,ensure_ascii=False,indent=2))
if __name__=='__main__':main()
