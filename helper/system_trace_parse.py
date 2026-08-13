#!/usr/bin/env python3
"""Summarise xctrace System Trace thread-state exports into one CSV.

將 xctrace System Trace 的 thread-state 匯出彙整為單一 CSV。

Called by system_tracer.command; usable standalone for a bundle recorded by
hand. Reads every *.thread-state.xml in the given directory.
由 system_tracer.command 呼叫；亦可對手動錄製的 bundle 單獨使用。會讀取指定目錄
下所有 *.thread-state.xml。

xctrace interns repeated values: a value appears once with an id and later rows
reference it with ref. A parser that ignores refs sees mostly-empty rows, so the
id table is resolved here before anything is aggregated.
xctrace 會內插重複值：某個值只出現一次並帶 id，其後各列以 ref 參照它。忽略 ref
的解析器會看到大量空列，故此處先解析 id 表，再進行任何彙整。
"""

import csv
import glob
import os
import re
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict

# Column order in a thread-state row, per the schema xctrace emits. Missing
# values appear as <sentinel/>, so position is stable and can be trusted.
# thread-state 列的欄位順序，依 xctrace 所輸出的 schema。缺值以 <sentinel/> 呈現，
# 故位置固定且可信賴。
COLS = ["start", "thread", "state", "duration", "process", "core", "cputime",
        "waittime", "priority", "note", "summary", "made_runnable_by",
        "preempted_by", "yielded_to", "rebalanced_from", "thermal_throttled"]


def resolve(node, table):
    """Return an element, following a ref into the id table when needed.
    回傳元素；必要時循 ref 進入 id 表查找。"""
    if node is None or node.tag == "sentinel":
        return None
    ref = node.get("ref")
    if ref is not None:
        return table.get(ref)
    if node.get("id") is not None:
        table[node.get("id")] = node
    return node


def text_of(node):
    return node.get("fmt") or (node.text or "") if node is not None else ""


def parse_bundle(path, table):
    """Yield one dict per thread-state interval.
    對每個 thread-state 區間產出一個 dict。"""
    # Rows are deliberately not cleared after being read. Later rows reference
    # earlier elements by id, so clearing a row destroys values the rest of the
    # file still points at — the interning that makes the export compact also
    # makes streaming-with-cleanup wrong.
    # 讀取後刻意不清除列。後續各列會以 id 參照先前的元素，清除某一列會摧毀檔案其
    # 餘部分仍指向的值——使匯出檔精簡的內插機制，同時也讓「邊串流邊清理」失效。
    for _, row in ET.iterparse(path, events=("end",)):
        if row.tag != "row":
            continue
        rec = {}
        for name, cell in zip(COLS, list(row)):
            rec[name] = resolve(cell, table)
        yield rec


PROC_RE = re.compile(r"\(([^(),]+), pid:\s*(\d+)\)")


def process_name(process_label, thread_label):
    """Process name from either column. xctrace formats both as
    "Something (name, pid: N)", so one regex covers each.
    自任一欄位取得行程名稱。xctrace 對兩者皆格式化為
    「Something (name, pid: N)」，故單一 regex 即可涵蓋。"""
    for label in (process_label, thread_label):
        if not label:
            continue
        m = PROC_RE.search(label)
        if m:
            return f"{m.group(1)} ({m.group(2)})"
        if label.strip():
            return label.split(" (")[0]
    return "(unknown)"


def core_kind(core_node):
    """'P', 'E' or '' — the P/E split is why a thread count alone says little
    about throughput on Apple silicon.
    回傳 'P'、'E' 或 ''——P/E 之分正是「執行緒數」單憑本身難以說明 Apple silicon
    吞吐量的原因。"""
    label = text_of(core_node)
    if "P Core" in label:
        return "P"
    if "E Core" in label:
        return "E"
    return ""


def main():
    src_dir = sys.argv[1] if len(sys.argv) > 1 else "trace_system"
    out_csv = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
        src_dir, "summary_system_trace.csv")

    exports = sorted(glob.glob(os.path.join(src_dir, "*.thread-state.xml")))
    if not exports:
        sys.exit(f"no *.thread-state.xml in {src_dir} / 找不到匯出檔")

    rows = []
    for export in exports:
        bundle = os.path.basename(export).replace(".thread-state.xml", "")
        table = {}

        # per (process, state) -> nanoseconds; plus P/E running split
        totals = defaultdict(int)
        counts = defaultdict(int)
        core_ns = defaultdict(int)
        threads = defaultdict(set)
        throttled = defaultdict(int)

        for rec in parse_bundle(export, table):
            # The process column is frequently interned away, so fall back to the
            # thread label, which carries "(name, pid: N)". Grouping on the raw
            # thread label instead would split one process across every worker
            # thread and hide the thread count entirely.
            # process 欄位經常被內插省略，故退而使用執行緒標籤，其中帶有
            # 「(name, pid: N)」。若直接以原始執行緒標籤分組，會把單一行程拆散到
            # 每條 worker 執行緒上，反而看不出執行緒數量。
            proc = process_name(text_of(rec["process"]), text_of(rec["thread"]))
            state = text_of(rec["state"]) or "(none)"
            try:
                dur = int(rec["duration"].text) if rec["duration"] is not None else 0
            except (AttributeError, ValueError):
                dur = 0

            totals[(proc, state)] += dur
            counts[(proc, state)] += 1
            if rec["thread"] is not None:
                threads[proc].add(text_of(rec["thread"]))
            if state == "Running":
                kind = core_kind(rec["core"])
                if kind:
                    core_ns[(proc, kind)] += dur
            if text_of(rec["thermal_throttled"]).lower() in ("1", "true", "yes"):
                throttled[proc] += 1

        per_proc = defaultdict(int)
        for (proc, _state), ns in totals.items():
            per_proc[proc] += ns

        for (proc, state), ns in sorted(totals.items(), key=lambda kv: -kv[1]):
            total = per_proc[proc] or 1
            rows.append({
                "bundle": bundle,
                "process": proc,
                "state": state,
                "total_ms": f"{ns / 1e6:.3f}",
                "share_pct": f"{100 * ns / total:.2f}",
                "intervals": counts[(proc, state)],
                "threads": len(threads.get(proc, ())),
                "running_p_core_ms": f"{core_ns.get((proc, 'P'), 0) / 1e6:.3f}",
                "running_e_core_ms": f"{core_ns.get((proc, 'E'), 0) / 1e6:.3f}",
                "thermal_throttled_intervals": throttled.get(proc, 0),
            })

    with open(out_csv, "w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)

    print(f"[Done] {len(rows)} row(s) -> {out_csv}")

    # A short readout so the run is useful without opening the CSV. Only
    # processes with real time are shown; the trace captures the whole system.
    # 附上簡短輸出，使執行結果不必開啟 CSV 即可判讀。僅列出佔用實際時間的行程；
    # 此 trace 涵蓋的是整個系統。
    top = defaultdict(lambda: defaultdict(float))
    for r in rows:
        top[r["process"]][r["state"]] += float(r["total_ms"])
    ranked = sorted(top.items(), key=lambda kv: -sum(kv[1].values()))[:6]
    print()
    print(f"{'process':<26}{'Running':>11}{'Blocked':>11}{'Runnable':>11}{'P/E ms':>16}")
    print("-" * 75)
    for proc, states in ranked:
        pe = next((f"{r['running_p_core_ms']}/{r['running_e_core_ms']}"
                   for r in rows if r["process"] == proc), "")
        print(f"{proc[:25]:<26}{states.get('Running', 0):>11.1f}"
              f"{states.get('Blocked', 0):>11.1f}{states.get('Runnable', 0):>11.1f}{pe:>16}")


if __name__ == "__main__":
    main()
