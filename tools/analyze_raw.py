#!/usr/bin/env python3
"""Analyze a raw 10-bit Bayer frame from s5k5e8 (BA10/SGRBG10, 2592x1944).

Supports two storage layouts produced by Rockchip rkcif:
  1. 16-bit LE (2 bytes/pixel, sizeimage = W*H*2)
  2. MIPI RAW10 packed (5 bytes per 4 pixels, stride = ceil(W*10/8) padded to 128)

Usage: python3 analyze_raw.py <file.raw>
Output: <file.raw>.pgm  (binary PGM, viewable with eog/feh/GIMP/ImageMagick)
        one-line health report on stdout

No external dependencies — stdlib only.
"""
import sys

WIDTH, HEIGHT = 2592, 1944
PIXELS = WIDTH * HEIGHT

# Stride for MIPI RAW10 packed: ceil(W * 10 / 8) rounded up to 128-byte boundary
RAW10_STRIDE = ((WIDTH * 10 + 7) // 8 + 127) // 128 * 128  # = 3328
RAW10_SIZE = RAW10_STRIDE * HEIGHT  # = 6,469,632


def decode_packed_ba10(data):
    """Decode MIPI RAW10 packed data → list of WIDTH*HEIGHT 10-bit values."""
    values = []
    row_bytes = (WIDTH * 10 + 7) // 8  # 3240 bytes of real data per row
    for row in range(HEIGHT):
        base = row * RAW10_STRIDE
        row_data = data[base:base + row_bytes]
        row_vals = []
        for i in range(0, len(row_data) - 4, 5):
            b0, b1, b2, b3, b4 = row_data[i], row_data[i+1], row_data[i+2], row_data[i+3], row_data[i+4]
            row_vals.append((b0 << 2) | ((b4 >> 0) & 0x3))
            row_vals.append((b1 << 2) | ((b4 >> 2) & 0x3))
            row_vals.append((b2 << 2) | ((b4 >> 4) & 0x3))
            row_vals.append((b3 << 2) | ((b4 >> 6) & 0x3))
        values.extend(row_vals[:WIDTH])
    return values


def analyze(path):
    with open(path, 'rb') as f:
        raw = f.read()

    file_size = len(raw)
    if file_size >= PIXELS * 2:
        # 16-bit LE layout
        import array as arr
        data = arr.array('H')
        data.frombytes(raw[:PIXELS * 2])
        if sys.byteorder == 'big':
            data.byteswap()
        values = data.tolist()
        layout = "16-bit LE"
    elif file_size >= RAW10_SIZE:
        # MIPI RAW10 packed layout
        values = decode_packed_ba10(raw)
        layout = f"packed BA10 stride={RAW10_STRIDE}"
    else:
        print(f"ERROR: file too small ({file_size} bytes); expected "
              f"{PIXELS*2} (16-bit) or {RAW10_SIZE} (packed BA10)")
        return False

    if len(values) < PIXELS:
        print(f"ERROR: only decoded {len(values)} pixels, expected {PIXELS}")
        return False

    values = values[:PIXELS]
    mn = min(values)
    mx = max(values)
    mean = sum(values) / PIXELS
    unique = len(set(values))

    # Column mean variance — stripe pattern (ADC reference) shows as high col_var
    col_sums = [0] * WIDTH
    for i, v in enumerate(values):
        col_sums[i % WIDTH] += v
    col_means = [s / HEIGHT for s in col_sums]
    overall_mean = sum(col_means) / WIDTH
    col_var = sum((m - overall_mean) ** 2 for m in col_means) / WIDTH

    if unique <= 50:
        status = "GREY - investigate registers"
    elif unique > 1000:
        status = "HEALTHY"
    else:
        status = "PARTIAL - check pipeline"

    print(f"[{layout}] min={mn} max={mx} mean={mean:.1f} unique={unique} "
          f"col_var={col_var:.1f}  [{status}]")

    # Save binary PGM (P5, 8-bit, scale 10-bit → 8-bit by right-shifting 2)
    out = path + '.pgm'
    with open(out, 'wb') as f:
        f.write(f"P5\n{WIDTH} {HEIGHT}\n255\n".encode())
        f.write(bytes(min(v >> 2, 255) for v in values))
    print(f"Saved: {out}")
    return status == "HEALTHY"


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <file.raw>")
        sys.exit(1)
    analyze(sys.argv[1])
