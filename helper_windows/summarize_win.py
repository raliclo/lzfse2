"""
summarize_win.py — BenchMarkResult-Win.csv 摘要工具 / Windows benchmark summary tool

用法 / Usage:
    python summarize_win.py [path/to/BenchMarkResult-Win.csv]

預設讀取腳本同目錄的 BenchMarkResult-Win.csv。
Defaults to BenchMarkResult-Win.csv in the same directory as this script.
"""

import csv
import io
import os
import sys

# Force UTF-8 output so Chinese labels render correctly on Windows consoles
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
else:
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

SUSPICIOUS_MB_S = 9999 # encode MB/s above this is likely a measurement error
BAR_WIDTH = 30          # character width for speed bar

def parse_float(s):
    """Return float or None for empty / non-numeric values."""
    try:
        return float(s) if s.strip() else None
    except ValueError:
        return None

def load_csv(path):
    """Load CSV, skip the Chinese header row (row 2), return list of dicts."""
    rows = []
    with open(path, newline="", encoding="utf-8-sig") as f:
        reader = csv.reader(f)
        headers = next(reader)          # row 1: English column names
        next(reader)                    # row 2: Chinese labels — skip
        for line in reader:
            if not any(line):           # skip blank lines
                continue
            rows.append(dict(zip(headers, line)))
    return rows

def bar(value, max_value, width=BAR_WIDTH):
    """Render a simple ASCII bar proportional to value/max_value."""
    if value is None or max_value == 0:
        return " " * width
    filled = int(round(value / max_value * width))
    return "#" * filled + "." * (width - filled)

def flag(row):
    """Return a warning tag if the row has suspicious data."""
    mb_s = parse_float(row.get("encode_mb_s"))
    if mb_s is not None and mb_s > SUSPICIOUS_MB_S:
        return " ⚠ TIMING INVALID"
    return ""

def print_section(title):
    print()
    print(f"{'-' * 72}")
    print(f"  {title}")
    print(f"{'-' * 72}")

def summarize(path):
    rows = load_csv(path)
    if not rows:
        print("No data found.")
        return

    # Group by dataset
    datasets = sorted({r["dataset"] for r in rows})

    for ds in datasets:
        ds_rows = [r for r in rows if r["dataset"] == ds]
        n_vals  = sorted({r["n"] for r in ds_rows})

        print(f"\n{'=' * 72}")
        print(f"  Dataset: {ds}    n value(s): {', '.join(n_vals)}")
        print(f"  (n = inflight chunk count in 92221a02 code, not repetition count)")
        print(f"{'=' * 72}")

        # -- Encode Speed ----------------------------------------------
        print_section("Encode Speed  壓縮速度 (MB/s)")
        valid_mb_s = [parse_float(r["encode_mb_s"]) for r in ds_rows
                      if parse_float(r["encode_mb_s"]) is not None
                      and parse_float(r["encode_mb_s"]) < SUSPICIOUS_MB_S]
        max_mb_s = max(valid_mb_s) if valid_mb_s else 1

        print(f"  {'Format':<20} {'MB/s':>8}  {'Bar (valid only)'}")
        print(f"  {'-'*20} {'-'*8}  {'-'*BAR_WIDTH}")
        for r in ds_rows:
            fmt    = r["format"]
            mb_s   = parse_float(r["encode_mb_s"])
            warn   = flag(r)
            if warn:
                print(f"  {fmt:<20} {'N/A':>8}  {warn.strip()}")
            else:
                val_str = f"{mb_s:.2f}" if mb_s is not None else "—"
                b       = bar(mb_s, max_mb_s) if mb_s is not None else " " * BAR_WIDTH
                print(f"  {fmt:<20} {val_str:>8}  {b}")

        # -- Compression Ratio -----------------------------------------
        print_section("Compression Ratio  壓縮比  (output / TGZ output, TGZ = 1.0000)")
        print(f"  {'Format':<20} {'Ratio':>8}  {'Compressed':>12}  {'Note'}")
        print(f"  {'-'*20} {'-'*8}  {'-'*12}  {'-'*20}")
        for r in ds_rows:
            fmt   = r["format"]
            ratio = parse_float(r["compression_ratio"])
            csz   = r.get("compressed_size_mib", "")
            note  = "< 1: smaller than TGZ" if ratio is not None and ratio < 1.0 else \
                    "> 1: larger than TGZ"  if ratio is not None and ratio > 1.0 else ""
            ratio_str = f"{ratio:.4f}" if ratio is not None else "—"
            print(f"  {fmt:<20} {ratio_str:>8}  {csz:>12}  {note}")

        # -- Encode Time -----------------------------------------------
        print_section("Encode Time  壓縮耗時 (seconds, ratio vs TGZ)")
        print(f"  {'Format':<20} {'Sec':>8}  {'vs TGZ':>8}  {'Note'}")
        print(f"  {'-'*20} {'-'*8}  {'-'*8}  {'-'*24}")
        for r in ds_rows:
            fmt    = r["format"]
            sec    = parse_float(r["encode_seconds"])
            tratio = parse_float(r["encode_time_ratio"])
            warn   = flag(r)
            sec_str = f"{sec:.2f}"      if sec    is not None else "—"
            tr_str  = f"{tratio:.4f}"   if tratio is not None else "—"
            note   = warn.strip() if warn else ""
            print(f"  {fmt:<20} {sec_str:>8}  {tr_str:>8}  {note}")

        # -- Empty Columns Summary -------------------------------------
        print_section("Column Availability  欄位可用性")
        all_cols = list(rows[0].keys()) if rows else []
        has_data = [c for c in all_cols
                    if any(r.get(c, "").strip() for r in ds_rows)]
        no_data  = [c for c in all_cols if c not in has_data]
        print(f"  Available ({len(has_data)}): {', '.join(has_data)}")
        print(f"  Empty     ({len(no_data)}): {', '.join(no_data)}")
        print(f"\n  Note: decode / RSS / trace / CPU power columns require macOS powermetrics.")
        print(f"        No energy data available on Windows.")

    print(f"\n{'=' * 72}\n")

if __name__ == "__main__":
    if len(sys.argv) > 1:
        csv_path = sys.argv[1]
    else:
        csv_path = os.path.join(os.path.dirname(__file__), "BenchMarkResult-Win.csv")

    if not os.path.exists(csv_path):
        print(f"File not found: {csv_path}")
        sys.exit(1)

    print(f"Reading: {csv_path}")
    summarize(csv_path)
