"""彙整 Windows benchmark 原始紀錄並輸出 benchmark_summary.csv。

Usage:
    python summarize_win.py [--results-dir DIR] [--output CSV]

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
NAME_RE = re.compile(
    r"^(?P<dataset>.+)-(?P<token>encode(?:Tgz|Other3|BVX3|Lazy2|Optimal|LZ4|ZSTD))"
    r"(?:-n(?P<n>\d+))?-results\.txt$"
)
NS_RE = re.compile(r"Process took:\s*(\d+)")
BYTES_RE = re.compile(r"Encoded size:\s*(\d+)")


def read_result(path):
    text = path.read_text(encoding="utf-8", errors="replace")
    ns_match = NS_RE.search(text)
    bytes_match = BYTES_RE.search(text)
    if not ns_match or not bytes_match:
        return None
    return int(ns_match.group(1)), int(bytes_match.group(1))


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
                "mtime": path.stat().st_mtime,
            })
    return candidates


def summarize(candidates, status_log):
    grouped = {}
    for item in candidates:
        key = (item["dataset"], item["token"], item["n"])
        grouped.setdefault(key, []).append(item)

    tar_write_error = False
    if status_log.is_file():
        tar_write_error = "tar: Write error" in status_log.read_text(
            encoding="utf-8", errors="replace"
        )

    rows = []
    for key, versions in grouped.items():
        versions.sort(key=lambda item: item["mtime"], reverse=True)
        current = versions[0]
        valid = current["nanoseconds"] > 0 and current["encoded_bytes"] > 0
        notes = []

        if len(versions) > 1 and versions[1]["encoded_bytes"] > 0:
            previous = versions[1]["encoded_bytes"]
            size_ratio = current["encoded_bytes"] / previous
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
            "note": "; ".join(notes),
            "_token": current["token"],
        })

    rows.sort(key=lambda row: (FORMAT_ORDER[row["_token"]], row["format"]))
    return rows


def write_csv(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    fields = ["format", "nanoseconds", "encoded_bytes", "valid", "note"]
    with path.open("w", newline="", encoding="utf-8-sig") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        for row in rows:
            writer.writerow({field: row[field] for field in fields})


def main():
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description="Generate Windows benchmark summary CSV")
    parser.add_argument("--results-dir", type=Path, default=here)
    parser.add_argument("--output", type=Path, default=here / "benchmark_summary.csv")
    parser.add_argument("--status-log", type=Path, default=here / "windows_round_status.txt")
    args = parser.parse_args()

    candidates = collect(args.results_dir.resolve())
    if not candidates:
        print(f"No benchmark result files found under {args.results_dir}", file=sys.stderr)
        return 1

    rows = summarize(candidates, args.status_log.resolve())
    write_csv(args.output.resolve(), rows)
    print(f"[OK] {args.output.resolve()} written ({len(rows)} rows)")
    for row in rows:
        state = "OK" if row["valid"] == "yes" else f"INVALID: {row['note']}"
        seconds = row["nanoseconds"] / 1_000_000_000
        print(f"  {row['format']:<22} {seconds:8.2f}s  {row['encoded_bytes']:>12} bytes  {state}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
