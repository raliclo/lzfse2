"""彙整 Windows benchmark 原始紀錄並輸出 encode_summary.csv 與 decode_summary.csv。

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

BENCHMARK_RESULT_ORDER = [
    "TGZ",
    "LZFSE (Other3)",
    "LZFSE (Lazy2)",
    "LZFSE (Optimal)",
    "LZFSE (BVX3)",
    "TLZ4",
    "ZSTD",
]

RSS_FORMAT_MAP = {
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
DISPLAY_BY_TOKEN = {**FORMATS, **DECODE_FORMATS}

NAME_RE = re.compile(
    r"^(?P<dataset>.+)-(?P<token>(?:en|de)code(?:Tgz|Other3|BVX3|Lazy2|Optimal|LZ4|ZSTD))"
    r"(?:-n(?P<n>\d+))?(?:-(?P<mode>file|nul))?-results\.txt$"
)
NS_RE = re.compile(r"Process took:\s*(\d+)")
BYTES_RE = re.compile(r"Encoded size:\s*(\d+)")
VERIFY_RE = re.compile(r"Verify:\s*(\w+)")
ENCODE_OUTPUT_RE = re.compile(r"Encode output:\s*(write to (?:file|nul))")
DECODE_OUTPUT_RE = re.compile(r"Decode output:\s*(write to (?:file|nul))")


def read_result(path):
    text = path.read_text(encoding="utf-8", errors="replace")
    ns_match = NS_RE.search(text)
    if not ns_match:
        return None
    bytes_match = BYTES_RE.search(text)
    verify_match = VERIFY_RE.search(text)
    encode_output_match = ENCODE_OUTPUT_RE.search(text)
    decode_output_match = DECODE_OUTPUT_RE.search(text)
    return (
        int(ns_match.group(1)),
        (int(bytes_match.group(1)) if bytes_match else 0),
        (verify_match.group(1).upper() if verify_match else None),
        (encode_output_match.group(1) if encode_output_match else None),
        (decode_output_match.group(1) if decode_output_match else None),
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
                "filename_mode": match.group("mode") or "",
                "nanoseconds": parsed[0],
                "encoded_bytes": parsed[1],
                "verify": parsed[2],
                "encode_output": parsed[3],
                "decode_output": parsed[4],
                "mtime": path.stat().st_mtime,
            })
    return candidates


def load_rss_summary(path):
    if not path.is_file():
        return {}
    with path.open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        rows = {}
        for row in reader:
            display = RSS_FORMAT_MAP.get((row.get("format") or "").strip())
            if not display:
                continue
            dataset = (row.get("dataset") or "").strip()
            mode = normalize_mode(row.get("output_mode") or row.get("mode") or "")
            key = (dataset, display, mode) if dataset else (display, mode)
            rows[key] = {
                "encode_rss_mb": row.get("encode_rss_mb", ""),
                "decode_rss_mb": row.get("decode_rss_mb", ""),
            }
        return rows


def attach_rss(rows, rss_rows):
    if not rss_rows:
        return rows
    for row in rows:
        display = DISPLAY_BY_TOKEN.get(row.get("_token"))
        mode = row.get("_output_mode", "")
        rss = (
            rss_rows.get((row.get("dataset", ""), display or "", mode))
            or rss_rows.get((display or "", mode))
            or rss_rows.get((row.get("dataset", ""), display or "", ""))
            or rss_rows.get((display or "", ""))
        )
        if not rss:
            continue
        row["encode_rss_mb"] = rss.get("encode_rss_mb", "")
        row["decode_rss_mb"] = rss.get("decode_rss_mb", "")
    return rows


def normalize_mode(value):
    value = (value or "").strip().lower()
    if value in {"file", "write to file"}:
        return "file"
    if value in {"nul", "null", "write to nul", "write to null"}:
        return "nul"
    return ""


def summarize(candidates, status_log, format_order, is_decode=False):
    grouped = {}
    for item in candidates:
        mode = item["filename_mode"] or normalize_mode(item.get("encode_output") or item.get("decode_output"))
        key = (item["dataset"], item["token"], item["n"], mode)
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
        mode = current["filename_mode"] or normalize_mode(current.get("encode_output") or current.get("decode_output"))
        # Decode validity: timing is what matters; compressed_bytes is informational
        valid = current["nanoseconds"] > 0
        if not is_decode and current.get("encode_output") != "write to nul":
            valid = valid and current["encoded_bytes"] > 0
        notes = []
        if not is_decode and current.get("encode_output"):
            notes.append(current["encode_output"])
        if is_decode and current.get("decode_output"):
            notes.append(current["decode_output"])

        if (
            not is_decode
            and current.get("encode_output") != "write to nul"
            and len(versions) > 1
            and versions[1]["encoded_bytes"] > 0
        ):
            previous = versions[1]["encoded_bytes"]
            size_ratio = current["encoded_bytes"] / previous if current["encoded_bytes"] > 0 else 0
            if size_ratio < 0.5 or size_ratio > 2.0:
                valid = False
                notes.append(
                    f"encoded size is {size_ratio:.1%} of previous result"
                )

        if (
            tar_write_error
            and current["token"] == "encodeOptimal"
            and current.get("encode_output") != "write to nul"
        ):
            valid = False
            notes.insert(0, "tar write error")

        suffix = f"-n{current['n']}" if current["n"] else ""
        rows.append({
            "dataset": current["dataset"],
            "format": f"{current['token']}{suffix}",
            "nanoseconds": current["nanoseconds"],
            "encoded_bytes": current["encoded_bytes"],
            "valid": "yes" if valid else "no",
            "verify": current["verify"] or "",
            "note": "; ".join(notes),
            "_token": current["token"],
            "_output_mode": mode,
        })

    rows.sort(key=lambda row: (
        row["dataset"],
        format_order.get(row["_token"], 999),
        row["format"],
        row.get("_output_mode", ""),
    ))
    return rows


def write_csv(path, rows, include_verify=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    fields = ["dataset", "format", "nanoseconds", "encoded_bytes", "valid"]
    if include_verify:
        fields.append("verify")
    if any("encode_rss_mb" in row or "decode_rss_mb" in row for row in rows):
        fields.extend(["encode_rss_mb", "decode_rss_mb"])
    fields.append("note")
    with path.open("w", newline="", encoding="utf-8-sig") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        for row in rows:
            writer.writerow({field: row.get(field, "") for field in fields})


def parse_summary_key(value):
    match = re.match(r"^(?P<token>(?:en|de)code\w+?)(?:-n(?P<n>\d+))?$", value or "")
    if not match:
        return "", ""
    return match.group("token"), match.group("n") or ""


def parse_mib(value):
    match = re.match(r"^\s*([0-9.]+)\s*([KMG]?)", str(value or ""), re.I)
    if not match:
        return None
    amount = float(match.group(1))
    unit = match.group(2).upper()
    return amount * {"": 1, "K": 1 / 1024, "M": 1, "G": 1024}[unit]


def fmt_seconds(ns):
    return f"{int(ns) / 1_000_000_000:.2f}" if ns not in ("", None) else ""


def fmt_mib_from_bytes(num_bytes):
    if num_bytes in ("", None):
        return ""
    return f"{round(int(num_bytes) / 1024 / 1024)}M"


def load_mac_result_template(path, dataset, n_value):
    """Return (header, zh_labels, raw_size_mib) from BenchMarkResult.csv."""
    default_header = [
        "dataset", "n", "format", "raw_size_mib", "compressed_size_mib",
        "encode_seconds", "decode_seconds", "encode_mb_s", "decode_mb_s",
        "compression_ratio", "encode_time_ratio", "decode_time_ratio",
        "encode_rss_mb", "decode_rss_mb", "trace_wall_seconds", "trace_timeout",
        "trace_target_seen", "cpu_symbol_status", "cpu_top_symbol", "cpu_top_count",
        "cpu_top_category", "cpu_parse_hits", "cpu_encode_hits", "cpu_fse_hits",
        "cpu_swift_array_hits", "encode_cpu_power_mw", "decode_cpu_power_mw",
        "encode_cpu_energy_j", "decode_cpu_energy_j", "encode_cpu_energy_ratio_tgz",
        "decode_cpu_energy_ratio_tgz",
    ]
    default_labels = [
        "資料夾", "N", "格式", "原始大小(M)", "壓縮後(M)",
        "壓縮耗時(秒)", "解壓耗時(秒)", "壓縮 MB/s", "解壓 MB/s",
        "壓縮比", "壓縮時間比", "解壓時間比", "Encode RSS(MB)",
        "Decode RSS(MB)", "Trace wall time(秒)", "Trace timeout",
        "Trace target seen", "CPU Symbol Status", "CPU Top Symbol",
        "CPU Top Count", "CPU Top Category", "CPU Parse Hits",
        "CPU Encode Hits", "CPU FSE Hits", "CPU Swift Array Hits",
        "Encode CPU Power(mW)", "Decode CPU Power(mW)", "Encode CPU Energy(J)",
        "Decode CPU Energy(J)", "Encode CPU Energy Ratio (TGZ=1)",
        "Decode CPU Energy Ratio (TGZ=1)",
    ]
    raw_size = ""
    if not path.is_file():
        return default_header, default_labels, raw_size

    with path.open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.reader(handle)
        rows = list(reader)
    header = rows[0] if rows else default_header
    labels = rows[1] if len(rows) > 1 and len(rows[1]) == len(header) else default_labels

    with path.open(newline="", encoding="utf-8-sig") as handle:
        for row in csv.DictReader(handle):
            if row.get("dataset") == dataset and row.get("n") == str(n_value):
                raw_size = row.get("raw_size_mib", "")
                break
    if not raw_size:
        with path.open(newline="", encoding="utf-8-sig") as handle:
            for row in csv.DictReader(handle):
                if row.get("dataset") == dataset:
                    raw_size = row.get("raw_size_mib", "")
                    break
    return header, labels, raw_size


def ensure_windows_mode_columns(header, labels):
    extra_columns = [
        "encode_mb_s(file)",
        "decode_mb_s(file)",
        "encode_rss_mb(file)",
        "decode_rss_mb(file)",
        "encode_mb_s(null)",
        "decode_mb_s(null)",
        "encode_rss_mb(null)",
        "decode_rss_mb(null)",
    ]
    extra_labels = [
        "Encode MB/s (write to file)",
        "Decode MB/s (write to file)",
        "Encode RSS MB (write to file)",
        "Decode RSS MB (write to file)",
        "Encode MB/s (write to null)",
        "Decode MB/s (write to null)",
        "Encode RSS MB (write to null)",
        "Decode RSS MB (write to null)",
    ]
    for column, label in zip(extra_columns, extra_labels):
        if column not in header:
            header.append(column)
            labels.append(label)
    return header, labels


def write_benchmark_result_win(path, mac_template_path, dataset, n_value, enc_rows, dec_rows):
    """Write BenchMarkResult-Win.csv with the same columns as BenchMarkResult.csv."""
    header, labels, raw_size = load_mac_result_template(mac_template_path, dataset, n_value)
    header, labels = ensure_windows_mode_columns(list(header), list(labels))
    raw_mib = parse_mib(raw_size)
    raw_mb = raw_mib * 1.048576 if raw_mib is not None else None

    enc_by_name_mode = {}
    for row in enc_rows:
        token, row_n = parse_summary_key(row.get("format"))
        name = FORMATS.get(token)
        if name:
            enc_by_name_mode[(name, row.get("_output_mode") or "file")] = {**row, "n": row_n}

    dec_by_name_mode = {}
    for row in dec_rows:
        token, _ = parse_summary_key(row.get("format"))
        name = DECODE_FORMATS.get(token)
        if name:
            dec_by_name_mode[(name, row.get("_output_mode") or "nul")] = row

    def row_for(mapping, name, preferred_mode):
        return mapping.get((name, preferred_mode)) or mapping.get((name, "file")) or mapping.get((name, "nul")) or {}

    tgz_enc = row_for(enc_by_name_mode, "TGZ", "file")
    tgz_dec = row_for(dec_by_name_mode, "TGZ", "file")
    tgz_bytes = int(tgz_enc.get("encoded_bytes") or 0)
    tgz_encode_seconds = int(tgz_enc.get("nanoseconds") or 0) / 1_000_000_000 if tgz_enc else None
    tgz_decode_seconds = int(tgz_dec.get("nanoseconds") or 0) / 1_000_000_000 if tgz_dec else None

    output_rows = []
    for name in BENCHMARK_RESULT_ORDER:
        enc = row_for(enc_by_name_mode, name, "file")
        if not enc:
            continue
        dec = row_for(dec_by_name_mode, name, "file")
        encoded_bytes = int(enc.get("encoded_bytes") or 0)
        encode_seconds = int(enc.get("nanoseconds") or 0) / 1_000_000_000
        decode_seconds = int(dec.get("nanoseconds") or 0) / 1_000_000_000 if dec.get("nanoseconds") else None
        enc_file = row_for(enc_by_name_mode, name, "file")
        enc_nul = row_for(enc_by_name_mode, name, "nul")
        dec_file = row_for(dec_by_name_mode, name, "file")
        dec_nul = row_for(dec_by_name_mode, name, "nul")
        enc_file_seconds = int(enc_file.get("nanoseconds") or 0) / 1_000_000_000 if enc_file.get("nanoseconds") else None
        enc_nul_seconds = int(enc_nul.get("nanoseconds") or 0) / 1_000_000_000 if enc_nul.get("nanoseconds") else None
        dec_file_seconds = int(dec_file.get("nanoseconds") or 0) / 1_000_000_000 if dec_file.get("nanoseconds") else None
        dec_nul_seconds = int(dec_nul.get("nanoseconds") or 0) / 1_000_000_000 if dec_nul.get("nanoseconds") else None

        record = {field: "" for field in header}
        record.update({
            "dataset": dataset,
            "n": str(n_value),
            "format": name,
            "raw_size_mib": raw_size,
            "compressed_size_mib": fmt_mib_from_bytes(encoded_bytes),
            "encode_seconds": f"{encode_seconds:.2f}",
            "decode_seconds": f"{decode_seconds:.2f}" if decode_seconds is not None else "",
            "encode_mb_s": f"{raw_mb / encode_seconds:.2f}" if raw_mb and encode_seconds else "",
            "decode_mb_s": f"{raw_mb / decode_seconds:.2f}" if raw_mb and decode_seconds else "",
            "compression_ratio": f"{encoded_bytes / tgz_bytes:.4f}" if encoded_bytes and tgz_bytes else "",
            "encode_time_ratio": f"{encode_seconds / tgz_encode_seconds:.4f}" if encode_seconds and tgz_encode_seconds else "",
            "decode_time_ratio": f"{decode_seconds / tgz_decode_seconds:.4f}" if decode_seconds and tgz_decode_seconds else "",
            "encode_rss_mb": enc.get("encode_rss_mb", ""),
            "decode_rss_mb": (dec.get("decode_rss_mb") or enc.get("decode_rss_mb", "")),
            "encode_mb_s(file)": f"{raw_mb / enc_file_seconds:.2f}" if raw_mb and enc_file_seconds else "",
            "decode_mb_s(file)": f"{raw_mb / dec_file_seconds:.2f}" if raw_mb and dec_file_seconds else "",
            "encode_rss_mb(file)": enc_file.get("encode_rss_mb", ""),
            "decode_rss_mb(file)": dec_file.get("decode_rss_mb", ""),
            "encode_mb_s(null)": f"{raw_mb / enc_nul_seconds:.2f}" if raw_mb and enc_nul_seconds else "",
            "decode_mb_s(null)": f"{raw_mb / dec_nul_seconds:.2f}" if raw_mb and dec_nul_seconds else "",
            "encode_rss_mb(null)": enc_nul.get("encode_rss_mb", ""),
            "decode_rss_mb(null)": dec_nul.get("decode_rss_mb", ""),
        })
        output_rows.append(record)

    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8-sig") as handle:
        writer = csv.DictWriter(handle, fieldnames=header, lineterminator="\n")
        writer.writeheader()
        writer.writerow(dict(zip(header, labels)))
        writer.writerows(output_rows)
    return output_rows


def write_all_benchmark_results_win(path, mac_template_path, enc_rows, dec_rows):
    keys = sorted({
        (row.get("dataset", ""), parse_summary_key(row.get("format"))[1])
        for row in enc_rows
        if row.get("dataset")
    })
    all_rows = []
    header = labels = None
    path.parent.mkdir(parents=True, exist_ok=True)
    for dataset, n_value in keys:
        enc_subset = [row for row in enc_rows if row.get("dataset") == dataset and parse_summary_key(row.get("format"))[1] == n_value]
        dec_subset = [row for row in dec_rows if row.get("dataset") == dataset and parse_summary_key(row.get("format"))[1] == n_value]
        if not enc_subset or not dec_subset:
            continue
        header, labels, _ = load_mac_result_template(mac_template_path, dataset, n_value)
        header, labels = ensure_windows_mode_columns(list(header), list(labels))
        rows = write_benchmark_result_win(path, mac_template_path, dataset, n_value, enc_subset, dec_subset)
        all_rows.extend(rows)

    if header is None:
        header, labels, _ = load_mac_result_template(mac_template_path, "", "")
        header, labels = ensure_windows_mode_columns(list(header), list(labels))
    with path.open("w", newline="", encoding="utf-8-sig") as handle:
        writer = csv.DictWriter(handle, fieldnames=header, lineterminator="\n")
        writer.writeheader()
        writer.writerow(dict(zip(header, labels)))
        writer.writerows(all_rows)
    return all_rows


def main():
    here = Path(__file__).resolve().parent
    csv_dir = here / "bench_results_csv"
    parser = argparse.ArgumentParser(description="Generate Windows benchmark summary CSVs")
    parser.add_argument("--results-dir", type=Path, default=here)
    parser.add_argument("--output", type=Path, default=csv_dir / "encode_summary.csv")
    parser.add_argument("--decode-output", type=Path, default=csv_dir / "decode_summary.csv")
    parser.add_argument("--benchmark-result-output", type=Path, default=csv_dir / "BenchMarkResult-Win.csv")
    parser.add_argument("--mac-result", type=Path, default=here.parent / "BenchMarkResult.csv")
    parser.add_argument("--status-log", type=Path, default=here / "windows_round_status.txt")
    parser.add_argument("--rss-summary", type=Path, default=csv_dir / "rss_summary.csv")
    args = parser.parse_args()

    candidates = collect(args.results_dir.resolve())
    if not candidates:
        print(f"No benchmark result files found under {args.results_dir}", file=sys.stderr)
        return 1

    enc_candidates = [c for c in candidates if c["token"].startswith("encode")]
    dec_candidates = [c for c in candidates if c["token"].startswith("decode")]
    rss_rows = load_rss_summary(args.rss_summary.resolve())

    enc_rows = []
    dec_rows = []

    if enc_candidates:
        enc_rows = summarize(enc_candidates, args.status_log.resolve(), FORMAT_ORDER)
        attach_rss(enc_rows, rss_rows)
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
        attach_rss(dec_rows, rss_rows)
        write_csv(args.decode_output.resolve(), dec_rows, include_verify=True)
        print(f"[OK] {args.decode_output.resolve()} written ({len(dec_rows)} rows)")
        for row in dec_rows:
            state = "OK" if row["valid"] == "yes" else f"INVALID: {row['note']}"
            seconds = row["nanoseconds"] / 1_000_000_000
            size_str = f"{row['encoded_bytes']:>12} bytes" if row["encoded_bytes"] else "  (size unknown)"
            verify_str = f"  verify={row['verify']}" if row["verify"] else "  verify=?"
            print(f"     {row['format']:<22} {seconds:8.2f}s  {size_str}  {state}{verify_str}")

    if enc_rows and dec_rows:
        result_rows = write_all_benchmark_results_win(
            args.benchmark_result_output.resolve(),
            args.mac_result.resolve(),
            enc_rows,
            dec_rows,
        )
        print(f"[OK] {args.benchmark_result_output.resolve()} written ({len(result_rows)} rows)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
