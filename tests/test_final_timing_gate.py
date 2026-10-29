"""Exercise the real Tcl acceptance gate without invoking physical tools."""
from pathlib import Path
import os
import tempfile
import tkinter
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'tools/repair_routed_hold.tcl'
CHECKS = '\n'.join('checking '+name+'(0)' for name in (
    'no clock', 'clock definition', 'invalid constraint',
    'combinational loops', 'no path constraints')) + (
    '\nThere are 0 clock pins that have no clock constraints'
    '\nThere are 0 clocks whose clock frequency do not match the PLL setting')


class FinalTimingGateTest(unittest.TestCase):
    def run_gate(self, timing, checks=CHECKS):
        calls = []
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder)
            (target/'settings.cfg').write_text('set device_name test\n'
                'set package_name test\nset prj_name test\n')
            (target/'test_phy.ts').write_text(timing)
            (target/'timing_checks.rpt').write_text(checks)
            interp = tkinter.Tcl()
            for command in ('import_device', 'open_project', 'import_db',
                    'report_param', 'fix_hold', 'update_timing',
                    'report_timing_status', 'report_timing_summary',
                    'check_timing', 'report_timing_exception', 'report_area',
                    'report_qor', 'flow_status', 'export_db', 'bitgen'):
                def capture(*args, name=command):
                    calls.append((name, args))
                    return ''
                interp.createcommand(command, capture)
            old = os.getcwd()
            try:
                os.chdir(target)
                try:
                    interp.call('source', SCRIPT.as_posix())
                    error = None
                except tkinter.TclError as exc:
                    error = str(exc)
            finally:
                os.chdir(old)
        return calls, error

    def test_pass_refreshes_qor_and_generates_bit(self):
        calls, error = self.run_gate('SWNS: 1.185ns, STNS: 0.000ns.\n'
                                    'HWNS: 0.021ns, HTNS: 0.000ns.')
        self.assertIsNone(error)
        names = [name for name, _ in calls]
        self.assertLess(names.index('fix_hold'), names.index('report_qor'))
        self.assertLess(names.index('report_qor'), names.index('bitgen'))
        self.assertEqual(names.count('bitgen'), 1)

    def test_negative_or_missing_timing_never_generates_bit(self):
        for key in ('SWNS', 'STNS', 'HWNS', 'HTNS'):
            for value in ('-0.001', 'NaN', None):
                with self.subTest(key=key, value=value):
                    timing='\n'.join(k+': '+(value if k==key else '0.021')+'ns'
                        for k in ('SWNS', 'STNS', 'HWNS', 'HTNS')
                        if k!=key or value is not None)
                    calls, error = self.run_gate(timing)
                    self.assertIn('FINAL_TIMING_REJECTED', error)
                    self.assertFalse(any(n=='bitgen' for n, _ in calls))

    def test_missing_or_failed_clock_checks_never_generate_bit(self):
        timing='SWNS: 1ns STNS: 0ns HWNS: 0.021ns HTNS: 0ns'
        bad_checks=[CHECKS.replace('('+str(0)+')', '(1)', 1),
                    CHECKS.replace('checking invalid constraint(0)', ''),
                    CHECKS.replace('There are 0 clock pins', 'There are 1 clock pins'),
                    CHECKS.replace('There are 0 clocks', 'There are 2 clocks'),
                    CHECKS.split('There are')[0]]
        for checks in bad_checks:
            with self.subTest(checks=checks):
                calls, error = self.run_gate(timing, checks)
                self.assertIn('FINAL_TIMING_REJECTED', error)
                self.assertFalse(any(n=='bitgen' for n, _ in calls))


if __name__ == '__main__':
    unittest.main()
