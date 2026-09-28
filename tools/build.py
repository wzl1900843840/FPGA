"""Build with TD, check routed timing, and publish only a verified local release."""
from pathlib import Path
import argparse, subprocess, re, json, hashlib, shutil, time

ROOT=Path(__file__).resolve().parents[1]
def reviewed_warning(line,log):
    if 'PHY-7002' in line and 'U3/sdram' in line:
        return True  # Fixed hard macro; TD legalizes its initial location.
    if 'PHY-5079' in line and 'Marked 1 clock net(s)' in line:
        # Tutorial PLL intentionally drives only the SDRAM hard-macro clock
        # from its phase-shifted output without a fabric global buffer.
        return bool(re.search(r'mem_clk_shift\s*\|\s*AL_PHY_PLL\s*\|\s*0/1\s*\|\s*1\s*\|\s*U3/u2_ram/SDRAM_CLK\s*\|\s*true',log))
    return False
def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--td-root',type=Path,default=Path('E:/Anlogic/TD_6.2.1_Engineer_6.2.168.116'))
    p.add_argument('--collect',action='store_true',help='Verify and collect an already finished build (no synthesis)')
    a=p.parse_args();project=ROOT/'src/td_project';build=project/'build_complete'
    top_text=(ROOT/'src/user_source/hdl_source/top_tf_hdmi_audio.v').read_text(encoding='utf-8')
    pcm_enabled=int(all(int(re.search(r'parameter \[31:0\] '+key+r'=(\d+)',top_text)[1])!=0
                        for key in ('PCM_START_LBA','PCM_TOTAL_SECTORS')))
    sdc=ROOT/'src/user_source/constraints_source/timing.sdc'
    sdc_text=sdc.read_text(encoding='utf-8')
    from pcm_constraints import configure_text
    sdc_updated=configure_text(sdc_text,pcm_enabled)
    if sdc_text!=sdc_updated:
        if a.collect:raise RuntimeError('PCM constraint mode does not match RTL; rebuild')
        sdc.write_text(sdc_updated,encoding='utf-8')
    inputs=[x for x in (ROOT/'src/user_source').rglob('*') if x.suffix.lower() in ('.v','.vh','.adc','.sdc')]
    inputs += [project/'lab_ex5_i2s_v1.0.al',project/'build_complete.tcl',project/'place_route_complete.tcl']
    latest_source=max(x.stat().st_mtime for x in inputs)
    input_hashes={str(x.relative_to(ROOT)):hashlib.sha256(x.read_bytes()).hexdigest() for x in sorted(inputs)}
    if not a.collect:
        for script,logname in [('build_complete.tcl','build_console.log'),('place_route_complete.tcl','place_route_console.log')]:
            print('Running '+script,flush=True)
            with (project/logname).open('w',encoding='utf-8') as f:
                result=subprocess.run([str(a.td_root/'bin/td_commands_prompt.exe'),script],cwd=project,stdout=f,stderr=subprocess.STDOUT)
            if result.returncode:raise RuntimeError(f'{script} exit {result.returncode}: inspect {logname}')
            log=(project/logname).read_text(encoding='utf-8',errors='replace')
            if re.search(r'\b(?:ERROR|FATAL)\s*:',log):raise RuntimeError('TD error: '+logname)
            critical=[line for line in log.splitlines() if 'CRITICAL-WARNING' in line and not reviewed_warning(line,log)]
            if critical:raise RuntimeError('\n'.join(critical))
    bit=build/'lab_ex4_tf_complete.bit';timing=build/'complete_pr.timing'
    if any(hashlib.sha256((ROOT/name).read_bytes()).hexdigest()!=value for name,value in input_hashes.items()):
        raise RuntimeError('Source changed during build; rerun to obtain a consistent release')
    if min(bit.stat().st_mtime,timing.stat().st_mtime)<latest_source:
        raise RuntimeError('Build is older than RTL/constraints/project; rebuild before release')
    timing_text=timing.read_text(errors='replace')
    values={key:float(re.search(key+r':\s*(-?[\d.]+)ns',timing_text)[1]) for key in ('SWNS','STNS','HWNS','HTNS')}
    if any(value<0 for value in values.values()):raise RuntimeError('Routed timing failed: '+str(values))
    # Keep IP/tool warnings visible; never label this a zero-warning build.
    warnings=[]
    for name in ['build_console.log','place_route_console.log']:
        log=(project/name).read_text(encoding='utf-8',errors='replace')
        if re.search(r'\b(?:ERROR|FATAL)\s*:',log):raise RuntimeError('TD error in '+name)
        if any('CRITICAL-WARNING' in line and not reviewed_warning(line,log) for line in log.splitlines()):
            raise RuntimeError('Unreviewed critical warning in '+name)
        warnings += [line for line in log.splitlines() if 'WARNING' in line]
    release=ROOT/'release';release.mkdir(exist_ok=True)
    for path in [bit,timing,build/'complete_phy.area',build/'complete_phy.ts',project/'build_console.log',project/'place_route_console.log']:
        shutil.copy2(path,release/path.name)
    manifest={'built_at':time.strftime('%Y-%m-%d %H:%M:%S'), 'timing_ns':values,
        'bit_sha256':hashlib.sha256(bit.read_bytes()).hexdigest(),
        'sources':input_hashes,
        'warnings':warnings,'hardware_tested':False}
    (release/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps({'release':str(release),'timing_ns':values,'bit_sha256':manifest['bit_sha256']},indent=2))
if __name__=='__main__':main()
