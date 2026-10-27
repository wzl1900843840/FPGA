"""Protocol/journal tests for the demo receiver; no physical port is opened."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location("rescue_receiver",ROOT/"tools/rescue_receiver.py")
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
REPORT=b"RESCUE,ID=0001,A=1,F=05,D=U,DO=C,S=L,E=00\r\n"

class FakeJournal:
    def __init__(self):self.rows=[];self.fail=False
    def write(self,row):
        if self.fail:raise OSError("disk full")
        self.rows.append(row)

class ReceiverTests(unittest.TestCase):
    def test_boot_metrics(self):
        log=FakeJournal();events=[];sent=[]
        engine=module.Receiver(log,sent.append,events.append)
        engine.new_session("test")
        engine.receive(b"BOOT,SD=0065,SC=00DC,P1=033E,TF=0352,P5=05DC,V=1F\r\n")
        self.assertEqual(events[-1]["kind"],"boot_metrics")
        self.assertEqual(events[-1]["tf_ms"],850)
        self.assertEqual(events[-1]["valid"],31)
        self.assertFalse(sent)

    def setUp(self):
        self.log=FakeJournal();self.sent=[];self.events=[];self.now=0
        self.receiver=module.Receiver(self.log,self.sent.append,self.events.append,lambda:self.now)
        self.receiver.new_session("test")

    def test_persist_then_ack_and_duplicate(self):
        def send(data):
            self.assertEqual(self.log.rows[-1]["kind"],"rescue")
            self.sent.append(data)
        self.receiver.send=send
        self.receiver.receive(REPORT);self.receiver.poll()
        self.receiver.receive(REPORT);self.receiver.poll()
        self.assertEqual(self.sent,[b"ACK=0001\r\n"]*2)
        self.assertEqual(len(self.receiver.seen),1)
        self.assertTrue(self.events[-2]["duplicate"])

    def test_delay_and_auto_off(self):
        self.receiver.delay=2
        self.receiver.receive(REPORT);self.receiver.poll();self.assertEqual(self.sent,[])
        self.now=1.99;self.receiver.poll();self.assertEqual(self.sent,[])
        self.now=2;self.receiver.poll();self.assertEqual(len(self.sent),1)
        self.receiver.auto_ack=False;self.receiver.receive(REPORT)
        self.now=9;self.receiver.poll();self.assertEqual(len(self.sent),1)

    def test_invalid_and_conflicting_duplicate(self):
        for report in [REPORT[:-2],REPORT.replace(b"F=05",b"F=AA"),REPORT.replace(b"ID=0001",b"ID=XYZ1"),REPORT+b"junk"]:
            self.receiver.receive(report)
        self.assertEqual(self.receiver.seen,{})
        self.receiver.receive(REPORT);self.receiver.poll()
        self.receiver.receive(REPORT.replace(b"F=05",b"F=06"));self.receiver.poll()
        self.assertEqual(len(self.sent),1)
        self.assertEqual(self.events[-1]["kind"],"invalid")

    def test_clear_reconnect_and_boot_cancel_delayed_ack(self):
        self.receiver.delay=1;self.receiver.receive(REPORT)
        clear=REPORT.replace(b"ID=0001,A=1",b"ID=0002,A=0")
        self.receiver.receive(clear);self.now=2;self.receiver.poll();self.assertEqual(self.sent,[])
        self.receiver.receive(REPORT);old=self.receiver.session
        self.receiver.new_session("reconnect");self.assertNotEqual(old,self.receiver.session)
        self.now=5;self.receiver.poll();self.assertEqual(self.sent,[])
        self.receiver.receive(REPORT);self.receiver.receive(module.BOOT.encode())
        self.now=8;self.receiver.poll();self.assertEqual(self.sent,[])
        self.receiver.receive(REPORT);self.now=10;self.receiver.poll();self.assertEqual(len(self.sent),1)

    def test_disk_failure_prevents_ack(self):
        self.log.fail=True
        with self.assertRaises(OSError):self.receiver.receive(REPORT)
        self.receiver.poll();self.assertEqual(self.sent,[])

    def test_state_query_and_utf8_csv(self):
        self.receiver.receive(b"RESCUE,ID=0001,A=1,C=ACKED\r\n")
        self.assertEqual(self.events[-1]["state"],"ACKED")
        with tempfile.TemporaryDirectory() as directory:
            source=Path(directory)/"log.jsonl";target=Path(directory)/"log.csv"
            journal=module.Journal(source);journal.write(dict(kind="session",session="中文会话"));journal.close()
            module.export_log(source,target)
            self.assertIn("中文会话",target.read_text(encoding="utf-8-sig"))

    def test_serial_worker_partial_reads_and_reconnect(self):
        import queue
        captures=[]
        class FakeSerial:
            def __init__(self,*args,**kwargs):
                self.chunks=[REPORT[:9],REPORT[9:24],REPORT[24:],REPORT]
            def __enter__(self):return self
            def __exit__(self,*args):pass
            def read(self,n):
                if self.chunks:return self.chunks.pop(0)
                worker.stop_event.set();return b""
            def write(self,data):captures.append(data);return len(data)
            def flush(self):pass
        with tempfile.TemporaryDirectory() as directory,patch("serial.Serial",FakeSerial):
            events=queue.Queue();commands=queue.Queue();path=Path(directory)/"serial.jsonl"
            sessions=[]
            for _ in range(2):
                worker=module.SerialWorker("FAKE",events,commands,path);worker.run()
                while not events.empty():
                    event=events.get_nowait()
                    self.assertNotEqual(event["kind"],"error")
                    if event["kind"]=="session":sessions.append(event["session"])
            self.assertEqual(captures,[b"ACK=0001\r\n"]*4)
            self.assertEqual(len(set(sessions)),2)

if __name__=="__main__":unittest.main(verbosity=2)
