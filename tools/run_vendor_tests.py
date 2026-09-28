"""Run focused tests using licensed vendor IP simulation and an SDRAM bus model."""
from pathlib import Path
import subprocess,json,time

r=Path(__file__).resolve().parents[1];p=r/'src/td_project'
out=r/'tests/results/vendor_checks';out.mkdir(parents=True,exist_ok=True)
lib=out/'work';ms=Path('E:/altera/14.1/modelsim_ase/win32aloem')
td=Path('E:/Anlogic/TD_6.2.1_Engineer_6.2.168.116/sim_release/eg4')
chip=Path('D:/FPGA/anlu/5_软件工具及驱动/lab_ex_2025_7_12_nosoft/HX4S20C_lab_ex/lab_ex_4_tf_sdram_etnernet_pc/source_code/model/IS42s32200.v')
inc=r/'src/user_source/hdl_source/include';rtl=r/'src/user_source/rtl'
if not lib.exists():subprocess.run([str(ms/'vlib.exe'),str(lib)],check=True,capture_output=True)
groups=[(['-suppress','2121','+incdir+'+str(inc)],[inc/'sdr_as_ram.enc.v',inc/'sdr_init_ref.enc.v',inc/'sdr_wrrd.enc.v',r/'src/user_source/hdl_source/SD/sdram.v',chip,r/'tests/sdram_chip_model.v']),
 ([],[td/'eg_phy_pll.v',td/'eg_logic_clk.v',rtl/'sys_pll_promax_40.v',r/'tests/tb_pll_clocks.v']),
 (['-sv'],[rtl/'media_sdram_write_cdc.v',rtl/'thumbnail_cache_builder.v',r/'tests/tb_vendor_sdram.v',r/'tests/tb_vendor_cdc.v',r/'tests/tb_vendor_cache.v'])]
with (out/'compile.log').open('w') as f:
 for flags,files in groups:
  c=subprocess.run([str(ms/'vlog.exe'),'-work',str(lib)]+flags+[str(x) for x in files],cwd=p,stdout=f,stderr=subprocess.STDOUT)
  if c.returncode:raise RuntimeError('See '+str(out/'compile.log'))
cases=[('tb_pll_clocks',[],'locked=1'),('tb_vendor_sdram',['+GAP=999','+BURSTS=256','+GATE'],'PASS vendor SDRAM'),
 ('tb_vendor_cdc',['+GAP=999','+BURSTS=1024','+GATE','+PACE'],'PASS vendor SDRAM'),('tb_vendor_cache',[],'PASS vendor cache')]
results=[]
for top,args,expected in cases:
 print('Running '+top,flush=True);start=time.time();log=out/(top+'.log')
 with (out/(top+'_console.log')).open('w') as f:
  c=subprocess.run([str(ms/'vsim.exe'),'-c','-onfinish','exit','-lib',str(lib),top]+args+['-l',str(log),'-do','run -all; quit -f'],cwd=p,stdout=f,stderr=subprocess.STDOUT,timeout=300)
 text=log.read_text(errors='replace');ok=c.returncode==0 and expected in text and not any(x in text for x in ('ERROR:','FAIL','** Fatal:','** Error:'))
 results.append(dict(test=top,passed=ok,seconds=time.time()-start));print('PASS' if ok else text[-2500:],flush=True)
(out/'summary.json').write_text(json.dumps(results,indent=2))
raise SystemExit(0 if all(x['passed'] for x in results) else 1)
