"""以 BenchMarkResult.csv（macOS）與 benchmark_summary.csv（Windows）產生比較報告。

工作流程 / Workflow:
    每輪先跑 R{N}-Mac，再跑 R{N}-Win，最後執行本腳本。
    Run R{N}-Mac first, then R{N}-Win, then run this script.

比較指標 / Comparison metrics:
    1. Encode/Decode MB/s + ratio vs TGZ
    2. RSS MB + ratio vs TGZ  (Mac only)
    3. CPU Energy J + ratio vs TGZ  (Mac only; decode n=40 unreliable)

Usage:
    python comparison_win.py [--mac PATH] [--win-summary PATH]
                             [--output PATH] [--n N] [--dataset NAME]
"""

import argparse
import csv
import io
import re
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
else:
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

# ── constants ────────────────────────────────────────────────────────────────

FORMAT_MAP = {
    "encodeTgz":     "TGZ",
    "encodeOther3":  "LZFSE (Other3)",
    "encodeLazy2":   "LZFSE (Lazy2)",
    "encodeOptimal": "LZFSE (Optimal)",
    "encodeBVX3":    "LZFSE (BVX3)",
    "encodeLZ4":     "TLZ4",
    "encodeZSTD":    "ZSTD",
}
FORMAT_ORDER = [
    "TGZ",
    "LZFSE (Other3)",
    "LZFSE (BVX3)",
    "LZFSE (Lazy2)",
    "LZFSE (Optimal)",
    "TLZ4",
    "ZSTD",
]
SUMMARY_RE     = re.compile(r"^(?P<token>encode\w+?)(?:-n(?P<n>\d+))?$")
SUSPICIOUS_MBS = 1000
BAR_WIDTH      = 20
COL            = 22

CSV_FIELDS = [
    "dataset", "format", "win_n_meaning", "mac_n",
    "win_encode_mb_s", "mac_encode_mb_s", "win_mac_speed_ratio",
    "win_compress_ratio", "mac_compress_ratio", "compress_ratio_diff",
    "win_encode_sec", "mac_encode_sec", "note",
]
CSV_LABELS = [
    "資料集", "格式", "Windows n=40 意義", "macOS n",
    "Win 壓縮 MB/s", "Mac 壓縮 MB/s", "Win/Mac 速度比",
    "Win 壓縮比", "Mac 壓縮比", "壓縮比差異",
    "Win 壓縮秒", "Mac 壓縮秒", "備註",
]


# ── helpers ──────────────────────────────────────────────────────────────────

def fv(s):
    try:
        return float(s) if s and str(s).strip() else None
    except (ValueError, TypeError):
        return None

def fmt_n(v, d=2):
    return "—" if v is None else f"{v:.{d}f}"

def parse_mib(s):
    m = re.match(r"^\s*([0-9.]+)\s*([KMG]?)", str(s or ""), re.I)
    if not m:
        return None
    amount = float(m.group(1))
    unit   = m.group(2).upper()
    return amount * {"": 1, "K": 1/1024, "M": 1, "G": 1024}[unit]

def bar(value, max_val, width=BAR_WIDTH):
    if value is None or max_val == 0:
        return "." * width
    filled = max(0, min(width, int(round(value / max_val * width))))
    return "#" * filled + "." * (width - filled)

def section(title):
    print()
    print("-" * 78)
    print(f"  {title}")
    print("-" * 78)


# ── loaders ──────────────────────────────────────────────────────────────────

def load_mac(path, dataset, n):
    """Return {format: row_dict} from BenchMarkResult.csv, filtered by dataset+n."""
    with path.open(newline="", encoding="utf-8-sig") as fh:
        reader = csv.DictReader(fh)
        rows   = list(reader)
    return {
        r["format"]: r
        for r in rows
        if r.get("dataset") == dataset and r.get("n") == str(n)
    }

def load_summary(path):
    """Return {format_display_name: row} from benchmark_summary.csv."""
    with path.open(newline="", encoding="utf-8-sig") as fh:
        reader = csv.DictReader(fh)
        result = {}
        for row in reader:
            m = SUMMARY_RE.match(row.get("format", ""))
            if not m or m.group("token") not in FORMAT_MAP:
                continue
            display = FORMAT_MAP[m.group("token")]
            result[display] = {**row, "n": m.group("n") or ""}
    return result


# ── report helpers ────────────────────────────────────────────────────────────

def compute_win_speed(win_row, raw_mb):
    """Return (seconds, mb_s, is_suspicious) from a summary row."""
    ns    = fv(win_row.get("nanoseconds"))
    valid = win_row.get("valid") == "yes"
    if not ns or not valid or raw_mb is None:
        return None, None, False
    sec   = ns / 1e9
    mb_s  = raw_mb / sec
    return sec, mb_s, (mb_s > SUSPICIOUS_MBS)

def win_compress_ratio(win_row, tgz_bytes):
    b = fv(win_row.get("encoded_bytes")) if win_row and win_row.get("valid") == "yes" else None
    return b / tgz_bytes if b and tgz_bytes else None


# ── Section 1: Encode / Decode MB/s ──────────────────────────────────────────

def report_speed(mac, win, raw_mb):
    mac_tgz   = mac.get("TGZ", {})
    win_tgz   = win.get("TGZ", {})
    m_tgz_enc = fv(mac_tgz.get("encode_mb_s"))
    m_tgz_dec = fv(mac_tgz.get("decode_mb_s"))
    _, w_tgz_enc, _ = compute_win_speed(win_tgz, raw_mb)

    # 1a. Encode
    section("1a. Encode MB/s  壓縮速度  (ratio = format / TGZ, per platform)")
    print(f"  {'Format':<{COL}}  {'Mac MB/s':>9}  {'Mac/TGZ':>7}  "
          f"{'Win MB/s':>9}  {'Win/TGZ':>7}  {'Win/Mac':>7}  Bar(Mac)")
    print(f"  {'-'*COL}  {'-'*9}  {'-'*7}  {'-'*9}  {'-'*7}  {'-'*7}  {'-'*BAR_WIDTH}")

    max_enc = max((fv(m.get("encode_mb_s")) or 0 for m in mac.values()), default=1)

    for name in FORMAT_ORDER:
        m = mac.get(name)
        w = win.get(name)
        mac_s = fv(m.get("encode_mb_s")) if m else None
        _, win_s, suspicious = compute_win_speed(w, raw_mb) if w else (None, None, False)

        m_rt = fmt_n(mac_s / m_tgz_enc, 4) if mac_s and m_tgz_enc else "—"
        w_rt = fmt_n(win_s / w_tgz_enc, 4) if win_s and w_tgz_enc and not suspicious else "—"
        wm   = fmt_n(win_s / mac_s,     3) if win_s and mac_s and not suspicious else "—"
        w_str = "⚠INVALID" if suspicious else fmt_n(win_s)
        b    = bar(mac_s, max_enc)
        note = " (Mac only)" if not w else ""
        print(f"  {name:<{COL}}  {fmt_n(mac_s):>9}  {m_rt:>7}  "
              f"{w_str:>9}  {w_rt:>7}  {wm:>7}  {b}{note}")

    # 1b. Decode
    section("1b. Decode MB/s  解壓速度  (Mac only — Windows does not benchmark decode)")
    print(f"  {'Format':<{COL}}  {'Mac MB/s':>9}  {'Mac/TGZ':>7}  Bar(Mac)")
    print(f"  {'-'*COL}  {'-'*9}  {'-'*7}  {'-'*BAR_WIDTH}")

    max_dec = max((fv(m.get("decode_mb_s")) or 0 for m in mac.values()), default=1)
    for name in FORMAT_ORDER:
        m = mac.get(name)
        if not m:
            continue
        dec_s = fv(m.get("decode_mb_s"))
        ratio = fmt_n(dec_s / m_tgz_dec, 4) if dec_s and m_tgz_dec else "—"
        b     = bar(dec_s, max_dec)
        print(f"  {name:<{COL}}  {fmt_n(dec_s):>9}  {ratio:>7}  {b}")


# ── Section 1c: Compress Size & Ratio ────────────────────────────────────────

def report_compression(mac, win):
    """Section 1c: compressed size (MiB) and ratio vs TGZ, both platforms."""
    mac_tgz    = mac.get("TGZ", {})
    m_tgz_size = parse_mib(mac_tgz.get("compressed_size_mib"))

    win_tgz     = win.get("TGZ", {})
    w_tgz_bytes = fv(win_tgz.get("encoded_bytes")) if win_tgz.get("valid") == "yes" else None
    w_tgz_mib   = w_tgz_bytes / 1024 / 1024 if w_tgz_bytes else None

    section("1c. Compress Size & Ratio  壓縮大小與比率  (ratio = format / TGZ, per platform)")
    print(f"  {'Format':<{COL}}  {'Mac MiB':>8}  {'Mac/TGZ':>7}  "
          f"{'Win MiB':>8}  {'Win/TGZ':>7}  {'Mac/Win':>7}")
    print(f"  {'-'*COL}  {'-'*8}  {'-'*7}  {'-'*8}  {'-'*7}  {'-'*7}")

    for name in FORMAT_ORDER:
        m = mac.get(name)
        w = win.get(name)

        mac_size  = parse_mib(m.get("compressed_size_mib")) if m else None
        mac_ratio = fv(m.get("compression_ratio")) if m else None

        w_bytes   = fv(w.get("encoded_bytes")) if w and w.get("valid") == "yes" else None
        win_mib   = w_bytes / 1024 / 1024 if w_bytes else None
        win_ratio = w_bytes / w_tgz_bytes  if w_bytes and w_tgz_bytes else None

        mac_win   = mac_size / win_mib if mac_size and win_mib else None

        print(f"  {name:<{COL}}  {fmt_n(mac_size, 1):>8}  {fmt_n(mac_ratio, 4):>7}  "
              f"{fmt_n(win_mib, 1):>8}  {fmt_n(win_ratio, 4):>7}  {fmt_n(mac_win, 4):>7}")


# ── Section 2: RSS MB ─────────────────────────────────────────────────────────

def report_rss(mac):
    mac_tgz = mac.get("TGZ", {})
    tgz_enc = fv(mac_tgz.get("encode_rss_mb"))
    tgz_dec = fv(mac_tgz.get("decode_rss_mb"))

    section("2. RSS MB  記憶體峰值  (Mac only — Windows does not measure RSS)")
    print(f"  {'Format':<{COL}}  {'Enc RSS':>9}  {'Enc/TGZ':>8}  {'Dec RSS':>9}  {'Dec/TGZ':>8}")
    print(f"  {'-'*COL}  {'-'*9}  {'-'*8}  {'-'*9}  {'-'*8}")

    for name in FORMAT_ORDER:
        m = mac.get(name)
        if not m:
            continue
        enc = fv(m.get("encode_rss_mb"))
        dec = fv(m.get("decode_rss_mb"))
        e_r = fmt_n(enc / tgz_enc, 4) if enc and tgz_enc else "—"
        d_r = fmt_n(dec / tgz_dec, 4) if dec and tgz_dec else "—"
        print(f"  {name:<{COL}}  {fmt_n(enc):>9}  {e_r:>8}  {fmt_n(dec):>9}  {d_r:>8}")


# ── Section 3: CPU Energy J ───────────────────────────────────────────────────

def report_energy(mac):
    section("3. CPU Energy J  能耗  (Mac only — macOS powermetrics required)")
    print(f"  ⚠  Encode energy n=40: reliable (95-107% sampling coverage).")
    print(f"  ⚠  Decode energy n=40: NOT reliable (<5% coverage); reference only.")
    print()
    print(f"  {'Format':<{COL}}  {'Enc J':>9}  {'Enc/TGZ':>8}  {'Dec J':>9}  {'Dec/TGZ':>8}")
    print(f"  {'-'*COL}  {'-'*9}  {'-'*8}  {'-'*9}  {'-'*8}")

    for name in FORMAT_ORDER:
        m = mac.get(name)
        if not m:
            continue
        enc_j  = fv(m.get("encode_cpu_energy_j"))
        dec_j  = fv(m.get("decode_cpu_energy_j"))
        enc_rt = fmt_n(fv(m.get("encode_cpu_energy_ratio_tgz")), 4)
        dec_rt = fmt_n(fv(m.get("decode_cpu_energy_ratio_tgz")), 4)
        flag   = "*" if name != "TGZ" else " "
        print(f"  {name:<{COL}}  {fmt_n(enc_j):>9}  {enc_rt:>8}  {fmt_n(dec_j):>9}{flag} {dec_rt:>8}")

    print()
    print("  * Decode energy marked unreliable at n=40.")


# ── CSV output ────────────────────────────────────────────────────────────────

def write_csv(path, mac, win, raw_mb, dataset, mac_n):
    tgz_win   = win.get("TGZ", {})
    tgz_bytes = fv(tgz_win.get("encoded_bytes")) if tgz_win.get("valid") == "yes" else None

    rows = []
    for name in FORMAT_ORDER:
        m = mac.get(name)
        w = win.get(name)
        win_sec, win_mbs, suspicious = compute_win_speed(w, raw_mb) if w else (None, None, False)
        if suspicious:
            win_sec, win_mbs = None, None

        mac_mbs   = fv(m.get("encode_mb_s")) if m else None
        mac_ratio = fv(m.get("compression_ratio")) if m else None
        mac_sec   = fv(m.get("encode_seconds")) if m else None
        win_ratio = win_compress_ratio(w, tgz_bytes) if w else None

        valid     = w and w.get("valid") == "yes" and not suspicious
        note = ""
        if not valid and w:
            note = f"WIN RESULT INVALID: {w.get('note') or 'marked invalid or suspicious'}"
        elif not w:
            note = "Windows result missing"

        win_n = f"inflight={w.get('n') or '?'} (1 run)" if w and name.startswith("LZFSE") \
                else "single run (no -n)"

        rows.append({
            "dataset":          dataset,
            "format":           name,
            "win_n_meaning":    win_n,
            "mac_n":            str(mac_n),
            "win_encode_mb_s":  fmt_n(win_mbs, 2),
            "mac_encode_mb_s":  fmt_n(mac_mbs, 2),
            "win_mac_speed_ratio": fmt_n(win_mbs / mac_mbs if win_mbs and mac_mbs else None, 3),
            "win_compress_ratio":  fmt_n(win_ratio, 4),
            "mac_compress_ratio":  fmt_n(mac_ratio, 4),
            "compress_ratio_diff": fmt_n(win_ratio - mac_ratio
                                         if win_ratio is not None and mac_ratio is not None
                                         else None, 4),
            "win_encode_sec":   fmt_n(win_sec, 2),
            "mac_encode_sec":   fmt_n(mac_sec, 2),
            "note":             note,
        })

    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8-sig") as fh:
        w = csv.writer(fh, lineterminator="\n")
        w.writerow(CSV_FIELDS)
        w.writerow(CSV_LABELS)
        for r in rows:
            w.writerow([r[f] for f in CSV_FIELDS])

    return rows


# ── main ─────────────────────────────────────────────────────────────────────

def main():
    here   = Path(__file__).resolve().parent
    ap     = argparse.ArgumentParser(description="macOS vs Windows benchmark comparison")
    ap.add_argument("--mac",         type=Path, default=here.parent / "BenchMarkResult.csv")
    ap.add_argument("--win-summary", type=Path, default=here / "benchmark_summary.csv")
    ap.add_argument("--output",      type=Path, default=here / "comparison.csv")
    ap.add_argument("--n",           type=int,  default=40)
    ap.add_argument("--dataset",     default="claw-code")
    args = ap.parse_args()

    for p in (args.mac, args.win_summary):
        if not p.exists():
            print(f"File not found: {p}", file=sys.stderr)
            sys.exit(1)

    mac = load_mac(args.mac.resolve(), args.dataset, args.n)
    win = load_summary(args.win_summary.resolve())
    if not mac:
        print(f"No macOS rows for dataset={args.dataset}, n={args.n}", file=sys.stderr)
        sys.exit(1)

    tgz_mac = mac.get("TGZ", {})
    raw_mb  = (parse_mib(tgz_mac.get("raw_size_mib")) or 0) * 1.048576  # MiB → MB

    print()
    print("=" * 78)
    print(f"  macOS vs Windows — dataset={args.dataset}  mac_n={args.n}  win_n=40(inflight)")
    print(f"  macOS  : {args.mac.name}")
    print(f"  Windows: {args.win_summary.name}")
    print()
    print(f"  Workflow: R{{N}}-Mac first → R{{N}}-Win → this script.")
    print(f"  Semantic: macOS -n {args.n} = {args.n} repetitions (avg).")
    print(f"            Windows -n 40 = inflight chunk count (single run).")
    print("=" * 78)

    report_speed(mac, win, raw_mb)
    report_compression(mac, win)
    report_rss(mac)
    report_energy(mac)

    print()
    print("=" * 78)
    print()

    # Also write comparison.csv
    rows = write_csv(args.output.resolve(), mac, win, raw_mb, args.dataset, args.n)
    print(f"[OK] {args.output} written ({len(rows)} rows)")
    for r in rows:
        spd  = r["win_encode_mb_s"] or "N/A"
        note = f"  {r['note']}" if r["note"] else ""
        print(f"  {r['format']:<20} Win {spd:>7} MB/s{note}")


if __name__ == "__main__":
    main()
