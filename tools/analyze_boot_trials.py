"""Read measured cold-start CSV; never infer hardware passes from simulation."""
from pathlib import Path
import argparse,csv,json,statistics
from rescue_receiver import BOOT_METRICS

FIELDS=('variant','cluster_sectors','trial','card_id','media_sha256','bit_sha256','commit','result','boot_raw','pattern_ms','display_ms','notes')

def assess(rows):
    required={('checkpoint',8),('candidate',1),('candidate',8),('candidate',16)}
    groups={key:[] for key in required};display={key:[] for key in required}
    identities=set();versions={};seen=set();failures=[]
    for number,row in enumerate(rows,2):
        try:
            key=(row['variant'],int(row['cluster_sectors']))
            if key not in groups:raise ValueError('unsupported variant/cluster')
            trial=int(row['trial'])
            if trial<1 or (key,trial) in seen:raise ValueError('invalid/duplicate trial')
            seen.add((key,trial))
            for field in ('card_id','commit'):
                if not row.get(field):raise ValueError('missing '+field)
            for field in ('media_sha256','bit_sha256'):
                value=row.get(field,'')
                if len(value)!=64 or any(c not in '0123456789abcdefABCDEF' for c in value):raise ValueError('invalid '+field)
            identities.add((row['card_id'],row['media_sha256'].lower()))
            version=(row['bit_sha256'].lower(),row['commit'])
            if row['variant'] in versions and versions[row['variant']]!=version:raise ValueError('mixed firmware in variant')
            versions[row['variant']]=version
            if row['result']!='PASS':raise ValueError('hardware trial not PASS')
            display_ms=float(row['display_ms'])
            if not 0<display_ms<600000:raise ValueError('invalid external first-complete-image measurement')
            if row['variant']=='checkpoint':
                # The known-good stage-5 firmware predates BOOT?. Compare the
                # same external complete-image boundary across both versions.
                display[key].append(display_ms)
                continue
            match=BOOT_METRICS.fullmatch(row['boot_raw'].rstrip('\r\n')+'\r\n')
            if not match:raise ValueError('missing/invalid BOOT snapshot')
            sd,scan,p1,tf,p5,valid=map(lambda x:int(x,16),match.groups())
            if valid!=31 or max(sd,scan,p1,tf,p5)==65535:raise ValueError('incomplete/saturated timestamps')
            if not sd<=scan<=p1<=tf or p5<p1:raise ValueError('inconsistent milestone order')
            groups[key].append(tf)
            display[key].append(display_ms)
        except (ValueError,KeyError) as error:
            failures.append(dict(csv_row=number,error=str(error)))
    if len(identities)>1:failures.append(dict(error='card/media differ across trials'))
    missing=[f'{v}/{s}: {len(values)}/5' for (v,s),values in sorted(display.items()) if len(values)<5]
    medians={f'{v}/{s}':statistics.median(values) for (v,s),values in sorted(groups.items()) if values}
    external={f'{v}/{s}':statistics.median(values) for (v,s),values in sorted(display.items()) if values}
    ready=not failures and not missing
    report=dict(status='READY_FOR_OPERATOR_REVIEW' if ready else 'PENDING_HARDWARE_DATA',
                metric='internal TF first accepted PIC1 pixel, ms since system reset release',
                medians_ms=medians,external_complete_image_medians_ms=external,
                failures=failures,missing=missing,recommended_cluster_sectors=8,
                counts={f'{v}/{s}':len(values) for (v,s),values in sorted(display.items())})
    if ready:
        best=min((1,8,16),key=lambda s:medians[f'candidate/{s}'])
        baseline=medians['candidate/8'];best_value=medians[f'candidate/{best}']
        improvement=(baseline-best_value)/baseline if baseline else 0
        selected=best if improvement>0.05 else 8
        report.update(recommended_cluster_sectors=selected,improvement_vs_candidate_8=improvement,
                      first_image_not_regressed=external[f'candidate/{selected}']<=external['checkpoint/8'],
                      note='Software statistics only; visual stability, alarms, complete frames and external display timing require operator signoff')
    return report

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('csv',type=Path)
    p.add_argument('--output',type=Path);a=p.parse_args()
    with a.csv.open(encoding='utf-8-sig',newline='') as stream:report=assess(list(csv.DictReader(stream)))
    output=json.dumps(report,ensure_ascii=False,indent=2);print(output)
    if a.output:a.output.write_text(output,encoding='utf-8')
    raise SystemExit(0 if report['status']=='READY_FOR_OPERATOR_REVIEW' and report['first_image_not_regressed'] else 2)

if __name__=='__main__':main()
