import sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from analyze_boot_trials import assess

def trials(candidate=(900,1000,950)):
    rows=[]
    for variant,cluster,tf in [('checkpoint',8,1100),*[( 'candidate',s,t) for s,t in zip((1,8,16),candidate)]]:
        for n in range(1,6):
            rows.append(dict(variant=variant,cluster_sectors=str(cluster),trial=str(n),card_id='fixture-only',
                             media_sha256='a'*64,bit_sha256=('b' if variant=='candidate' else 'c')*64,
                             commit=variant,result='PASS',display_ms=str(tf+200),
                             boot_raw=f'BOOT,SD=0064,SC=00C8,P1=012C,TF={tf:04X},P5=05DC,V=1F'))
    return rows

class BootTrials(unittest.TestCase):
    def test_no_data_is_pending(self):
        self.assertEqual(assess([])['status'],'PENDING_HARDWARE_DATA')
    def test_select_and_five_percent_rule(self):
        self.assertEqual(assess(trials())['recommended_cluster_sectors'],1)
        self.assertEqual(assess(trials((950,1000,980)))['recommended_cluster_sectors'],8)
    def test_errors_not_discarded(self):
        rows=trials();rows[0]['result']='FAIL'
        self.assertEqual(assess(rows)['status'],'PENDING_HARDWARE_DATA')
    def test_reject_mixed_card_and_duplicate(self):
        rows=trials();rows[0]['card_id']='different'
        self.assertTrue(assess(rows)['failures'])
        rows=trials();rows.append(rows[0]);self.assertTrue(assess(rows)['failures'])
    def test_regression_remains_failure(self):
        self.assertFalse(assess(trials((1300,1400,1500)))['first_image_not_regressed'])
    def test_invalid_and_saturated_metrics(self):
        for raw in ('bad','BOOT,SD=0064,SC=00C8,P1=012C,TF=FFFF,P5=05DC,V=1F'):
            rows=trials();rows[5]['boot_raw']=raw
            self.assertTrue(assess(rows)['failures'])
    def test_checkpoint_predates_boot_query(self):
        rows=trials()
        for row in rows[:5]:row['boot_raw']=''
        self.assertEqual(assess(rows)['status'],'READY_FOR_OPERATOR_REVIEW')

if __name__=='__main__':unittest.main()
