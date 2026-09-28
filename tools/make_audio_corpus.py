"""WAV -> 48 kHz, signed 16-bit little-endian mono PCM (tutorial lesson 11)."""
from pathlib import Path
import argparse
import wave
import numpy as np

def convert(path):
    with wave.open(str(path), 'rb') as w:
        channels, width, rate = w.getnchannels(), w.getsampwidth(), w.getframerate()
        raw = w.readframes(w.getnframes())
    if width == 1:
        data = (np.frombuffer(raw, np.uint8).astype(np.float64)-128)*256
    elif width in (2, 4):
        data = np.frombuffer(raw, '<i'+str(width)).astype(np.float64)/(256**(width-2))
    elif width == 3:
        b = np.frombuffer(raw, np.uint8).reshape(-1, 3).astype(np.int32)
        v = b[:, 0] | b[:, 1] << 8 | b[:, 2] << 16
        data = ((v ^ 0x800000)-0x800000).astype(np.float64)/256
    else:
        raise ValueError('Only uncompressed integer PCM WAV (8/16/24/32 bit) is supported')
    data = data.reshape(-1, channels).mean(axis=1)
    if len(data) == 0:
        raise ValueError('Empty WAV')
    if rate != 48000:
        from scipy.signal import resample_poly
        from math import gcd
        d = gcd(rate, 48000)
        data = resample_poly(data, 48000//d, rate//d)
    return np.clip(np.rint(data), -32768, 32767).astype('<i2').tobytes()

if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('input', type=Path)
    p.add_argument('output', type=Path)
    a = p.parse_args()
    data = convert(a.input)
    a.output.write_bytes(data)
    print(f'{len(data)//2} samples, {len(data)/96000:.3f} seconds; 48kHz/16bit/mono')
