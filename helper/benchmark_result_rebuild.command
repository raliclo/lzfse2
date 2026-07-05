#!/bin/zsh
set -euo pipefail

# Rebuild BenchMarkResult.csv from lz4bench + memProbe + trace summaries.
# 從 lz4bench、memProbe、trace summary 重新產生 BenchMarkResult.csv。
#
# Usage / 用法:
#   helper/benchmark_result_rebuild.command          # print CSV to stdout / 輸出到 stdout
#   helper/benchmark_result_rebuild.command --write  # overwrite BenchMarkResult.csv / 覆寫檔案

cd /Users/raliclo/proj/lzfse2
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

write_output="no"
if [[ "${1:-}" == "--write" ]]; then
    write_output="yes"
elif [[ $# -gt 0 ]]; then
    echo "Usage: $0 [--write]" >&2
    exit 2
fi

tmp_out="$(mktemp)"
trap 'rm -f "$tmp_out"' EXIT

python3 - <<'PY' > "$tmp_out"
import csv
import re
import sys
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8-sig", newline="")

BENCHMARK_LOG_DIR = Path("lz4bench_log")

FORMATS = [
    ("TGZ", "tgz"),
    ("LZFSE (Other3)", "other3"),
    ("LZFSE (Optimal3)", "optimal3"),
    ("LZFSE (Lazy2)", "lazy2"),
    ("LZFSE (Optimal)", "optimal"),
    ("LZFSE (BVX3)", "bvx3"),
    ("LZFSE (Apple)", "apple"),
    ("TLZ4", "tar.lz4"),
    ("ZSTD", "zstd"),
]

SIZE_SUFFIX = {
    "tgz": ".tgz",
    "other3": ".lzfse.other3",
    "optimal3": ".lzfse.other3.optimal3",
    "lazy2": ".lzfse.bvx3.lazy2",
    "optimal": ".lzfse.bvx3.optimal",
    "bvx3": ".lzfse.bvx3",
    "apple": ".lzfse.apple",
    "tar.lz4": ".tar.lz4",
    "zstd": ".zst",
}

FIELDS = [
    "資料夾",
    "N",
    "格式",
    "原始大小(M)",
    "壓縮後(M)",
    "壓縮耗時(秒)",
    "解壓耗時(秒)",
    "壓縮 MB/s",
    "解壓 MB/s",
    "壓縮比",
    "壓縮時間比",
    "解壓時間比",
    "Encode RSS(MB)",
    "Decode RSS(MB)",
    "Trace wall time(秒)",
    "Trace timeout",
    "Trace target seen",
    "CPU Symbol Status",
    "CPU Top Symbol",
    "CPU Top Count",
    "CPU Top Category",
    "CPU Parse Hits",
    "CPU Encode Hits",
    "CPU FSE Hits",
    "CPU Swift Array Hits",
]

EN_FIELDS = [
    "dataset",
    "n",
    "format",
    "raw_size_mib",
    "compressed_size_mib",
    "encode_seconds",
    "decode_seconds",
    "encode_mb_s",
    "decode_mb_s",
    "compression_ratio",
    "encode_time_ratio",
    "decode_time_ratio",
    "encode_rss_mb",
    "decode_rss_mb",
    "trace_wall_seconds",
    "trace_timeout",
    "trace_target_seen",
    "cpu_symbol_status",
    "cpu_top_symbol",
    "cpu_top_count",
    "cpu_top_category",
    "cpu_parse_hits",
    "cpu_encode_hits",
    "cpu_fse_hits",
    "cpu_swift_array_hits",
]


def require_match(pattern: str, text: str, source: str) -> re.Match[str]:
    match = re.search(pattern, text)
    if not match:
        raise RuntimeError(f"missing pattern in {source}: {pattern}")
    return match


def optional_ns(pattern: str, text: str) -> int | None:
    match = re.search(pattern, text)
    return int(match.group(1)) if match else None


def normalized_trace_key(trace_name: str) -> str:
    if trace_name.endswith(".trace.timeout"):
        return trace_name.removesuffix(".trace.timeout")
    if trace_name.endswith(".trace"):
        return trace_name.removesuffix(".trace")
    return trace_name


def load_trace_summaries() -> dict[str, dict[str, str]]:
    path = Path("trace/analysis/trace_summary.csv")
    if not path.exists():
        return {}

    summaries: dict[str, dict[str, str]] = {}
    with path.open(encoding="utf-8-sig", newline="") as handle:
        for record in csv.DictReader(handle):
            trace_name = record.get("trace", "")
            if not trace_name:
                continue
            summaries[normalized_trace_key(trace_name)] = record
    return summaries


def load_cpu_summaries() -> dict[str, dict[str, str]]:
    path = Path("trace/analysis/cpu_call_tree_summary/cpu_call_tree_summary.csv")
    if not path.exists():
        return {}

    summaries: dict[str, dict[str, str]] = {}
    with path.open(encoding="utf-8-sig", newline="") as handle:
        for record in csv.DictReader(handle):
            if record.get("kind") != "time-profile":
                continue
            file_name = record.get("file", "")
            if not file_name:
                continue
            key = file_name.removesuffix(".time-profile.xml")
            summaries[key] = record
    return summaries


def load_memprobe(dataset: str, n_value: int, algo: str) -> tuple[str, str]:
    path = Path(f"memprobeResults/{dataset}-n{n_value}-{algo}-memprobe.txt")
    if not path.exists():
        return "", ""

    text = path.read_text(encoding="utf-8", errors="replace")
    encode = re.search(r"\[MEM\] encode .* peak RSS: ([0-9.]+) MB", text)
    decode = re.search(r"\[MEM\] decode .* peak RSS: ([0-9.]+) MB", text)
    return (
        f"{float(encode.group(1)):.1f}" if encode else "",
        f"{float(decode.group(1)):.1f}" if decode else "",
    )


def trace_key(dataset: str, n_value: int, algo: str) -> str:
    if algo in ("tgz", "tar.lz4", "zstd"):
        return f"{dataset}-{algo}"
    return f"{dataset}-{algo}-n{n_value}"


def parse_benchmark(
    path: Path,
    trace_summaries: dict[str, dict[str, str]],
    cpu_summaries: dict[str, dict[str, str]],
) -> list[dict[str, str]]:
    match = re.match(r"lz4bench-(.*)-n(\d+)\.txt", path.name)
    if not match:
        raise RuntimeError(f"unexpected benchmark filename: {path}")

    dataset = match.group(1)
    n_value = int(match.group(2))
    text = path.read_text(encoding="utf-8", errors="replace")
    raw_kb = int(require_match(rf"\[SIZE\] {re.escape(dataset)} \(raw\): (\d+) KB", text, path.name).group(1))
    raw_bytes = raw_kb * 1024

    sizes: dict[str, int] = {}
    for algo, suffix in SIZE_SUFFIX.items():
        sizes[algo] = int(
            require_match(rf"\[SIZE\] {re.escape(dataset)}{re.escape(suffix)}: (\d+) bytes", text, path.name).group(1)
        )

    encode_patterns = {
        "tgz": rf"Process getar {re.escape(dataset)} took: (\d+)",
        "other3": rf"Process lzfseX {re.escape(dataset)} other3 took: (\d+)",
        "optimal3": rf"Process lzfseX {re.escape(dataset)} optimal3 took: (\d+)",
        "lazy2": rf"Process lzfseX {re.escape(dataset)} lazy2 took: (\d+)",
        "optimal": rf"Process lzfseX {re.escape(dataset)} optimal took: (\d+)",
        "bvx3": rf"Process lzfseX {re.escape(dataset)} bvx3 took: (\d+)",
        "apple": rf"Process lzfseX {re.escape(dataset)} apple took: (\d+)",
        "tar.lz4": rf"Process tlz4 {re.escape(dataset)} took: (\d+)",
        "zstd": rf"Process getzstd {re.escape(dataset)} took: (\d+)",
    }
    decode_patterns = {
        "tgz": rf"Process extract {re.escape(dataset)}\.tgz took: (\d+)",
        "other3": rf"Process extract {re.escape(dataset)}\.lzfse\.other3 took: (\d+)",
        "optimal3": rf"Process extract {re.escape(dataset)}\.lzfse\.other3\.optimal3 took: (\d+)",
        "lazy2": rf"Process extract {re.escape(dataset)}\.lzfse\.bvx3\.lazy2 took: (\d+)",
        "optimal": rf"Process extract {re.escape(dataset)}\.lzfse\.bvx3\.optimal took: (\d+)",
        "bvx3": rf"Process extract {re.escape(dataset)}\.lzfse\.bvx3 took: (\d+)",
        "apple": rf"Process extract {re.escape(dataset)}\.lzfse\.apple took: (\d+)",
        "tar.lz4": rf"Process extract {re.escape(dataset)}\.tar\.lz4 took: (\d+)",
        "zstd": rf"Process extract {re.escape(dataset)}\.zst took: (\d+)",
    }

    encode_ns = {
        algo: require_match(pattern, text, path.name)
        for algo, pattern in encode_patterns.items()
    }
    decode_ns = {
        algo: require_match(pattern, text, path.name)
        for algo, pattern in decode_patterns.items()
    }

    rows: list[dict[str, str]] = []
    for label, algo in FORMATS:
        encode_time_ns = int(encode_ns[algo].group(1))
        decode_time_ns = int(decode_ns[algo].group(1))
        encode_rss, decode_rss = load_memprobe(dataset, n_value, algo)
        key = trace_key(dataset, n_value, algo)
        trace_summary = trace_summaries.get(key, {})
        cpu_summary = cpu_summaries.get(key, {})
        trace_duration = trace_summary.get("duration_sec", "")

        rows.append({
            "資料夾": dataset,
            "N": str(n_value),
            "格式": label,
            "原始大小(M)": f"{raw_bytes / 1048576:.0f}M",
            "壓縮後(M)": f"{sizes[algo] / 1048576:.0f}M",
            "壓縮耗時(秒)": f"{encode_time_ns / 1e9:.2f}",
            "解壓耗時(秒)": f"{decode_time_ns / 1e9:.2f}",
            "壓縮 MB/s": f"{raw_bytes / encode_time_ns * 1000:.2f}",
            "解壓 MB/s": f"{raw_bytes / decode_time_ns * 1000:.2f}",
            "壓縮比": f"{sizes[algo] / sizes['tgz']:.4f}",
            "壓縮時間比": "",
            "解壓時間比": "",
            "Encode RSS(MB)": encode_rss,
            "Decode RSS(MB)": decode_rss,
            "Trace wall time(秒)": f"{float(trace_duration):.2f}" if trace_duration else "",
            "Trace timeout": trace_summary.get("timeout", ""),
            "Trace target seen": trace_summary.get("target_seen", ""),
            "CPU Symbol Status": cpu_summary.get("symbol_status", ""),
            "CPU Top Symbol": cpu_summary.get("top_symbol", ""),
            "CPU Top Count": cpu_summary.get("top_count", ""),
            "CPU Top Category": cpu_summary.get("top_category", ""),
            "CPU Parse Hits": cpu_summary.get("parse_hits", ""),
            "CPU Encode Hits": cpu_summary.get("encode_hits", ""),
            "CPU FSE Hits": cpu_summary.get("fse_hits", ""),
            "CPU Swift Array Hits": cpu_summary.get("swift_array_hits", ""),
        })

    tgz_row = next(row for row in rows if row["格式"] == "TGZ")
    tgz_encode_sec = float(tgz_row["壓縮耗時(秒)"])
    tgz_decode_sec = float(tgz_row["解壓耗時(秒)"])
    for row in rows:
        row["壓縮時間比"] = f"{float(row['壓縮耗時(秒)']) / tgz_encode_sec:.2f}"
        row["解壓時間比"] = f"{float(row['解壓耗時(秒)']) / tgz_decode_sec:.2f}"

    return rows


def discover_benchmark_files() -> list[Path]:
    # Only read the current benchmark log directory.
    # 只讀目前指定的 benchmark log 資料夾，不回退讀根目錄舊檔。
    if not BENCHMARK_LOG_DIR.is_dir():
        return []
    return sorted(BENCHMARK_LOG_DIR.glob("lz4bench-*-n*.txt"))


trace_summaries = load_trace_summaries()
cpu_summaries = load_cpu_summaries()
rows: list[dict[str, str]] = []
for benchmark_file in discover_benchmark_files():
    rows.extend(parse_benchmark(benchmark_file, trace_summaries, cpu_summaries))

dataset_order = {"claw-code": 0, "llama.cpp": 1}
algo_order = {algo: index for index, (_, algo) in enumerate(FORMATS)}
label_to_algo = {label: algo for label, algo in FORMATS}
rows.sort(key=lambda row: (
    dataset_order.get(row["資料夾"], 99),
    int(row["N"]),
    algo_order[label_to_algo[row["格式"]]],
))

if not rows:
    raise RuntimeError("no benchmark rows parsed")

writer = csv.writer(sys.stdout, lineterminator="\n")
writer.writerow(EN_FIELDS)
writer.writerow(FIELDS)
for row in rows:
    writer.writerow([row.get(field, "") for field in FIELDS])
PY

python3 - <<'PY' "$tmp_out"
import csv
import sys

path = sys.argv[1]
with open(path, encoding="utf-8-sig", newline="") as handle:
    raw_rows = list(csv.reader(handle))
if len(raw_rows) >= 2 and raw_rows[0] and raw_rows[0][0].lstrip("\ufeff") == "dataset" and raw_rows[1] and raw_rows[1][0] == "資料夾":
    rows = [dict(zip(raw_rows[1], row)) for row in raw_rows[2:]]
else:
    rows = list(csv.DictReader(open(path, encoding="utf-8-sig", newline="")))
expected_fields = {
    "資料夾", "N", "格式", "壓縮 MB/s", "解壓 MB/s", "Encode RSS(MB)", "Decode RSS(MB)"
}
if not rows:
    raise SystemExit("no rows generated")
if not expected_fields.issubset(rows[0].keys()):
    raise SystemExit("missing required columns")
if any(not row["N"] for row in rows):
    raise SystemExit("missing N value")
print(f"[Info] generated rows: {len(rows)}", file=sys.stderr)
PY

if [[ "$write_output" == "yes" ]]; then
    cp "$tmp_out" BenchMarkResult.csv
    echo "[Info] wrote BenchMarkResult.csv" >&2
else
    cat "$tmp_out"
fi
