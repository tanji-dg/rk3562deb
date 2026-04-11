#!/usr/bin/env python3
"""Analyze a raw frame from Rockchip cameras.

Supported formats:
  bayer   — 10-bit Bayer (SGRBG10/SGRBG10), 16-bit LE or MIPI packed
  nv12    — 8-bit NV12 (Y plane then interleaved UV), from ISP output

Usage:
  python3 analyze_raw.py [--w W] [--h H] [--fmt bayer|nv12] <file.raw>

  Defaults: W=2592, H=1944, fmt=auto (bayer preferred)

Output:
  <file.raw>.pgm (bayer) or <file.raw>.ppm (nv12, approximate RGB)
  Health report on stdout.

No external dependencies — stdlib only.
"""
import sys
import math


def parse_args():
    args = sys.argv[1:]
    w, h, fmt, path = 2592, 1944, 'auto', None
    i = 0
    while i < len(args):
        if args[i] == '--w' and i + 1 < len(args):
            w = int(args[i + 1]); i += 2
        elif args[i] == '--h' and i + 1 < len(args):
            h = int(args[i + 1]); i += 2
        elif args[i] == '--fmt' and i + 1 < len(args):
            fmt = args[i + 1]; i += 2
        elif not args[i].startswith('--'):
            path = args[i]; i += 1
        else:
            i += 1
    return w, h, fmt, path


def stats(values):
    n = len(values)
    mn = min(values)
    mx = max(values)
    mean = sum(values) / n
    stdev = math.sqrt(sum((v - mean) ** 2 for v in values) / n)
    return mn, mx, mean, stdev


def analyze_bayer(path, w, h):
    pixels = w * h
    raw10_stride = ((w * 10 + 7) // 8 + 127) // 128 * 128
    raw10_size = raw10_stride * h

    with open(path, 'rb') as f:
        raw = f.read()

    file_size = len(raw)

    if file_size >= pixels * 2:
        import array as arr
        data = arr.array('H')
        data.frombytes(raw[:pixels * 2])
        if sys.byteorder == 'big':
            data.byteswap()
        values = data.tolist()
        layout = "16-bit LE"
    elif file_size >= raw10_size:
        values = _decode_packed_raw10(raw, w, h, raw10_stride)
        layout = f"packed RAW10 stride={raw10_stride}"
    else:
        print(f"ERROR: file too small ({file_size} bytes); expected "
              f"{pixels*2} (16-bit) or {raw10_size} (packed RAW10) for {w}x{h}")
        return False

    values = values[:pixels]
    mn, mx, mean, stdev = stats(values)
    unique = len(set(values))

    col_sums = [0] * w
    for i, v in enumerate(values):
        col_sums[i % w] += v
    col_means = [s / h for s in col_sums]
    overall_mean = sum(col_means) / w
    col_var = sum((m - overall_mean) ** 2 for m in col_means) / w

    if unique <= 50:
        status = "GREY - investigate registers"
    elif unique > 1000:
        status = "HEALTHY"
    else:
        status = "PARTIAL - check pipeline"

    print(f"[{layout}] {w}x{h} min={mn} max={mx} mean={mean:.1f} stdev={stdev:.1f} "
          f"unique={unique} col_var={col_var:.1f}  [{status}]")

    out = path + '.pgm'
    with open(out, 'wb') as f:
        f.write(f"P5\n{w} {h}\n255\n".encode())
        f.write(bytes(min(v >> 2, 255) for v in values))
    print(f"Saved: {out}")
    return status == "HEALTHY"


def _decode_packed_raw10(data, w, h, stride):
    values = []
    row_bytes = (w * 10 + 7) // 8
    for row in range(h):
        base = row * stride
        row_data = data[base:base + row_bytes]
        for i in range(0, len(row_data) - 4, 5):
            b0, b1, b2, b3, b4 = (row_data[i], row_data[i+1],
                                   row_data[i+2], row_data[i+3], row_data[i+4])
            values.append((b0 << 2) | ((b4 >> 0) & 0x3))
            values.append((b1 << 2) | ((b4 >> 2) & 0x3))
            values.append((b2 << 2) | ((b4 >> 4) & 0x3))
            values.append((b3 << 2) | ((b4 >> 6) & 0x3))
        values = values[:w * (row + 1)]  # trim to exact width
    return values


def analyze_nv12(path, w, h):
    y_size = w * h
    uv_size = w * h // 2
    expected = y_size + uv_size

    with open(path, 'rb') as f:
        raw = f.read()

    if len(raw) < expected:
        print(f"ERROR: file too small ({len(raw)} bytes); expected {expected} for NV12 {w}x{h}")
        return False

    y_plane = list(raw[:y_size])
    uv_plane = raw[y_size:y_size + uv_size]
    u_vals = [uv_plane[i]     for i in range(0, len(uv_plane), 2)]
    v_vals = [uv_plane[i + 1] for i in range(0, len(uv_plane) - 1, 2)]

    y_mn, y_mx, y_mean, y_stdev = stats(y_plane)
    u_mn, u_mx, u_mean, u_stdev = stats(u_vals)
    v_mn, v_mx, v_mean, v_stdev = stats(v_vals)

    chroma_ok = u_stdev > 1.0 or v_stdev > 1.0
    luma_ok = y_stdev > 1.0 and (y_mx - y_mn) > 10

    if luma_ok and chroma_ok:
        status = "COLOR OK"
    elif luma_ok and not chroma_ok:
        status = "GREY (no chroma) — check AWB service"
    else:
        status = "BLANK"

    print(f"[NV12] {w}x{h}")
    print(f"  Y:  mean={y_mean:.1f} stdev={y_stdev:.1f} min={y_mn} max={y_mx}")
    print(f"  U:  mean={u_mean:.1f} stdev={u_stdev:.1f} min={u_mn} max={u_mx}")
    print(f"  V:  mean={v_mean:.1f} stdev={v_stdev:.1f} min={v_mn} max={v_mx}")
    print(f"  [{status}]")

    # Approximate RGB PPM for visual inspection
    # YUV→RGB: R=Y+1.402*(V-128), G=Y-0.344*(U-128)-0.714*(V-128), B=Y+1.772*(U-128)
    out = path + '.ppm'
    with open(out, 'wb') as f:
        f.write(f"P6\n{w} {h}\n255\n".encode())
        rgb = bytearray(w * h * 3)
        uv_w = w // 2
        for row in range(h):
            for col in range(w):
                y = y_plane[row * w + col]
                uv_idx = (row // 2) * uv_w + (col // 2)
                u = u_vals[uv_idx] if uv_idx < len(u_vals) else 128
                v = v_vals[uv_idx] if uv_idx < len(v_vals) else 128
                r = int(y + 1.402 * (v - 128))
                g = int(y - 0.344 * (u - 128) - 0.714 * (v - 128))
                b = int(y + 1.772 * (u - 128))
                px = (row * w + col) * 3
                rgb[px]     = max(0, min(255, r))
                rgb[px + 1] = max(0, min(255, g))
                rgb[px + 2] = max(0, min(255, b))
        f.write(rgb)
    print(f"Saved: {out}")
    return status == "COLOR OK"


def main():
    w, h, fmt, path = parse_args()
    if path is None:
        print(f"Usage: {sys.argv[0]} [--w W] [--h H] [--fmt bayer|nv12] <file.raw>")
        sys.exit(1)

    if fmt == 'nv12':
        ok = analyze_nv12(path, w, h)
    elif fmt == 'bayer':
        ok = analyze_bayer(path, w, h)
    else:
        # Auto-detect: try NV12 size first if file matches, else bayer
        try:
            size = __import__('os').path.getsize(path)
        except OSError:
            size = 0
        nv12_size = w * h * 3 // 2
        if size == nv12_size or size == nv12_size + 1:
            ok = analyze_nv12(path, w, h)
        else:
            ok = analyze_bayer(path, w, h)

    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
