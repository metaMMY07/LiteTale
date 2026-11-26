"""Build the canonical BMP GBK query mapping using Python's standard codec."""
from pathlib import Path
import hashlib
import struct

root = Path(__file__).resolve().parents[1]
table = bytearray()
for lead in range(0x81, 0xFF):
    for trail in range(0x40, 0xFF):
        pair = bytes([lead, trail])
        value = 0
        try:
            char = pair.decode('gbk')
            if len(char) == 1 and ord(char) <= 0xFFFF and char.encode('gbk') == pair:
                value = ord(char)
        except UnicodeError:
            pass
        table += struct.pack('<H', value)
output = root / 'lib/assets/encodings/gbk-to-unicode.bin'
assert len(table) == 48132
output.parent.mkdir(parents=True, exist_ok=True)
output.write_bytes(table)
print(f'{output}: {len(table)} bytes, sha256={hashlib.sha256(table).hexdigest()}')
