"""Resource-round compatibility tests against the retained I baseline."""
from pathlib import Path
import json, subprocess, time
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build_out/resource_compatibility'
OUT.mkdir(parents=True,exist_ok=True)
RTL=ROOT/'src/user_source/rtl'
IV='D:/iverilog/bin/iverilog.exe'
VVP='D:/iverilog/bin/vvp.exe'
BASE='fullchain-I-delivery-20261029'
results=[]
def baseline(name):
    source=subprocess.run(['git','show',BASE+':src/user_source/rtl/'+name+'.v'],cwd=ROOT,capture_output=True,check=True).stdout.decode('utf-8')
    target=OUT/(name+'_baseline.v')
    target.write_text(source.replace('module '+name,'module '+name+'_baseline',1),encoding='utf-8')
    return target
def run(name,files,parameters=(),label=None):
    start=time.time();binary=OUT/(name+'.vvp')
    c=subprocess.run([IV,'-g2012','-s','tb_'+name,*parameters,'-o',str(binary),str(ROOT/'tests'/('tb_'+name+'.v'))]+list(map(str,files)),cwd=ROOT,capture_output=True,text=True)
    log=c.stdout+c.stderr
    if c.returncode==0:
        c=subprocess.run([VVP,str(binary)],cwd=ROOT,capture_output=True,text=True,timeout=240);log+=c.stdout+c.stderr
    ok=c.returncode==0 and 'PASS ' in log and 'FATAL' not in log
    (OUT/((label or name)+'.log')).write_text(log,encoding='utf-8')
    results.append(dict(test=label or name,passed=ok,seconds=round(time.time()-start,2)))
    print(log,flush=True)
    (OUT/'summary.json').write_text(json.dumps(results,indent=2),encoding='utf-8')
    if not ok:raise SystemExit(1)
run('resource_config',[RTL/'config_journal.v'])
run('resource_uart',[RTL/'uart_status_reporter.v',RTL/'uart_tx_byte.v',baseline('uart_status_reporter')])
run('resource_fat32',[RTL/'fat32_volume_scanner.v',baseline('fat32_volume_scanner')])
for n in (1,12,16,256):
    run('resource_store',[RTL/'w25q64_record_store.v',RTL/'spi_byte_engine.v',ROOT/'tests/spi_flash_model.v'],['-P','tb_resource_store.N='+str(n)],'resource_store_'+str(n))
run('resource_wave',[RTL/'promax_audio_waveform.v',baseline('promax_audio_waveform')])
