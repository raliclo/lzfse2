"""彙整 Windows benchmark 原始紀錄並輸出 benchmark_summary.csv 與 decode_summary.csv。

Usage:
    python summarize_win.py [--results-dir DIR] [--output CSV] [--decode-output CSV]

工具會同時檢查 DIR 與 DIR/bench_logs，對每個格式選用最新紀錄。
若最新輸出大小與上一份紀錄相差超過 50%，會標記為無效，避免截斷輸出
（例如 tar write error）被誤當成壓縮率改善。
"""

import argparse
import csv
import re
import sys
from pathlib import Path


FORMATS = {
    "encodeTgz": "TGZ",
    "encodeOther3": "LZFSE (Other3)",
    "encodeBVX3": "LZFSE (BVX3)",
    "encodeLazy2": "LZFSE (Lazy2)",
    "encodeOptimal": "LZFSE (Optimal)",
    "encodeLZ4": "TLZ4",
    "encodeZSTD": "ZSTD",
}
FORMAT_ORDER = {name: i for i, name in enumerate(FORMATS)}

DECODE_FORMATS = {
    "decodeTgz": "TGZ",
    "decodeOther3": "LZFSE (Other3)",
    "decodeBVX3": "LZFSE (BVX3)",
    "decodeLazy2": "LZFSE (Lazy2)",
    "decodeOptimal": "LZFSE (Optimal)",
    "decodeLZ4": "TLZ4",
    "decodeZSTD": "ZSTD",
}
DECODE_FORMAT_ORDER = {name: i for i, name in enumerate(DECODE_FORMATS)}

NAME_RE = re.compile(
    r"^(?P<dataset>.+)-(?P<token>(?:en|de)code(?:Tgz|Other3|BVX3|Lazy2|Optimal|LZ4|ZSTD))"
    r"(?:-n(?P<n>\d+))?-results\.txt$"
)
NS_RE = re.compile(r"Process took:\s*(\d+)")
BYTES_RE = re.compile(r"Encoded size:\s*(\d+)")
VERIFY_RE = re.compile(r"Verify:\s*(\w+)")


def read_result(path):
    text = path.read_text(encoding="utf-8", errors="replace")
    ns_match = NS_RE.search(text)
    if not ns_match:
        return None
    bytes_match = BYTES_RE.search(text)
    verify_match = VERIFY_RE.search(text)
    return (
        int(ns_match.group(1)),
        (int(bytes_match.group(1)) if bytes_match else 0),
        (verify_match.group(1).upper() if verify_match else None),
    )


def collect(results_dir):
    candidates = []
    for directory in (results_dir, results_dir / "bench_logs"):
        if not directory.is_dir():
            continue
        for path in directory.glob("*-results.txt"):
            match = NAME_RE.match(path.name)
            parsed = read_result(path) if match else None
            if not match or not parsed:
                continue
            candidates.append({
                "path": path,
                "dataset": match.group("dataset"),
                "token": match.group("token"),
                "n": match.group("n") or "",
                "nanoseconds": parsed[0],
                "encoded_bytes": parsed[1],
                "verify": parsed[2],
                "mtime": path.stat().st_mtime,
            })
    return candidates


def summarize(candidates, status_log, format_order, is_decode=False):
    grouped = {}
    for item in candidates:
        key = (item["dataset"], item["token"], item["n"])
        grouped.setdefault(key, []).append(item)

    tar_write_error = False
    if not is_decode and status_log.is_file():
        tar_write_error = "tar: Write error" in status_log.read_text(
            encoding="utf-8", errors="replace"
        )

    rows = []
    for key, versions in grouped.items():
        versions.sort(key=lambda item: item["mtime"], reverse=True)
        current = versions[0]
        # Decode validity: timing is what matters; compressed_bytes is informational
        valid = current["nanoseconds"] > 0
        if not is_decode:
            valid = valid and current["encoded_bytes"] > 0
        notes = []

        if not is_decode and len(versions) > 1 and versions[1]["encoded_bytes"] > 0:
            previous = versions[1]["encoded_bytes"]
            size_ratio = current["encoded_bytes"] / previous if current["encoded_bytes"] > 0 else 0
            if size_ratio < 0.5 or size_ratio > 2.0:
                valid = False
                notes.append(
                    f"encoded size is {size_ratio:.1%} of previous result"
                )

        if tar_write_error and current["token"] == "encodeOptimal":
            valid = False
            notes.insert(0, "tar write error")

        suffix = f"-n{current['n']}" if current["n"] else ""
        rows.append({
            "format": f"{current['token']}{suffix}",
            "nanoseconds": current["nanoseconds"],
            "encoded_bytes": current["encoded_bytes"],
            "valid": "yes" if valid else "no",
            "verify": current["verify"] or "",
            "note": "; ".join(notes),
            "_token": current["token"],
        })

    rows.sort(key=lambda row: (format_order.get(row["_token"], 999), row["format"]))
    return rows


def write_csv(path, rows, include_verify=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    fields = ["format", "nanoseconds", "encoded_bytes", "valid"]
    if include_verify:
        fields.append("verify")
    fields.append("note")
    with path.open("w", newline="", encoding="utf-8-sig") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        for row in rows:
            writer.writerow({field: row.get(field, "") for field in fields})


def main():
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description="Generate Windows benchmark summary CSVs")
    parser.add_argument("--results-dir", type=Path, default=here)
    parser.add_argument("--output", type=Path, default=here / "benchmark_summary.csv")
    parser.add_argument("--decode-output", type=Path, default=here / "decode_summary.csv")
    parser.add_argument("--status-log", type=Path, default=here / "windows_round_status.txt")
    args = parser.parse_args()

    candidates = collect(args.results_dir.resolve())
    if not candidates:
        print(f"No benchmark result files found under {args.results_dir}", file=sys.stderr)
        return 1

    enc_candidates = [c for c in candidates if c["token"].startswith("encode")]
    dec_candidates = [c for c in candidates if c["token"].startswith("decode")]

    if enc_candidates:
        enc_rows = summarize(enc_candidates, args.status_log.resolve(), FORMAT_ORDER)
        write_csv(args.output.resolve(), enc_rows)
        print(f"[OK] {args.output.resolve()} written ({len(enc_rows)} rows)")
        for row in enc_rows:
            state = "OK" if row["valid"] == "yes" else f"INVALID: {row['note']}"
            seconds = row["nanoseconds"] / 1_000_000_000
            print(f"     {row['format']:<22} {seconds:8.2f}s  {row['encoded_bytes']:>12} bytes  {state}")
    else:
        print("No encode result files found.", file=sys.stderr)

    if dec_candidates:
        dec_rows = summarize(dec_candidates, args.status_log.resolve(), DECODE_FORMAT_ORDER, is_decode=True)
        write_csv(args.decode_output.resolve(), dec_rows, include_verify=True)
        print(f"[OK] {args.decode_output.resolve()} written ({len(dec_rows)} rows)")
        for row in dec_rows:
            state = "OK" if row["valid"] == "yes" else f"INVALID: {row['note']}"
            seconds = row["nanoseconds"] / 1_000_000_000
            size_str = f"{row['encoded_bytes']:>12} bytes" if row["encoded_bytes"] else "  (size unknown)"
            verify_str = f"  verify={row['verify']}" if row["verify"] else "  verify=?"
            print(f"     {row['format']:<22} {seconds:8.2f}s  {size_str}  {state}{verify_str}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
