#!/usr/bin/env python3
# Convert firmware.hex ($readmemh format) to Quartus .mif format
# Usage: hex2mif.py firmware.hex nwords > firmware.mif

import sys

hexfile = sys.argv[1]
nwords = int(sys.argv[2])

with open(hexfile, 'r') as f:
    lines = f.readlines()

print(f"WIDTH=32;")
print(f"DEPTH={nwords};")
print()
print("ADDRESS_RADIX=HEX;")
print("DATA_RADIX=HEX;")
print()
print("CONTENT BEGIN")

for i in range(nwords):
    if i < len(lines):
        val = lines[i].strip()
        if val == '0' or val == '':
            val = '00000000'
        print(f"\t{i:04X} : {val};")
    else:
        print(f"\t{i:04X} : 00000000;")

print("END;")
