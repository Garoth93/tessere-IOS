#!/usr/bin/env python3
"""Decodes the module strings dumped by BarcodeTests.testDumpForExternalDecoder
with zbar, to check the pure-Swift 1D encoders against an independent reader.

  docker run --rm -e DUMP_BARCODES=/src/packages/TessereCore/.build/barcodes.tsv \
    -v "$PWD":/src -w /src swift:6.0-noble swift test --package-path packages/TessereCore
  pip install pyzbar pillow  (+ libzbar0)
  python3 scripts/verify-barcodes.py packages/TessereCore/.build/barcodes.tsv
"""
import sys
from PIL import Image
from pyzbar.pyzbar import decode

ok = True
for line in open(sys.argv[1]).read().splitlines():
    fmt, text, modules = line.split("\t")
    scale, quiet, height = 4, 15, 120
    w = (len(modules) + 2 * quiet) * scale
    img = Image.new("L", (w, height), 255)
    px = img.load()
    for i, m in enumerate(modules):
        if m == "1":
            for dx in range(scale):
                for y in range(10, height - 10):
                    px[(quiet + i) * scale + dx, y] = 0
    res = decode(img)
    got = [(r.type, r.data.decode()) for r in res]
    expected = {text, "0" + text}
    if fmt == "upcE":  # zbar reports UPC-E expanded to UPC-A (as EAN-13)
        expected.add("0042100005264" if text == "04252614" else text)
    good = any(d in expected or d.strip("ABCD") == text for _, d in got)
    print(("OK  " if good else "FAIL"), fmt, text, got)
    ok &= good
sys.exit(0 if ok else 1)
