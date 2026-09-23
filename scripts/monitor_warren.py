#!/usr/bin/env python3
"""Continuously sample CPU/memory usage of Warren processes.

Samples the installed Warren app, its menu-bar daemon, and any
warren-headless processes every --interval seconds. Writes one CSV row
per process per sample and optionally refreshes an SVG usage chart so a
long-running background session can be inspected at any time.

Requires only the Python 3 standard library.
"""

from __future__ import annotations

import argparse
import csv
import re
import signal
import subprocess
import sys
import threading
import time
import xml.sax.saxutils as saxutils
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple


APP_MARKERS = ("/Warren.app/Contents/MacOS/",)
WARREN_BASENAMES = {"Warren", "WarrenDaemonMenuBar", "warren-headless", "warren-ghostline"}
TIME_RE = re.compile(r"^(\d+):(\d+(?:\.\d+)?)$")
PALETTE = [
    "#e74c3c",
    "#3498db",
    "#2ecc71",
    "#f39c12",
    "#9b59b6",
    "#1abc9c",
    "#e67e22",
    "#34495e",
    "#16a085",
    "#c0392b",
]


@dataclass
class ProcessSample:
    pid: int
    ppid: int
    rss_kb: int
    vsz_kb: int
    cum_cpu_s: float
    command: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Monitor Warren process CPU/memory usage over time."
    )
    parser.add_argument(
        "--interval",
        type=float,
        default=10.0,
        help="Sampling interval in seconds (default: 10.0)",
    )
    parser.add_argument(
        "--duration",
        type=float,
        default=0.0,
        help="Stop after this many seconds; 0 means run forever (default: 0)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path.home() / ".warren" / "usage" / "warren_usage.csv",
        help="CSV output path (default: ~/.warren/usage/warren_usage.csv)",
    )
    parser.add_argument(
        "--chart",
        type=Path,
        default=None,
        help="SVG chart output path; refreshes periodically while running",
    )
    parser.add_argument(
        "--chart-every",
        type=int,
        default=30,
        help="Refresh the SVG chart every N samples (default: 30)",
    )
    return parser.parse_args()


def run_ps() -> List[ProcessSample]:
    """Return one ProcessSample per process using macOS ps output."""
    proc = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,rss=,vsz=,time=,command="],
        check=True,
        capture_output=True,
        text=True,
    )
    samples: List[ProcessSample] = []
    for line in proc.stdout.splitlines():
        fields = line.split(maxsplit=5)
        if len(fields) < 5:
            continue
        try:
            pid = int(fields[0])
            ppid = int(fields[1])
            rss_kb = int(fields[2])
            vsz_kb = int(fields[3])
        except ValueError:
            continue
        time_s = parse_cum_time(fields[4])
        if time_s is None:
            continue
        command = fields[5] if len(fields) > 5 else ""
        samples.append(
            ProcessSample(
                pid=pid,
                ppid=ppid,
                rss_kb=rss_kb,
                vsz_kb=vsz_kb,
                cum_cpu_s=time_s,
                command=command,
            )
        )
    return samples


def parse_cum_time(value: str) -> Optional[float]:
    """Parse ps cumulative time (MM:SS[.cc]) into seconds."""
    match = TIME_RE.match(value.strip())
    if not match:
        return None
    minutes = int(match.group(1))
    seconds = float(match.group(2))
    return minutes * 60.0 + seconds


def is_warren_process(sample: ProcessSample) -> bool:
    if any(marker in sample.command for marker in APP_MARKERS):
        return True
    first_token = sample.command.split(maxsplit=1)[0]
    return Path(first_token).name in WARREN_BASENAMES


def process_label(sample: ProcessSample) -> str:
    name = Path(sample.command.split(maxsplit=1)[0]).name
    if "ghostline-serve" in sample.command or name == "warren-ghostline":
        return "warren-headless (ghostline)"
    return name


def nice_step(max_value: float) -> float:
    """Pick a round grid step near max_value / 4."""
    raw = max_value / 4.0
    magnitude = 10.0 ** max(0, int(raw // 10.0)) if raw > 0 else 1.0
    normalized = raw / magnitude
    for step in (1, 2, 5, 10):
        if normalized <= step:
            return step * magnitude
    return 10.0 * magnitude


def format_duration(seconds: float) -> str:
    seconds = int(seconds)
    minutes, secs = divmod(seconds, 60)
    return f"{minutes}:{secs:02d}"


def write_svg(
    path: Path,
    history: List[Dict],
) -> None:
    """Render CPU and RSS curves for the sampled history as an SVG."""
    if not history:
        return

    width, height = 1200, 760
    left, right, top, bottom = 70, 20, 50, 45
    cpu_panel_height = 300
    gap = 45
    rss_panel_height = height - top - bottom - cpu_panel_height - gap
    plot_width = width - left - right
    x_axis = lambda elapsed: left + (elapsed / max(1.0, history[-1]["elapsed"])) * plot_width

    total_cpu = max(s["total_cpu"] for s in history)
    total_rss = max(s["total_rss"] for s in history)
    cpu_max = max(20.0, total_cpu * 1.15)
    rss_max = max(20.0, total_rss * 1.15)

    # Series keys are stable (pid + display name); total is drawn separately.
    series: Dict[str, List[Tuple[float, float]]] = {}
    name_counts: Dict[str, int] = {}
    seen_names: set = set()
    for s in history:
        for entry in s["entries"]:
            identity = (entry["label"], entry["pid"])
            if identity not in seen_names:
                seen_names.add(identity)
                name_counts[entry["label"]] = name_counts.get(entry["label"], 0) + 1

    def series_key(entry: Dict) -> str:
        label = entry["label"]
        return f"{label}[{entry['pid']}]" if name_counts[label] > 1 else label

    for s in history:
        for entry in s["entries"]:
            series.setdefault(series_key(entry), []).append(
                (s["elapsed"], entry["cpu"])
            )

    def polyline(points: List[Tuple[float, float]], y_max: float, y_origin: float) -> str:
        coords = []
        for elapsed, value in points:
            x = x_axis(elapsed)
            y = y_origin - (value / y_max) * panel_height(y_origin)
            coords.append(f"{x:.1f},{y:.1f}")
        return " ".join(coords)

    def panel_height(y_origin: float) -> float:
        if y_origin == top + cpu_panel_height:
            return cpu_panel_height
        return rss_panel_height

    elements: List[str] = []
    elements.append(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}">'
    )
    elements.append(
        f'<rect x="0" y="0" width="{width}" height="{height}" fill="#ffffff"/>'
    )

    # CPU panel.
    cpu_origin = top + cpu_panel_height
    elements.append(f'<text x="{left}" y="{top - 14}" font-size="15" fill="#333">CPU % (per core, instantaneous)</text>')
    cpu_step = nice_step(cpu_max)
    cpu_value = 0.0
    while cpu_value <= cpu_max:
        y = cpu_origin - (cpu_value / cpu_max) * cpu_panel_height
        elements.append(f'<line x1="{left}" y1="{y:.1f}" x2="{width - right}" y2="{y:.1f}" stroke="#e5e5e5"/>')
        elements.append(f'<text x="{left - 8}" y="{y + 4:.1f}" font-size="11" fill="#888" text-anchor="end">{cpu_value:.0f}</text>')
        cpu_value += cpu_step

    # RSS panel.
    rss_origin = cpu_origin + gap + rss_panel_height
    elements.append(f'<text x="{left}" y="{cpu_origin + gap - 14}" font-size="15" fill="#333">RSS (MB)</text>')
    rss_step = nice_step(rss_max)
    rss_value = 0.0
    while rss_value <= rss_max:
        y = rss_origin - (rss_value / rss_max) * rss_panel_height
        elements.append(f'<line x1="{left}" y1="{y:.1f}" x2="{width - right}" y2="{y:.1f}" stroke="#e5e5e5"/>')
        elements.append(f'<text x="{left - 8}" y="{y + 4:.1f}" font-size="11" fill="#888" text-anchor="end">{rss_value:.0f}</text>')
        rss_value += rss_step

    # X axis ticks for the CPU panel (both panels share the same X range).
    last_elapsed = history[-1]["elapsed"]
    x_step = nice_step(last_elapsed) if last_elapsed > 0 else 1.0
    x_value = 0.0
    while x_value <= last_elapsed:
        x = x_axis(x_value)
        elements.append(f'<line x1="{x:.1f}" y1="{top}" x2="{x:.1f}" y2="{height - bottom}" stroke="#e5e5e5"/>')
        elements.append(f'<text x="{x:.1f}" y="{height - bottom + 18}" font-size="11" fill="#888" text-anchor="middle">{format_duration(x_value)}</text>')
        x_value += x_step

    # Total CPU line.
    total_points = [(s["elapsed"], s["total_cpu"]) for s in history]
    elements.append(
        f'<polyline points="{polyline(total_points, cpu_max, cpu_origin)}" fill="none" '
        f'stroke="#111111" stroke-width="2.5"/>'
    )

    # Per-process lines.
    for index, (key, points) in enumerate(series.items()):
        color = PALETTE[index % len(PALETTE)]
        elements.append(
            f'<polyline points="{polyline(points, cpu_max, cpu_origin)}" fill="none" '
            f'stroke="{color}" stroke-width="1.5" stroke-opacity="0.85"/>'
        )

    # RSS lines.
    total_rss_points = [(s["elapsed"], s["total_rss"]) for s in history]
    elements.append(
        f'<polyline points="{polyline(total_rss_points, rss_max, rss_origin)}" fill="none" '
        f'stroke="#111111" stroke-width="2.5"/>'
    )
    rss_series: Dict[str, List[Tuple[float, float]]] = {}
    for s in history:
        for entry in s["entries"]:
            rss_series.setdefault(series_key(entry), []).append(
                (s["elapsed"], entry["rss"])
            )
    for index, (key, points) in enumerate(rss_series.items()):
        color = PALETTE[index % len(PALETTE)]
        elements.append(
            f'<polyline points="{polyline(points, rss_max, rss_origin)}" fill="none" '
            f'stroke="{color}" stroke-width="1.5" stroke-opacity="0.85"/>'
        )

    # Legend.
    legend_x = width - right - 260
    legend_y = top + 2
    elements.append(
        f'<rect x="{legend_x - 8}" y="{legend_y - 16}" width="268" height="{18 + 18 * (len(series) + 1)}" '
        f'fill="#ffffff" fill-opacity="0.92" stroke="#dddddd"/>'
    )
    legend_entries = [("total", "#111111")]
    for index, key in enumerate(series):
        color = PALETTE[index % len(PALETTE)]
        last_cpu = series[key][-1][1]
        legend_entries.append((f"{key} {last_cpu:.1f}%", color))
    for row, (label, color) in enumerate(legend_entries):
        y = legend_y + row * 18
        elements.append(f'<rect x="{legend_x}" y="{y - 9}" width="10" height="10" fill="{color}"/>')
        elements.append(
            f'<text x="{legend_x + 16}" y="{y}" font-size="11" fill="#333">{saxutils.escape(label)}</text>'
        )

    elements.append("</svg>")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(elements), encoding="utf-8")


def main() -> int:
    args = parse_args()
    output: Path = args.output
    output.parent.mkdir(parents=True, exist_ok=True)

    stop = threading.Event()

    def handle_signal(_signum, _frame) -> None:
        stop.set()

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    history: List[Dict] = []
    prev_cpu: Dict[int, float] = {}
    start_wall = time.time()
    last_sample_mono: Optional[float] = None

    with output.open("w", newline="", encoding="utf-8") as csv_file:
        writer = csv.writer(csv_file)
        writer.writerow(
            ["timestamp", "iso_time", "pid", "process", "cpu_pct", "rss_mb", "cum_cpu_s"]
        )

        sample_index = 0
        while not stop.is_set():
            sample_start = time.monotonic()
            try:
                samples = [s for s in run_ps() if is_warren_process(s)]
            except subprocess.CalledProcessError as exc:
                print(f"ps failed: {exc}", file=sys.stderr)
                return 1

            now = time.time()
            elapsed = now - start_wall
            entries: List[Dict] = []
            total_cpu = 0.0
            total_rss = 0.0
            actual_interval = (
                sample_start - last_sample_mono
                if last_sample_mono is not None
                else args.interval
            )
            last_sample_mono = sample_start

            for sample in samples:
                previous = prev_cpu.get(sample.pid)
                if previous is None:
                    cpu_pct = 0.0
                else:
                    cpu_pct = max(0.0, (sample.cum_cpu_s - previous) / actual_interval * 100.0)
                prev_cpu[sample.pid] = sample.cum_cpu_s

                rss_mb = sample.rss_kb / 1024.0
                label = process_label(sample)
                entries.append(
                    {
                        "pid": sample.pid,
                        "label": label,
                        "cpu": cpu_pct,
                        "rss": rss_mb,
                    }
                )
                total_cpu += cpu_pct
                total_rss += rss_mb

                writer.writerow(
                    [
                        f"{now:.3f}",
                        time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now)),
                        sample.pid,
                        label,
                        f"{cpu_pct:.2f}",
                        f"{rss_mb:.1f}",
                        f"{sample.cum_cpu_s:.2f}",
                    ]
                )

            if not entries:
                writer.writerow(
                    [
                        f"{now:.3f}",
                        time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now)),
                        0,
                        "(none)",
                        "0.00",
                        "0.0",
                        "0.00",
                    ]
                )

            csv_file.flush()
            history.append(
                {
                    "elapsed": elapsed,
                    "entries": entries,
                    "total_cpu": total_cpu,
                    "total_rss": total_rss,
                }
            )
            sample_index += 1

            detail = " ".join(
                f"{e['label']}={e['cpu']:.1f}%" for e in entries
            )
            print(
                f"{time.strftime('%H:%M:%S', time.localtime(now))}  "
                f"cpu={total_cpu:6.1f}%  rss={total_rss:7.1f}MB  "
                f"n={len(entries)}  {detail}",
                flush=True,
            )

            if args.chart and sample_index % args.chart_every == 0:
                write_svg(args.chart, history)

            if args.duration > 0 and elapsed >= args.duration:
                break

            remaining = args.interval - (time.monotonic() - sample_start)
            if remaining > 0 and not stop.wait(remaining):
                continue

    if args.chart:
        write_svg(args.chart, history)

    if history:
        avg_cpu = sum(s["total_cpu"] for s in history) / len(history)
        max_cpu = max(s["total_cpu"] for s in history)
        avg_rss = sum(s["total_rss"] for s in history) / len(history)
        max_rss = max(s["total_rss"] for s in history)
        print(
            f"\nSummary: {len(history)} samples over {format_duration(history[-1]['elapsed'])}s; "
            f"avg total cpu={avg_cpu:.1f}%, max={max_cpu:.1f}%; "
            f"avg total rss={avg_rss:.1f}MB, max={max_rss:.1f}MB",
            flush=True,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
