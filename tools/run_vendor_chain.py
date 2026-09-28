"""Replay F: BMP contents through RTL and the vendor encrypted SDRAM controller.

The FAT32 transport is a synthetic sector image; bitmap bytes and pixel oracle
come from the actual files. IS42s32200 supplies the bus-level SDRAM chip model.
"""
from pathlib import Path
import argparse, subprocess, json, hashlib, time
from PIL import Image

root=Path(__file__).resolve().parents[1]
out=root/'tests/results/vendor_chain';out.mkdir(parents=True,exist_ok=True)
project=root/'src/td_project'
ms=Path('E:/altera/14.1/modelsim_ase/win32aloem')
chip=Path('D:/FPGA/anlu/5_软件工具及驱动/lab_ex_2025_7_12_nosoft/HX4S20C_lab_ex/lab_ex_4_tf_sdram_etnernet_pc/source_code/model/IS42s32200.v')
p=argparse.ArgumentParser();p.add_argument('--drive',default='F:/');p.add_argument('--video-only',action='store_true');p.add_argument('--output',default='vendor_chain_final');a=p.parse_args()
out=root/'tests/results'/a.output;out.mkdir(parents=True,exist_ok=True)
if a.video_only:out=root/'tests/results/vendor_video';out.mkdir(parents=True,exist_ok=True)
metadata=[];pixels=[];bitmap=bytearray()
for n in range(1,5):
 f=Path(a.drive)/f'PIC{n}.BMP';data=f.read_bytes();im=Image.open(f).convert('RGB')
 if im.size!=(640,480) or len(data)!=921654:raise ValueError('This fixture requires 640x480 24bpp BMP with 54-byte header')
 metadata.append(dict(file=str(f),sha256=hashlib.sha256(data).hexdigest()))
 bitmap.extend(data);pixels.extend((r<<16)|(g<<8)|b for r,g,b in im.getdata())
(out/'bmp.hex').write_text('\n'.join(f'{v:02x}' for v in bitmap)+'\n')
(out/'pixels.hex').write_text('\n'.join(f'{v:06x}' for v in pixels)+'\n')
s=(root/'tests/tb_chain.v').read_text()
s=s.replace('module tb_chain;','module tb_vendor_chain;\nwire vendor_init,vendor_busy,vendor_refresh;')
s=s.replace('function[23:0]pixel;input integer bank,x,y;begin pixel={x[7:0],y[7:0],8\'d5+bank[7:0]*8\'d40};end endfunction',f'''reg[7:0]bmp_bytes[0:3686615];reg[23:0]expected_pixels[0:1228799];
initial begin $readmemh("{(out/'bmp.hex').as_posix()}",bmp_bytes);$readmemh("{(out/'pixels.hex').as_posix()}",expected_pixels);end
function[23:0]pixel;input integer bank,x,y;begin pixel=expected_pixels[bank*307200+y*640+x];end endfunction''')
start=s.index('if(o<54)begin case(o)');end=s.index('end end endfunction',start)
s=s[:start]+'if(o<sz)diskbyte=bmp_bytes[b*921654+o];\n'+s[end:]
s=s.replace('reg rv=0;reg[31:0]rd=0;','wire rv;wire[31:0]rd;')
s=s.replace('always @(posedge mc)begin rv<=re;if(re)rd<=memory[ra];end','''reg msclk=0;initial begin #10;forever #12.5 msclk=~msclk;end
sdram vendor(.Clk(mc),.Clk_sft(msclk),.Rst(!rst),.Sdr_init_done(vendor_init),.Sdr_busy(vendor_busy),.Sdr_init_ref_vld(vendor_refresh),
.App_wr_en(mw),.App_wr_addr(mwa),.App_wr_dm(mmask),.App_wr_din(mwdata),
.App_rd_en(re),.App_rd_addr(ra),.Sdr_rd_en(rv),.Sdr_rd_dout(rd));''')
s=s.replace("mwdata,idle,1'b0,1'b0);", "mwdata,idle,vendor_busy,vendor_refresh);")
s=s.replace(".controller_init_done(prst),.controller_busy(1'b0),.refresh_active(1'b0)",".controller_init_done(prst),.controller_busy(vendor_busy),.refresh_active(vendor_refresh)")
s=s.replace('if(mwdata[23:0]!==expected)', 'if(writes%307200==0)begin $display("LOAD bank=%d",bank);$fflush();end\nif(mwdata[23:0]!==expected)')
s=s.replace('#51;rst=1;' ,'#51;rst=1;wait(vendor_init);')
s=s.replace('for(f=0;f<1228800;f=f+1) memory[f]=pixel(f/307200,(f%307200)%640,(f%307200)/640);','''for(f=0;f<1228800;f=f+1)begin
+case((f>>2)&3)
+0:vendor.sdram.chip.Bank0[((f>>4)<<2)|(f&3)]=expected_pixels[f];
+1:vendor.sdram.chip.Bank1[((f>>4)<<2)|(f&3)]=expected_pixels[f];
+2:vendor.sdram.chip.Bank2[((f>>4)<<2)|(f&3)]=expected_pixels[f];
+3:vendor.sdram.chip.Bank3[((f>>4)<<2)|(f&3)]=expected_pixels[f];
+endcase end'''.replace('\n+','\n'))
s=s.replace('PASS CHAIN:' ,'PASS VENDOR CHAIN:')
tb=out/'tb_vendor_chain.v';tb.write_text(s)
lib=out/'work'
if not lib.exists():subprocess.run([str(ms/'vlib.exe'),str(lib)],check=True,capture_output=True)
rtl=root/'src/user_source/rtl';inc=root/'src/user_source/hdl_source/include'
files=[str(x) for x in sorted(rtl.glob('*.v')) if x.name not in ['sys_pll_promax_40.v','global_def_125.v']]
groups=[(['-suppress','2121','+incdir+'+str(inc)],[str(inc/n) for n in ['sdr_as_ram.enc.v','sdr_init_ref.enc.v','sdr_wrrd.enc.v']]+[str(root/'src/user_source/hdl_source/SD/sdram.v'),str(chip),str(root/'tests/sdram_chip_model.v')]),
        (['-sv'],files+[str(root/'tests/lut1_model.v'),str(tb)])]
with (out/'compile.log').open('w') as log:
 for flags,group in groups:
  c=subprocess.run([str(ms/'vlog.exe'),'-work',str(lib)]+flags+group,cwd=project,stdout=log,stderr=subprocess.STDOUT)
  if c.returncode:raise RuntimeError('Compile failed: '+str(out/'compile.log'))
print('Running actual BMP files through vendor SDRAM and video/audio RTL',flush=True)
t=time.time()
with (out/'console.log').open('w') as log:
 c=subprocess.run([str(ms/'vsim.exe'),'-c','-onfinish','exit','-lib',str(lib),'tb_vendor_chain',*(['+VIDEO_ONLY'] if a.video_only else []),'-l',str(out/'transcript.log'),'-do','run -all; quit -f'],cwd=project,stdout=log,stderr=subprocess.STDOUT,timeout=1800)
log=(out/'transcript.log').read_text(errors='replace')
ok=c.returncode==0 and 'PASS VENDOR CHAIN:' in log and '# ** Fatal:' not in log and 'ERROR:' not in log
(out/'result.json').write_text(json.dumps(dict(passed=ok,seconds=time.time()-t,files=metadata,video_only=a.video_only,sources={str(Path(f).relative_to(root)):hashlib.sha256(Path(f).read_bytes()).hexdigest() for flags,group in groups for f in group if Path(f).is_relative_to(root/'src')},scope='actual BMP contents, synthetic FAT sectors, encrypted controller, bus-level SDRAM, pre-TMDS video and audio packet input'),indent=2))
print('\n'.join(log.splitlines()[-18:]),flush=True)
raise SystemExit(0 if ok else 1)
