"""Read-only FAT-chain reconstruction of the four BMPs on the current F: card."""
from pathlib import Path
import ctypes,struct,hashlib,json
from ctypes import wintypes as w

root=Path(__file__).resolve().parents[1]
meta=json.loads((root/'tests/card_snapshot/metadata.json').read_text(encoding='utf-8'))
drive=meta['drive'];k=ctypes.WinDLL('kernel32',use_last_error=True)
k.CreateFileW.argtypes=[w.LPCWSTR,w.DWORD,w.DWORD,w.LPVOID,w.DWORD,w.DWORD,w.HANDLE];k.CreateFileW.restype=w.HANDLE
k.ReadFile.argtypes=[w.HANDLE,w.LPVOID,w.DWORD,ctypes.POINTER(w.DWORD),w.LPVOID]
k.SetFilePointerEx.argtypes=[w.HANDLE,ctypes.c_longlong,ctypes.POINTER(ctypes.c_longlong),w.DWORD]
k.CloseHandle.argtypes=[w.HANDLE]
h=k.CreateFileW('\\\\.\\'+drive+':',0x80000000,3,None,3,0,None)
if h==ctypes.c_void_p(-1).value:raise ctypes.WinError(ctypes.get_last_error())
def read(offset,size):
 b=ctypes.create_string_buffer(size);n=w.DWORD()
 if not k.SetFilePointerEx(h,offset,None,0):raise ctypes.WinError(ctypes.get_last_error())
 if not k.ReadFile(h,b,size,ctypes.byref(n),None) or n.value!=size:raise RuntimeError('Incomplete raw volume read')
 return b.raw
results=[]
try:
 boot=read(0,512);spc=boot[13];reserved=struct.unpack_from('<H',boot,14)[0]
 fat_size=struct.unpack_from('<I',boot,36)[0];data=reserved+boot[16]*fat_size
 for i in range(1,5):
  name=f'PIC{i}.BMP';e=next(e for e in meta['entries'] if e['short_name']==f'PIC{i}    BMP')
  cluster=e['cluster'];remaining=e['bytes'];raw=bytearray();seen=set()
  while remaining:
   if cluster<2 or cluster>=0xffffff8 or cluster in seen:raise RuntimeError('Invalid/short/looping FAT chain')
   seen.add(cluster);chunk=read((data+(cluster-2)*spc)*512,spc*512)
   raw.extend(chunk[:remaining]);remaining=max(0,remaining-len(chunk))
   sec=read((reserved+cluster//128)*512,512)
   cluster=struct.unpack_from('<I',sec,(cluster%128)*4)[0]&0xfffffff
  expected=(Path(drive+':/')/name).read_bytes()
  if raw!=expected:raise RuntimeError(name+' raw FAT content differs from OS file')
  results.append(dict(file=name,clusters=len(seen),bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest(),passed=True))
finally:k.CloseHandle(h)
(root/'tests/results/card_file_verification.json').write_text(json.dumps(dict(scope='read-only volume FAT and all bitmap bytes; physical MBR excluded',files=results),indent=2))
print(json.dumps(results,indent=2))
