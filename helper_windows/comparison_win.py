"""以 BenchMarkResult.csv（macOS）與 benchmark_summary.csv（Windows）產生比較報告。

工作流程 / Workflow:
    每輪先跑 R{N}-Mac，再跑 R{N}-Win（含 decode），最後執行本腳本。
    Run R{N}-Mac first, then R{N}-Win (with decode), then run this script.

比較指標 / Comparison metrics:
    1a. Encode MB/s + ratio vs TGZ  (both platforms)
    1b. Decode MB/s + ratio vs TGZ  (Mac + Windows)
    1c. Compress size & ratio vs TGZ  (both platforms)
    2.  RSS MB + ratio vs TGZ  (Mac + Windows when rss_summary.csv exists)
    3.  CPU Energy J + ratio vs TGZ  (Mac only; decode n=40 unreliable)

Usage:
    python comparison_win.py [--mac PATH] [--win-summary PATH]
                             [--win-decode PATH] [--win-rss PATH] [--output PATH]
                             [--n N] [--dataset NAME]
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
DECODE_FORMAT_MAP = {
    "decodeTgz":     "TGZ",
    "decodeOther3":  "LZFSE (Other3)",
    "decodeLazy2":   "LZFSE (Lazy2)",
    "decodeOptimal": "LZFSE (Optimal)",
    "decodeBVX3":    "LZFSE (BVX3)",
    "decodeLZ4":     "TLZ4",
    "decodeZSTD":    "ZSTD",
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
SUMMARY_RE      = re.compile(r"^(?P<token>encode\w+?)(?:-n(?P<n>\d+))?$")
DECODE_SUMMARY_RE = re.compile(r"^(?P<token>decode\w+?)(?:-n(?P<n>\d+))?$")
SUSPICIOUS_MBS  = 1000
BAR_WIDTH       = 20
COL             = 22

CSV_FIELDS = [
    "dataset", "format", "win_n_meaning", "mac_n",
    "win_encode_mb_s", "mac_encode_mb_s", "win_mac_speed_ratio",
    "win_compress_ratio", "mac_compress_ratio", "compress_ratio_diff",
    "win_encode_sec", "mac_encode_sec",
    "win_decode_mb_s", "mac_decode_mb_s", "win_mac_decode_ratio",
    "win_decode_sec", "mac_decode_sec",
    "win_decode_verify",
    "win_encode_rss_mb", "mac_encode_rss_mb", "win_decode_rss_mb", "mac_decode_rss_mb",
    "note",
]
CSV_LABELS = [
    "資料集", "格式", "Windows n=40 意義", "macOS n",
    "Win 壓縮 MB/s", "Mac 壓縮 MB/s", "Win/Mac 速度比",
    "Win 壓縮比", "Mac 壓縮比", "壓縮比差異",
    "Win 壓縮秒", "Mac 壓縮秒",
    "Win 解壓 MB/s", "Mac 解壓 MB/s", "Win/Mac 解壓速度比",
    "Win 解壓秒", "Mac 解壓秒",
    "Win 解壓驗證",
    "備註",
]

CSV_LABEL_BY_FIELD = {
    "dataset": "資料集 / Dataset",
    "format": "格式 / Format",
    "win_n_meaning": "Windows n meaning",
    "mac_n": "macOS n",
    "win_encode_mb_s": "Win encode MB/s",
    "mac_encode_mb_s": "Mac encode MB/s",
    "win_mac_speed_ratio": "Win/Mac encode speed ratio",
    "win_compress_ratio": "Win compression ratio",
    "mac_compress_ratio": "Mac compression ratio",
    "compress_ratio_diff": "Compression ratio diff",
    "win_encode_sec": "Win encode sec",
    "mac_encode_sec": "Mac encode sec",
    "win_decode_mb_s": "Win decode MB/s",
    "mac_decode_mb_s": "Mac decode MB/s",
    "win_mac_decode_ratio": "Win/Mac decode speed ratio",
    "win_decode_sec": "Win decode sec",
    "mac_decode_sec": "Mac decode sec",
    "win_decode_verify": "Win decode verify",
    "win_encode_rss_mb": "Win encode RSS MB",
    "mac_encode_rss_mb": "Mac encode RSS MB",
    "win_decode_rss_mb": "Win decode RSS MB",
    "mac_decode_rss_mb": "Mac decode RSS MB",
    "note": "備註 / Note",
}


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

def load_decode_summary(path):
    """Return {format_display_name: row} from decode_summary.csv."""
    with path.open(newline="", encoding="utf-8-sig") as fh:
        reader = csv.DictReader(fh)
        result = {}
        for row in reader:
            m = DECODE_SUMMARY_RE.match(row.get("format", ""))
            if not m or m.group("token") not in DECODE_FORMAT_MAP:
                continue
            display = DECODE_FORMAT_MAP[m.group("token")]
            result[display] = {**row, "n": m.group("n") or ""}
    return result


def load_rss_summary(path):
    """Return {format_display_name: row} from rss_summary.csv."""
    if not path or not path.exists():
        return {}
    names = {
        "Tgz": "TGZ",
        "TGZ": "TGZ",
        "Other3": "LZFSE (Other3)",
        "BVX3": "LZFSE (BVX3)",
        "Lazy2": "LZFSE (Lazy2)",
        "Optimal": "LZFSE (Optimal)",
        "LZ4": "TLZ4",
        "TLZ4": "TLZ4",
        "ZSTD": "ZSTD",
    }
    with path.open(newline="", encoding="utf-8-sig") as fh:
        reader = csv.DictReader(fh)
        result = {}
        for row in reader:
            display = names.get((row.get("format") or "").strip())
            if display:
                result[display] = row
        return result


def win_rss_value(win, win_rss, name, key):
    row = win.get(name) or {}
    value = fv(row.get(key))
    if value is not None:
        return value
    row = win_rss.get(name) or {}
    return fv(row.get(key))


# ── report helpers ────────────────────────────────────────────────────────────

def compute_win_speed(win_row, raw_mb):
    """Return (seconds, mb_s, is_suspicious) from an encode summary row."""
    ns    = fv(win_row.get("nanoseconds"))
    valid = win_row.get("valid", "yes") != "no"
    if not ns or not valid or raw_mb is None:
        return None, None, False
    sec   = ns / 1e9
    mb_s  = raw_mb / sec
    return sec, mb_s, (mb_s > SUSPICIOUS_MBS)

def compute_win_decode_speed(dec_row, raw_mb):
    """Return (seconds, mb_s) from a decode summary row."""
    ns    = fv(dec_row.get("nanoseconds"))
    valid = dec_row.get("valid", "yes") != "no"
    if not ns or not valid or raw_mb is None:
        return None, None
    sec = ns / 1e9
    return sec, raw_mb / sec

def win_compress_ratio(win_row, tgz_bytes):
    b = fv(win_row.get("encoded_bytes")) if win_row and win_row.get("valid", "yes") != "no" else None
    return b / tgz_bytes if b and tgz_bytes else None


# ── Section 1: Encode / Decode MB/s ──────────────────────────────────────────

def report_speed(mac, win, win_dec, raw_mb):
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
    if win_dec:
        section("1b. Decode MB/s  解壓速度  (Mac: avg n=40; Windows: single run total)")
        _, w_tgz_dec = compute_win_decode_speed(win_dec.get("TGZ", {}), raw_mb)
        print(f"  {'Format':<{COL}}  {'Mac MB/s':>9}  {'Mac/TGZ':>7}  "
              f"{'Win MB/s':>9}  {'Win/TGZ':>7}  {'Win/Mac':>7}  {'Verify':>6}  Bar(Mac)")
        print(f"  {'-'*COL}  {'-'*9}  {'-'*7}  {'-'*9}  {'-'*7}  {'-'*7}  {'-'*6}  {'-'*BAR_WIDTH}")
    else:
        section("1b. Decode MB/s  解壓速度  (Mac only — Windows decode not available)")
        w_tgz_dec = None
        print(f"  {'Format':<{COL}}  {'Mac MB/s':>9}  {'Mac/TGZ':>7}  Bar(Mac)")
        print(f"  {'-'*COL}  {'-'*9}  {'-'*7}  {'-'*BAR_WIDTH}")

    max_dec = max((fv(m.get("decode_mb_s")) or 0 for m in mac.values()), default=1)
    for name in FORMAT_ORDER:
        m = mac.get(name)
        if not m:
            continue
        dec_s = fv(m.get("decode_mb_s"))
        m_rt  = fmt_n(dec_s / m_tgz_dec, 4) if dec_s and m_tgz_dec else "—"
        b     = bar(dec_s, max_dec)

        if win_dec:
            d = win_dec.get(name)
            _, win_dec_s = compute_win_decode_speed(d, raw_mb) if d else (None, None)
            w_rt    = fmt_n(win_dec_s / w_tgz_dec, 4) if win_dec_s and w_tgz_dec else "—"
            wm      = fmt_n(win_dec_s / dec_s, 3) if win_dec_s and dec_s else "—"
            verify  = (d.get("verify") or "?") if d else "?"
            v_str   = f"{'PASS':>6}" if verify == "PASS" else f"{'FAIL':>6}" if verify == "FAIL" else f"{'?':>6}"
            print(f"  {name:<{COL}}  {fmt_n(dec_s):>9}  {m_rt:>7}  "
                  f"{fmt_n(win_dec_s):>9}  {w_rt:>7}  {wm:>7}  {v_str}  {b}")
        else:
            print(f"  {name:<{COL}}  {fmt_n(dec_s):>9}  {m_rt:>7}  {b}")


# ── Section 1c: Compress Size & Ratio ────────────────────────────────────────

def report_compression(mac, win):
    """Section 1c: compressed size (MiB) and ratio vs TGZ, both platforms."""
    mac_tgz    = mac.get("TGZ", {})
    m_tgz_size = parse_mib(mac_tgz.get("compressed_size_mib"))

    win_tgz     = win.get("TGZ", {})
    w_tgz_bytes = fv(win_tgz.get("encoded_bytes")) if win_tgz.get("valid", "yes") != "no" else None
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

        w_bytes   = fv(w.get("encoded_bytes")) if w and w.get("valid", "yes") != "no" else None
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

def report_rss_win(mac, win, win_rss):
    mac_tgz = mac.get("TGZ", {})
    m_tgz_enc = fv(mac_tgz.get("encode_rss_mb"))
    w_tgz_enc = win_rss_value(win, win_rss, "TGZ", "encode_rss_mb")

    section("2. RSS MB  peak memory  (Mac + Windows when rss_summary.csv is available)")
    print(f"  {'Format':<{COL}}  {'Mac Enc':>8}  {'Mac/TGZ':>8}  {'Win Enc':>8}  {'Win/TGZ':>8}  {'Mac Dec':>8}  {'Win Dec':>8}")
    print(f"  {'-'*COL}  {'-'*8}  {'-'*8}  {'-'*8}  {'-'*8}  {'-'*8}  {'-'*8}")

    for name in FORMAT_ORDER:
        m = mac.get(name)
        if not m:
            continue
        m_enc = fv(m.get("encode_rss_mb"))
        m_dec = fv(m.get("decode_rss_mb"))
        w_enc = win_rss_value(win, win_rss, name, "encode_rss_mb")
        w_dec = win_rss_value(win, win_rss, name, "decode_rss_mb")
        m_er = fmt_n(m_enc / m_tgz_enc, 4) if m_enc and m_tgz_enc else "—"
        w_er = fmt_n(w_enc / w_tgz_enc, 4) if w_enc and w_tgz_enc else "—"
        print(f"  {name:<{COL}}  {fmt_n(m_enc):>8}  {m_er:>8}  {fmt_n(w_enc):>8}  {w_er:>8}  {fmt_n(m_dec):>8}  {fmt_n(w_dec):>8}")

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

def write_csv(path, mac, win, win_dec, win_rss, raw_mb, dataset, mac_n):
    tgz_win   = win.get("TGZ", {})
    tgz_bytes = fv(tgz_win.get("encoded_bytes")) if tgz_win.get("valid", "yes") != "no" else None

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

        # Decode
        mac_dec_mbs = fv(m.get("decode_mb_s")) if m else None
        mac_dec_sec = fv(m.get("decode_seconds")) if m else None
        d = win_dec.get(name) if win_dec else None
        win_dec_sec, win_dec_mbs = compute_win_decode_speed(d, raw_mb) if d else (None, None)
        win_dec_verify = (d.get("verify") or "") if d else ""
        win_enc_rss = win_rss_value(win, win_rss, name, "encode_rss_mb")
        win_dec_rss = win_rss_value(win, win_rss, name, "decode_rss_mb")
        mac_enc_rss = fv(m.get("encode_rss_mb")) if m else None
        mac_dec_rss = fv(m.get("decode_rss_mb")) if m else None

        valid     = w and w.get("valid", "yes") != "no" and not suspicious
        note = ""
        if not valid and w:
            note = f"WIN RESULT INVALID: {w.get('note') or 'marked invalid or suspicious'}"
        elif not w:
            note = "Windows result missing"

        win_n = f"inflight={w.get('n') or '?'} (1 run)" if w and name.startswith("LZFSE") \
                else "single run (no -n)"

        rows.append({
            "dataset":              dataset,
            "format":               name,
            "win_n_meaning":        win_n,
            "mac_n":                str(mac_n),
            "win_encode_mb_s":      fmt_n(win_mbs, 2),
            "mac_encode_mb_s":      fmt_n(mac_mbs, 2),
            "win_mac_speed_ratio":  fmt_n(win_mbs / mac_mbs if win_mbs and mac_mbs else None, 3),
            "win_compress_ratio":   fmt_n(win_ratio, 4),
            "mac_compress_ratio":   fmt_n(mac_ratio, 4),
            "compress_ratio_diff":  fmt_n(win_ratio - mac_ratio
                                          if win_ratio is not None and mac_ratio is not None
                                          else None, 4),
            "win_encode_sec":       fmt_n(win_sec, 2),
            "mac_encode_sec":       fmt_n(mac_sec, 2),
            "win_decode_mb_s":      fmt_n(win_dec_mbs, 2),
            "mac_decode_mb_s":      fmt_n(mac_dec_mbs, 2),
            "win_mac_decode_ratio": fmt_n(win_dec_mbs / mac_dec_mbs
                                          if win_dec_mbs and mac_dec_mbs else None, 3),
            "win_decode_sec":       fmt_n(win_dec_sec, 2),
            "mac_decode_sec":       fmt_n(mac_dec_sec, 2),
            "win_decode_verify":    win_dec_verify,
            "win_encode_rss_mb":    fmt_n(win_enc_rss, 2),
            "mac_encode_rss_mb":    fmt_n(mac_enc_rss, 2),
            "win_decode_rss_mb":    fmt_n(win_dec_rss, 2),
            "mac_decode_rss_mb":    fmt_n(mac_dec_rss, 2),
            "note":                 note,
        })

    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8-sig") as fh:
        w = csv.writer(fh, lineterminator="\n")
        w.writerow(CSV_FIELDS)
        w.writerow([CSV_LABEL_BY_FIELD.get(field, field) for field in CSV_FIELDS])
        for r in rows:
            w.writerow([r[f] for f in CSV_FIELDS])

    return rows


# ── main ─────────────────────────────────────────────────────────────────────

def main():
    here   = Path(__file__).resolve().parent
    csv_dir = here / "bench_results_csv"
    ap     = argparse.ArgumentParser(description="macOS vs Windows benchmark comparison")
    ap.add_argument("--mac",         type=Path, default=here.parent / "BenchMarkResult.csv")
    ap.add_argument("--win-summary", type=Path, default=csv_dir / "benchmark_summary.csv")
    ap.add_argument("--win-decode",  type=Path, default=None)
    ap.add_argument("--win-rss",     type=Path, default=None)
    ap.add_argument("--output",      type=Path, default=csv_dir / "comparison.csv")
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

    # Auto-detect decode_summary.csv if not specified
    win_dec_path = args.win_decode
    if win_dec_path is None:
        default_dec = args.win_summary.parent / "decode_summary.csv"
        if default_dec.exists():
            win_dec_path = default_dec
    win_dec = load_decode_summary(win_dec_path) if win_dec_path and win_dec_path.exists() else {}
    win_rss_path = args.win_rss
    if win_rss_path is None:
        default_rss = args.win_summary.parent / "rss_summary.csv"
        if default_rss.exists():
            win_rss_path = default_rss
    win_rss = load_rss_summary(win_rss_path) if win_rss_path and win_rss_path.exists() else {}

    tgz_mac = mac.get("TGZ", {})
    raw_mb  = (parse_mib(tgz_mac.get("raw_size_mib")) or 0) * 1.048576  # MiB → MB

    print()
    print("=" * 78)
    print(f"  macOS vs Windows — dataset={args.dataset}  mac_n={args.n}  win_n=40(inflight)")
    print(f"  macOS  : {args.mac.name}")
    print(f"  Windows: {args.win_summary.name}")
    if win_dec:
        print(f"  Win Dec: {win_dec_path.name}")
    if win_rss:
        print(f"  Win RSS: {win_rss_path.name}")
    print()
    print(f"  Workflow: R{{N}}-Mac first → R{{N}}-Win → this script.")
    print(f"  Semantic: macOS -n {args.n} = {args.n} repetitions (avg).")
    print(f"            Windows -n 40 = inflight chunk count (single run).")
    print("=" * 78)

    report_speed(mac, win, win_dec, raw_mb)
    report_compression(mac, win)
    report_rss_win(mac, win, win_rss)
    report_energy(mac)

    print()
    print("=" * 78)
    print()

    rows = write_csv(args.output.resolve(), mac, win, win_dec, win_rss, raw_mb, args.dataset, args.n)
    print(f"[OK] {args.output} written ({len(rows)} rows)")
    for r in rows:
        enc_spd = r["win_encode_mb_s"] or "N/A"
        dec_spd = r["win_decode_mb_s"] or "N/A"
        note = f"  {r['note']}" if r["note"] else ""
        print(f"  {r['format']:<20} Win enc {enc_spd:>7} MB/s  dec {dec_spd:>7} MB/s{note}")


if __name__ == "__main__":
    main()
