"""Compare only load order with identical five-file synthetic media and clocks."""
from pathlib import Path
import json,re,subprocess
r=Path(__file__).resolve().parents[1];out=r/'tests/results/priority_boot';out.mkdir(parents=True,exist_ok=True)
base=(r/'tests/tb_early_ingest.v').read_text()
base=base.replace('module tb_early_ingest;','module tb_priority_ingest;')
base=base.replace('wire [3:0] mask,mmask,complete,ready;','wire [3:0] mask,mmask;wire [4:0] complete,ready;')
base=base.replace('.EARLY_DISPLAY(1)) front(','.EARLY_DISPLAY(1),.PRIORITIZE_EMERGENCY(1)) front(')
base=base.replace('writes[0:3]','writes[0:4]').replace('reg [3:0] previous_ready=0;','reg [4:0] previous_ready=0;')
base=base.replace('integer k,bank,pos;','integer k,bank,pos;integer cycle=0,first_cycle=0,pic5_cycle=0,published=0;')
base=base.replace('always @(posedge sc) if(rst) begin','always @(posedge sc) if(rst) begin\n cycle=cycle+1;')
base=base.replace('for(k=0;k<4;k=k+1) if(ready[k]','for(k=0;k<5;k=k+1) if(ready[k]')
base=base.replace('if(writes[k]!=128)', '''if(published==0 && k!=FIRST_BANK) $fatal(1,"first bank priority");
     if(published==1 && k!=SECOND_BANK) $fatal(1,"second bank priority");
     published=published+1;if(k==0)first_cycle=cycle;if(k==4)pic5_cycle=cycle;
     if(writes[k]!=128)''')
base=base.replace('ready!=15','ready!=31').replace('if(n<4)','if(n<5)').replace('sector<=171','sector<=172')
base=base.replace('for(k=0;k<4;k=k+1)writes','for(k=0;k<5;k=k+1)writes')
base=base.replace('if(!saw_early || ready!=((tail_bad || abort_bad)?14:15))','if(!saw_early || ready!=31)')
base=base.replace('$display("PASS early ingest:', '$display("BOOT_SIM first_pic1_cycles=%0d pic5_cycles=%0d total_cycles=%0d",first_cycle,pic5_cycle,cycle);\n $display("PASS priority ingest:')
modules=['media_ingest_frontend','sd_sector_replay_buffer','media_ingest_pipeline','fat32_volume_scanner',
         'fat32_file_streamer','bmp24_decoder','media_frame_loader','media_sdram_write_cdc']
results={}
for legacy in (True,False):
    label='legacy_pic5_first' if legacy else 'pic1_first'
    tb=out/(label+'.v');tb.write_text(base.replace('FIRST_BANK','4' if legacy else '0').replace('SECOND_BANK','0' if legacy else '4'))
    files=[r/'src/user_source/rtl'/(name+'.v') for name in modules]
    if legacy:
        for module_name in ('media_ingest_frontend','media_ingest_pipeline'):
            prior=out/('legacy_'+module_name+'.v')
            prior.write_bytes(subprocess.check_output(['git','show','80dcde8:src/user_source/rtl/'+module_name+'.v'],cwd=r))
            files=[prior if f.stem==module_name else f for f in files]
    binary=out/(label+'.vvp')
    subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012','-s','tb_priority_ingest','-o',str(binary),str(tb)]+list(map(str,files)),check=True)
    p=subprocess.run(['D:/iverilog/bin/vvp.exe',str(binary)],capture_output=True,text=True,timeout=60)
    log=p.stdout+p.stderr;(out/(label+'.log')).write_text(log);print(log);p.check_returncode()
    match=re.search(r'first_pic1_cycles=(\d+) pic5_cycles=(\d+) total_cycles=(\d+)',log)
    if not match or 'PASS priority ingest:' not in log:raise RuntimeError('Priority check failed')
    results[label]=dict(zip(('pic1_cycles','pic5_cycles','total_cycles'),map(int,match.groups())))
if results['pic1_first']['pic1_cycles']>=results['legacy_pic5_first']['pic1_cycles']:raise RuntimeError('First image did not improve')
results['scope']='Synthetic 16x8 images, replay-sector model, identical clocks and bytes; not hardware boot time'
(out/'summary.json').write_text(json.dumps(results,indent=2))
