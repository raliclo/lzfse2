"""
comparison_win.py — macOS vs Windows 壓縮基準比較 / macOS vs Windows benchmark comparison

用法 / Usage:
    python comparison_win.py [--mac PATH] [--win PATH] [--n N] [--dataset DS]

預設 / Defaults:
    --mac  ../BenchMarkResult.csv          (macOS full benchmark)
    --win  ./BenchMarkResult-Win.csv       (Windows encode-only benchmark)
    --n    40
    --dataset  claw-code

⚠ 語義差異 / Semantic difference:
    macOS  -n N : encode 重複執行 N 次，取平均速度。
    Windows -n N: inflight chunk count（92221a02 code），單次 encode。
    兩者速度可對比趨勢，但不等同受控 A/B 測試。
    macOS -n N = N encode repetitions (average). Windows -n N = inflight chunks (single run).
"""

import argparse
import csv
import io
import os
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
else:
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

SUSPICIOUS_MB_S = 1000
BAR_WIDTH = 24
COL = 22  # format column width


# ── helpers ───────────────────────────────────────────────────────────

def f(s):
    """Parse float or return None."""
    try:
        return float(s) if s and s.strip() else None
    except ValueError:
        return None

def fmt(v, decimals=2, unit=""):
    if v is None:
        return "—"
    return f"{v:.{decimals}f}{unit}"

def bar(value, max_value, width=BAR_WIDTH):
    if value is None or max_value == 0:
        return "." * width
    filled = max(0, min(width, int(round(value / max_value * width))))
    return "#" * filled + "." * (width - filled)

def section(title):
    print()
    print("-" * 72)
    print(f"  {title}")
    print("-" * 72)


# ── CSV loader ────────────────────────────────────────────────────────

def load(path):
    """Load CSV → list[dict], skipping the Chinese label row (row 2)."""
    rows = []
    with open(path, newline="", encoding="utf-8-sig") as fh:
        reader = csv.reader(fh)
        headers = next(reader)      # row 1: English column names
        next(reader)                # row 2: Chinese labels — skip
        for line in reader:
            if not any(line):
                continue
            rows.append(dict(zip(headers, line)))
    return rows


# ── join ──────────────────────────────────────────────────────────────

def join(mac_rows, win_rows, dataset, mac_n):
    """Return list of (format, mac_row_or_None, win_row_or_None) in display order."""
    mac = {r["format"]: r for r in mac_rows
           if r["dataset"] == dataset and r["n"] == str(mac_n)}
    win = {r["format"]: r for r in win_rows
           if r["dataset"] == dataset}

    # Preserve macOS row order; append any Windows-only formats at the end
    order = list(mac.keys())
    for fmt_name in win:
        if fmt_name not in order:
            order.append(fmt_name)

    return [(fmt_name, mac.get(fmt_name), win.get(fmt_name)) for fmt_name in order]


# ── report sections ───────────────────────────────────────────────────

def report_encode_speed(rows):
    section("Encode Speed  壓縮速度  (MB/s)  —  higher is better")
    print(f"  {'Format':<{COL}}  {'Mac MB/s':>9}  {'Win MB/s':>9}  {'Win/Mac':>7}  Bar (Mac=full)")
    print(f"  {'-'*COL}  {'-'*9}  {'-'*9}  {'-'*7}  {'-'*BAR_WIDTH}")

    mac_speeds = [f(m["encode_mb_s"]) for _, m, _ in rows if m]
    max_mac = max((v for v in mac_speeds if v), default=1)

    for fmt_name, m, w in rows:
        mac_s = f(m["encode_mb_s"]) if m else None
        win_s = f(w["encode_mb_s"]) if w else None
        win_invalid = win_s is not None and win_s > SUSPICIOUS_MB_S

        ratio_str = "—"
        if mac_s and win_s and not win_invalid:
            ratio_str = f"{win_s / mac_s:.3f}"

        win_str = "⚠ INVALID" if win_invalid else fmt(win_s)
        b = bar(mac_s, max_mac) if mac_s else "." * BAR_WIDTH

        # mark macOS-only formats
        note = " (Mac only)" if w is None else ""
        print(f"  {fmt_name:<{COL}}  {fmt(mac_s):>9}  {win_str:>9}  {ratio_str:>7}  {b}{note}")


def report_compression(rows):
    section("Compression Ratio  壓縮比  (relative to each platform's TGZ output)")
    print(f"  NOTE: ratios use each platform's own TGZ as baseline — cross-platform")
    print(f"        ratio differences reflect different TGZ tool outputs, not LZFSE code.")
    print()
    print(f"  {'Format':<{COL}}  {'Mac ratio':>9}  {'Win ratio':>9}  {'Mac cmp':>8}  {'Win cmp':>8}")
    print(f"  {'-'*COL}  {'-'*9}  {'-'*9}  {'-'*8}  {'-'*8}")

    for fmt_name, m, w in rows:
        mac_r = fmt(f(m["compression_ratio"]), 4) if m else "—"
        win_r = fmt(f(w["compression_ratio"]), 4) if w else "—"
        mac_c = m.get("compressed_size_mib", "—") if m else "—"
        win_c = w.get("compressed_size_mib", "—") if w else "—"
        note  = " (Mac only)" if w is None else ""
        print(f"  {fmt_name:<{COL}}  {mac_r:>9}  {win_r:>9}  {mac_c:>8}  {win_c:>8}{note}")


def report_encode_time(rows):
    section("Encode Time  壓縮耗時  (seconds, ratio vs each platform's TGZ)")
    print(f"  {'Format':<{COL}}  {'Mac sec':>8}  {'Win sec':>8}  {'Mac/TGZ':>8}  {'Win/TGZ':>8}  Note")
    print(f"  {'-'*COL}  {'-'*8}  {'-'*8}  {'-'*8}  {'-'*8}  {'-'*18}")

    for fmt_name, m, w in rows:
        mac_s  = fmt(f(m["encode_seconds"]),    2) if m else "—"
        win_s  = fmt(f(w["encode_seconds"]),    2) if w else "—"
        mac_tr = fmt(f(m["encode_time_ratio"]), 4) if m else "—"
        win_tr = fmt(f(w["encode_time_ratio"]), 4) if w else "—"
        win_invalid = w and f(w["encode_mb_s"]) is not None and f(w["encode_mb_s"]) > SUSPICIOUS_MB_S
        note = "⚠ Win timing invalid" if win_invalid else ("(Mac only)" if w is None else "")
        print(f"  {fmt_name:<{COL}}  {mac_s:>8}  {win_s:>8}  {mac_tr:>8}  {win_tr:>8}  {note}")


def report_mac_only(rows, dataset, mac_n):
    section(f"macOS-only Metrics  僅 macOS 有資料  (dataset={dataset}, n={mac_n})")
    print(f"  {'Format':<{COL}}  {'Dec MB/s':>9}  {'Enc RSS':>8}  {'Dec RSS':>8}  {'Enc Eng J':>10}  {'Eng Ratio':>10}")
    print(f"  {'-'*COL}  {'-'*9}  {'-'*8}  {'-'*8}  {'-'*10}  {'-'*10}")

    for fmt_name, m, _ in rows:
        if not m:
            continue
        dec_s  = fmt(f(m["decode_mb_s"]))
        enc_r  = fmt(f(m["encode_rss_mb"]))
        dec_r  = fmt(f(m["decode_rss_mb"]))
        eng_j  = fmt(f(m["encode_cpu_energy_j"]), 2)
        eng_rt = fmt(f(m["encode_cpu_energy_ratio_tgz"]), 4)
        print(f"  {fmt_name:<{COL}}  {dec_s:>9}  {enc_r:>8}  {dec_r:>8}  {eng_j:>10}  {eng_rt:>10}")

    print()
    print("  Columns unavailable on Windows: decode_mb_s, encode/decode_rss_mb,")
    print("  encode/decode_cpu_power_mw, encode/decode_cpu_energy_j,")
    print("  encode/decode_cpu_energy_ratio_tgz, all trace/CPU-symbol columns.")
    print("  Reason: macOS powermetrics required for energy measurement.")


# ── main ──────────────────────────────────────────────────────────────

def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description="macOS vs Windows benchmark comparison")
    ap.add_argument("--mac",     default=os.path.join(here, "..", "BenchMarkResult.csv"))
    ap.add_argument("--win",     default=os.path.join(here, "BenchMarkResult-Win.csv"))
    ap.add_argument("--n",       type=int, default=40)
    ap.add_argument("--dataset", default="claw-code")
    args = ap.parse_args()

    for p in (args.mac, args.win):
        if not os.path.exists(p):
            print(f"File not found: {p}")
            sys.exit(1)

    mac_rows = load(args.mac)
    win_rows = load(args.win)
    rows = join(mac_rows, win_rows, args.dataset, args.n)

    print()
    print("=" * 72)
    print(f"  macOS vs Windows  —  dataset={args.dataset}  mac_n={args.n}  win_n=40(inflight)")
    print(f"  macOS : {os.path.basename(args.mac)}")
    print(f"  Windows: {os.path.basename(args.win)}")
    print()
    print(f"  ⚠  Semantic difference / 語義差異:")
    print(f"     macOS   -n {args.n} = {args.n} encode repetitions, averaged.")
    print(f"     Windows -n 40 = inflight chunk count (92221a02), single run.")
    print("=" * 72)

    report_encode_speed(rows)
    report_compression(rows)
    report_encode_time(rows)
    report_mac_only(rows, args.dataset, args.n)

    print()
    print("=" * 72)
    print()


if __name__ == "__main__":
    main()
