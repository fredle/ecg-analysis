"""
ECG Processing Pipeline
=======================
Processes R-files from the import directory:
  1. Skips files that have already been processed
  2. Decodes raw ECG and saves as Parquet (snappy compression)
  3. Classifies all beats (QRS / PAC / PVC) and saves as Parquet
  4. Generates a day-timeline HTML showing beat classifications with
     gaps where no recording exists.

Output layout:
  processed/
    {filename}_raw.parquet    - raw ECG samples (sample_idx, value, timestamp_ms)
    {filename}_beats.parquet  - per-beat classifications
  ecg_timeline.html           - interactive day-view chart
"""

import os
import sys
import json
import struct
import re
import math
import numpy as np
from datetime import datetime, timedelta

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
IMPORT_DIR = os.path.join(BASE_DIR, "import")
PROCESSED_DIR = os.path.join(BASE_DIR, "processed")
MODEL_PATH = os.path.join(BASE_DIR, "models", "beat-3-eff-sm", "model.keras")
TIMELINE_HTML = os.path.join(BASE_DIR, "ecg_timeline.html")

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
ORIG_SAMPLE_RATE = 125    # Hz — device native rate
MODEL_SAMPLE_RATE = 100   # Hz — heartkit model expected rate
FRAME_SIZE = 512          # samples at 100 Hz (~5.12 s)
CONFIDENCE_THRESHOLD = 0.5
CLASS_NAMES = ["QRS", "PAC", "PVC"]
GAP_THRESHOLD_SEC = 10    # seconds between recordings to show as gap in chart


# ---------------------------------------------------------------------------
# R-file decoder
# ---------------------------------------------------------------------------
def decode_ecg_r_file(filepath):
    with open(filepath, "rb") as f:
        file_data = f.read()

    if len(file_data) < 12:
        raise ValueError(f"File too small: {filepath}")

    header_size = file_data[8]
    if header_size != 9:
        raise ValueError(f"Unexpected header size: {header_size}")

    data = file_data[9:]
    samples = []
    acc = 0
    i = 1  # skip padding byte

    while i < len(data):
        b = data[i]
        if b == 0x80:
            if i + 2 < len(data):
                acc = struct.unpack_from('<h', data, i + 1)[0]
                samples.append(acc)
                i += 3
            else:
                break
        elif b == 0x7F:
            if i + 1 < len(data):
                acc += 127 + data[i + 1]
                samples.append(acc)
                i += 2
            else:
                break
        elif b == 0x81:
            if i + 1 < len(data):
                acc -= 127 + data[i + 1]
                samples.append(acc)
                i += 2
            else:
                break
        else:
            delta = b - 256 if b > 127 else b
            acc += delta
            samples.append(acc)
            i += 1

    return samples


def parse_timestamp_from_filename(filepath):
    basename = os.path.basename(filepath)
    match = re.search(r'R(\d{14})$', basename)
    if not match:
        raise ValueError(f"Cannot extract timestamp from: {basename}")
    return datetime.strptime(match.group(1), "%Y%m%d%H%M%S")


def find_r_files(directory):
    r_files = []
    for entry in os.listdir(directory):
        full_path = os.path.join(directory, entry)
        if os.path.isfile(full_path) and re.search(r'R\d{14}$', entry):
            r_files.append(full_path)
    return sorted(r_files)


# ---------------------------------------------------------------------------
# Signal processing
# ---------------------------------------------------------------------------
def resample_125_to_100(signal_125):
    from scipy.signal import resample_poly
    return resample_poly(signal_125, up=4, down=5).astype(np.float32)


def layer_norm(x, epsilon=0.01):
    mean = np.mean(x)
    std = np.std(x)
    return (x - mean) / (std + epsilon)


# ---------------------------------------------------------------------------
# Beat classification
# ---------------------------------------------------------------------------
def classify_beats(ecg_100hz, peaks, model, batch_size=256):
    n_peaks = len(peaks)
    beat_classes = np.full(n_peaks, -1, dtype=np.int32)
    beat_probs = np.zeros(n_peaks, dtype=np.float32)

    half_frame = FRAME_SIZE // 2

    valid_indices = []
    windows = []
    for i in range(n_peaks):
        start = peaks[i] - half_frame
        stop = start + FRAME_SIZE
        if start < 0 or stop > len(ecg_100hz):
            continue
        window = layer_norm(ecg_100hz[start:stop].copy())
        windows.append(window)
        valid_indices.append(i)

    if not windows:
        return beat_classes, beat_probs

    X = np.array(windows, dtype=np.float32).reshape(-1, FRAME_SIZE, 1)
    print(f"    Batched inference on {len(X)} windows...", flush=True)
    logits = model.predict(X, batch_size=batch_size, verbose=1)

    from scipy.special import softmax as scipy_softmax
    probs = scipy_softmax(logits, axis=-1)
    pred_classes = np.argmax(probs, axis=-1)
    pred_probs = np.max(probs, axis=-1)

    for idx, vi in enumerate(valid_indices):
        if pred_probs[idx] >= CONFIDENCE_THRESHOLD:
            beat_classes[vi] = int(pred_classes[idx])
        else:
            beat_classes[vi] = 0  # default to normal if below threshold
        beat_probs[vi] = float(pred_probs[idx])

    return beat_classes, beat_probs


# ---------------------------------------------------------------------------
# Parquet I/O
# ---------------------------------------------------------------------------
def save_raw_parquet(samples, start_time, out_path):
    import pyarrow as pa
    import pyarrow.parquet as pq

    n = len(samples)
    # Build timestamps in milliseconds since epoch for compactness
    epoch = datetime(1970, 1, 1)
    start_ms = int((start_time - epoch).total_seconds() * 1000)
    interval_ms = int(1000 / ORIG_SAMPLE_RATE)  # 8 ms

    sample_idx = np.arange(n, dtype=np.int32)
    values = np.array(samples, dtype=np.int16)
    timestamps_ms = np.array(
        [start_ms + i * interval_ms for i in range(n)], dtype=np.int64
    )

    table = pa.table(
        {
            "sample_idx": pa.array(sample_idx, type=pa.int32()),
            "value": pa.array(values, type=pa.int16()),
            "timestamp_ms": pa.array(timestamps_ms, type=pa.int64()),
        },
        metadata={
            "start_time": start_time.isoformat(),
            "sample_rate_hz": str(ORIG_SAMPLE_RATE),
            "units": "ADC counts (16-bit signed)",
        },
    )
    pq.write_table(table, out_path, compression="snappy")
    size_kb = os.path.getsize(out_path) / 1024
    print(f"    Raw parquet saved: {os.path.basename(out_path)} ({size_kb:.0f} KB)")


def save_beats_parquet(peaks_100hz, beat_classes, beat_probs, start_time, out_path):
    import pyarrow as pa
    import pyarrow.parquet as pq

    # Convert 100 Hz peak indices to timestamps
    epoch = datetime(1970, 1, 1)
    timestamps_ms = np.array(
        [int((start_time - epoch).total_seconds() * 1000 + p * 10)  # 10ms per sample @100Hz
         for p in peaks_100hz],
        dtype=np.int64,
    )

    class_names_arr = np.array(
        [CLASS_NAMES[c] if 0 <= c < len(CLASS_NAMES) else "UNK" for c in beat_classes],
        dtype=object,
    )

    table = pa.table(
        {
            "timestamp_ms": pa.array(timestamps_ms, type=pa.int64()),
            "sample_100hz": pa.array(peaks_100hz, type=pa.int32()),
            "beat_class": pa.array(beat_classes.astype(np.int8), type=pa.int8()),
            "beat_class_name": pa.array(class_names_arr, type=pa.string()),
            "probability": pa.array(beat_probs, type=pa.float32()),
        },
        metadata={
            "start_time": start_time.isoformat(),
            "sample_rate_hz": str(MODEL_SAMPLE_RATE),
            "class_map": "0=QRS, 1=PAC, 2=PVC, -1=unclassified",
        },
    )
    pq.write_table(table, out_path, compression="snappy")
    size_kb = os.path.getsize(out_path) / 1024
    print(f"    Beats parquet saved: {os.path.basename(out_path)} ({size_kb:.0f} KB, {len(peaks_100hz):,} beats)")


# ---------------------------------------------------------------------------
# Per-minute summary for chart
# ---------------------------------------------------------------------------
def build_minute_summary(beats_data_list):
    """
    beats_data_list: list of dicts with keys:
        start_time, end_time, timestamps_ms, beat_classes

    Returns a list of per-minute dicts for the chart, with None gaps between
    recordings that are more than GAP_THRESHOLD_SEC apart.
    """
    if not beats_data_list:
        return []

    # Find overall day range
    day_start = min(d["start_time"] for d in beats_data_list)
    day_end = max(d["end_time"] for d in beats_data_list)
    day_date = day_start.replace(hour=0, minute=0, second=0, microsecond=0)

    # Build per-minute buckets across the whole day
    total_minutes = int(math.ceil((day_end - day_date).total_seconds() / 60)) + 1

    epoch = datetime(1970, 1, 1)

    # Map each beat to its minute bucket
    minute_counts = {}  # minute_idx -> {"QRS": n, "PAC": n, "PVC": n, "UNK": n}

    day_start_ms = int((day_date - epoch).total_seconds() * 1000)
    for rec in beats_data_list:

        for ts_ms, cls in zip(rec["timestamps_ms"], rec["beat_classes"]):
            minute_idx = int((ts_ms - day_start_ms) / 60000)
            if minute_idx < 0:
                continue
            bucket = minute_counts.setdefault(minute_idx, {"QRS": 0, "PAC": 0, "PVC": 0, "UNK": 0})
            if cls == 0:
                bucket["QRS"] += 1
            elif cls == 1:
                bucket["PAC"] += 1
            elif cls == 2:
                bucket["PVC"] += 1
            else:
                bucket["UNK"] += 1

    # Build recording coverage intervals (in minutes from day start)
    coverage = []
    for rec in beats_data_list:
        start_min = int((rec["start_time"] - day_date).total_seconds() / 60)
        end_min = int(math.ceil((rec["end_time"] - day_date).total_seconds() / 60))
        coverage.append((start_min, end_min))
    coverage.sort()

    # Merge overlapping coverage
    merged = []
    for s, e in coverage:
        if merged and s <= merged[-1][1] + GAP_THRESHOLD_SEC // 60:
            merged[-1] = (merged[-1][0], max(merged[-1][1], e))
        else:
            merged.append([s, e])

    # Build chart rows — only emit minutes within coverage
    rows = []
    for seg_start, seg_end in merged:
        for m in range(seg_start, seg_end + 1):
            bucket = minute_counts.get(m, {"QRS": 0, "PAC": 0, "PVC": 0, "UNK": 0})
            minute_dt = day_date + timedelta(minutes=m)
            rows.append({
                "time": minute_dt.strftime("%H:%M"),
                "timestamp_ms": int((minute_dt - epoch).total_seconds() * 1000),
                "QRS": bucket["QRS"],
                "PAC": bucket["PAC"],
                "PVC": bucket["PVC"],
                "UNK": bucket["UNK"],
            })
        # Add null sentinel to create gap (unless last segment)
        if seg_end != merged[-1][1]:
            rows.append(None)

    return rows, day_start, day_end


# ---------------------------------------------------------------------------
# HTML generation
# ---------------------------------------------------------------------------
def generate_timeline_html(all_records, out_path):
    """Generate a standalone HTML file with a beat-classification timeline."""

    # Build chart data
    beats_data_list = []
    for rec in all_records:
        beats_data_list.append({
            "start_time": rec["start_time"],
            "end_time": rec["end_time"],
            "timestamps_ms": rec["timestamps_ms"],
            "beat_classes": rec["beat_classes"],
        })

    result = build_minute_summary(beats_data_list)
    if not result:
        print("  No data to chart.")
        return
    rows, day_start, day_end = result

    # Overall stats
    total_beats = sum(r["QRS"] + r["PAC"] + r["PVC"] + r["UNK"]
                      for r in rows if r is not None)
    total_qrs = sum(r["QRS"] for r in rows if r is not None)
    total_pac = sum(r["PAC"] for r in rows if r is not None)
    total_pvc = sum(r["PVC"] for r in rows if r is not None)
    pvc_pct = round(100 * total_pvc / total_beats, 1) if total_beats else 0
    pac_pct = round(100 * total_pac / total_beats, 1) if total_beats else 0
    recording_hours = sum(
        (rec["end_time"] - rec["start_time"]).total_seconds() / 3600
        for rec in beats_data_list
    )

    rows_json = json.dumps(rows)

    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ECG Beat Classification Timeline</title>
<style>
  :root {{
    --bg: #0f1117;
    --surface: #1a1d27;
    --border: #2a2d3a;
    --text: #e0e0e8;
    --text-dim: #8888a0;
    --accent: #6c8cff;
    --col-qrs: #44dd88;
    --col-pac: #ffaa33;
    --col-pvc: #ff4d6a;
    --col-unk: #555570;
    --col-gap: transparent;
  }}
  * {{ box-sizing: border-box; margin: 0; padding: 0; }}
  body {{
    font-family: 'Segoe UI', system-ui, sans-serif;
    background: var(--bg);
    color: var(--text);
    padding: 24px;
    min-height: 100vh;
  }}
  h1 {{ font-size: 22px; font-weight: 600; margin-bottom: 4px; }}
  .subtitle {{ color: var(--text-dim); font-size: 13px; margin-bottom: 20px; }}
  .stats-row {{
    display: flex; gap: 12px; margin-bottom: 20px; flex-wrap: wrap;
  }}
  .stat {{
    background: var(--surface); border: 1px solid var(--border);
    border-radius: 8px; padding: 12px 18px; flex: 1; min-width: 130px;
  }}
  .stat .label {{ font-size: 11px; color: var(--text-dim); text-transform: uppercase; letter-spacing: .5px; margin-bottom: 4px; }}
  .stat .value {{ font-size: 24px; font-weight: 700; }}
  .stat.qrs .value {{ color: var(--col-qrs); }}
  .stat.pac .value {{ color: var(--col-pac); }}
  .stat.pvc .value {{ color: var(--col-pvc); }}
  .stat.accent .value {{ color: var(--accent); }}
  .stat .unit {{ font-size: 13px; color: var(--text-dim); font-weight: 400; }}

  .chart-card {{
    background: var(--surface); border: 1px solid var(--border);
    border-radius: 10px; padding: 20px; margin-bottom: 20px;
  }}
  .chart-title {{ font-size: 14px; font-weight: 600; margin-bottom: 4px; }}
  .chart-sub {{ font-size: 12px; color: var(--text-dim); margin-bottom: 14px; }}
  canvas {{ display: block; width: 100%; }}

  .legend {{
    display: flex; gap: 18px; margin-top: 10px; flex-wrap: wrap;
  }}
  .legend-item {{ display: flex; align-items: center; gap: 6px; font-size: 12px; color: var(--text-dim); }}
  .legend-dot {{ width: 10px; height: 10px; border-radius: 2px; flex-shrink: 0; }}
  .dot-qrs {{ background: var(--col-qrs); }}
  .dot-pac {{ background: var(--col-pac); }}
  .dot-pvc {{ background: var(--col-pvc); }}
  .dot-gap {{ background: var(--border); border: 1px dashed var(--text-dim); }}

  .recordings-table {{
    background: var(--surface); border: 1px solid var(--border);
    border-radius: 10px; padding: 20px;
  }}
  table {{ width: 100%; border-collapse: collapse; font-size: 13px; }}
  th {{
    text-align: left; color: var(--text-dim); font-size: 11px;
    text-transform: uppercase; letter-spacing: .5px;
    border-bottom: 1px solid var(--border); padding: 6px 10px;
  }}
  td {{ padding: 8px 10px; border-bottom: 1px solid #1e2130; }}
  tr:last-child td {{ border-bottom: none; }}
  .pill {{
    display: inline-block; border-radius: 4px; padding: 1px 7px;
    font-size: 11px; font-weight: 600;
  }}
  .pill-pvc {{ background: #3a1020; color: var(--col-pvc); }}
  .pill-pac {{ background: #2a1e0a; color: var(--col-pac); }}
</style>
</head>
<body>
<h1>ECG Beat Classification Timeline</h1>
<div class="subtitle">
  {day_start.strftime('%A, %d %B %Y').replace(' 0', ' ')} &mdash;
  {len(all_records)} recording(s) &nbsp;|&nbsp;
  {recording_hours:.1f} h recorded &nbsp;|&nbsp;
  Generated {datetime.now().strftime('%Y-%m-%d %H:%M')}
</div>

<div class="stats-row">
  <div class="stat accent">
    <div class="label">Total beats</div>
    <div class="value">{total_beats:,}</div>
  </div>
  <div class="stat qrs">
    <div class="label">Normal QRS</div>
    <div class="value">{total_qrs:,}</div>
  </div>
  <div class="stat pac">
    <div class="label">PAC <span class="unit">{pac_pct}%</span></div>
    <div class="value">{total_pac:,}</div>
  </div>
  <div class="stat pvc">
    <div class="label">PVC <span class="unit">{pvc_pct}%</span></div>
    <div class="value">{total_pvc:,}</div>
  </div>
</div>

<div class="chart-card">
  <div class="chart-title">Beat Classification — Per Minute</div>
  <div class="chart-sub">Stacked beat counts. White spaces = no recording.</div>
  <canvas id="mainChart" height="220"></canvas>
  <div class="legend">
    <div class="legend-item"><div class="legend-dot dot-qrs"></div> Normal QRS</div>
    <div class="legend-item"><div class="legend-dot dot-pac"></div> PAC</div>
    <div class="legend-item"><div class="legend-dot dot-pvc"></div> PVC</div>
    <div class="legend-item"><div class="legend-dot dot-gap"></div> No recording</div>
  </div>
</div>

<div class="chart-card">
  <div class="chart-title">Ectopic Burden — Per Minute</div>
  <div class="chart-sub">Percentage of beats that are PAC or PVC each minute.</div>
  <canvas id="burdenChart" height="160"></canvas>
</div>

<div class="recordings-table">
  <div class="chart-title" style="margin-bottom:12px">Recordings</div>
  <table>
    <thead>
      <tr>
        <th>File</th><th>Start</th><th>End</th><th>Duration</th>
        <th>Total</th><th>QRS</th><th>PAC</th><th>PVC</th><th>PVC%</th>
      </tr>
    </thead>
    <tbody>
      {''.join(_rec_row(r) for r in all_records)}
    </tbody>
  </table>
</div>

<script>
const rows = {rows_json};

// ── helpers ──────────────────────────────────────────────────────────────────
function drawChart(canvasId, drawFn) {{
  const canvas = document.getElementById(canvasId);
  const dpr = window.devicePixelRatio || 1;
  const rect = canvas.getBoundingClientRect();
  canvas.width = rect.width * dpr;
  canvas.height = canvas.height * dpr;
  const ctx = canvas.getContext('2d');
  ctx.scale(dpr, dpr);
  drawFn(ctx, rect.width, parseInt(canvas.height / dpr));
}}

// ── main stacked bar chart ───────────────────────────────────────────────────
function drawMain(ctx, W, H) {{
  const PAD_L = 48, PAD_R = 10, PAD_T = 8, PAD_B = 24;
  const cW = W - PAD_L - PAD_R;
  const cH = H - PAD_T - PAD_B;

  // background
  ctx.fillStyle = '#1a1d27';
  ctx.fillRect(0, 0, W, H);

  const segments = [];
  let seg = [];
  for (const r of rows) {{
    if (r === null) {{ if (seg.length) segments.push(seg); seg = []; }}
    else seg.push(r);
  }}
  if (seg.length) segments.push(seg);

  const allRows = rows.filter(r => r !== null);
  const maxTotal = Math.max(...allRows.map(r => r.QRS + r.PAC + r.PVC + r.UNK), 1);
  const totalBars = allRows.length;
  if (totalBars === 0) return;

  const barW = Math.max(1, cW / totalBars);

  // grid lines
  ctx.strokeStyle = '#2a2d3a';
  ctx.lineWidth = 1;
  for (let g = 0; g <= 4; g++) {{
    const y = PAD_T + cH * (1 - g / 4);
    ctx.beginPath(); ctx.moveTo(PAD_L, y); ctx.lineTo(PAD_L + cW, y); ctx.stroke();
    ctx.fillStyle = '#8888a0';
    ctx.font = '10px system-ui';
    ctx.textAlign = 'right';
    ctx.fillText(Math.round(maxTotal * g / 4), PAD_L - 4, y + 3);
  }}

  // bars
  let xOffset = 0;
  for (const seg of segments) {{
    for (const r of seg) {{
      const x = PAD_L + xOffset * barW;
      const total = r.QRS + r.PAC + r.PVC + r.UNK;
      let y = PAD_T + cH;
      const layers = [
        [r.QRS, '#44dd88'],
        [r.PAC, '#ffaa33'],
        [r.PVC, '#ff4d6a'],
        [r.UNK, '#555570'],
      ];
      for (const [count, color] of layers) {{
        if (count === 0) continue;
        const h = (count / maxTotal) * cH;
        y -= h;
        ctx.fillStyle = color;
        ctx.fillRect(x, y, barW - 0.5, h);
      }}
      xOffset++;
    }}
    // gap — leave space
    xOffset += Math.max(1, totalBars * 0.01);
  }}

  // time axis labels
  ctx.fillStyle = '#8888a0';
  ctx.font = '10px system-ui';
  ctx.textAlign = 'center';
  // label every 30 rows (~30 min)
  let absIdx = 0;
  for (const seg of segments) {{
    for (let i = 0; i < seg.length; i++) {{
      if (i % 30 === 0 || i === seg.length - 1) {{
        const x = PAD_L + (absIdx + i) * barW + barW / 2;
        ctx.fillText(seg[i].time, x, H - 4);
      }}
    }}
    absIdx += seg.length + Math.max(1, totalBars * 0.01);
  }}
}}

// ── burden chart ─────────────────────────────────────────────────────────────
function drawBurden(ctx, W, H) {{
  const PAD_L = 48, PAD_R = 10, PAD_T = 8, PAD_B = 24;
  const cW = W - PAD_L - PAD_R;
  const cH = H - PAD_T - PAD_B;

  ctx.fillStyle = '#1a1d27';
  ctx.fillRect(0, 0, W, H);

  const segments = [];
  let seg = [];
  for (const r of rows) {{
    if (r === null) {{ if (seg.length) segments.push(seg); seg = []; }}
    else seg.push(r);
  }}
  if (seg.length) segments.push(seg);

  const allRows = rows.filter(r => r !== null);
  const totalBars = allRows.length;
  if (totalBars === 0) return;
  const barW = Math.max(1, cW / totalBars);

  // grid
  ctx.strokeStyle = '#2a2d3a';
  ctx.lineWidth = 1;
  for (let g = 0; g <= 4; g++) {{
    const y = PAD_T + cH * (1 - g / 4);
    ctx.beginPath(); ctx.moveTo(PAD_L, y); ctx.lineTo(PAD_L + cW, y); ctx.stroke();
    ctx.fillStyle = '#8888a0';
    ctx.font = '10px system-ui';
    ctx.textAlign = 'right';
    ctx.fillText((g * 25) + '%', PAD_L - 4, y + 3);
  }}

  // burden bars
  let xOffset = 0;
  for (const seg of segments) {{
    for (const r of seg) {{
      const total = r.QRS + r.PAC + r.PVC + r.UNK;
      if (total === 0) {{ xOffset++; continue; }}
      const burden = (r.PAC + r.PVC) / total;
      const x = PAD_L + xOffset * barW;
      const h = burden * cH;
      const color = burden > 0.2 ? '#ff4d6a' : burden > 0.05 ? '#ffaa33' : '#6c8cff';
      ctx.fillStyle = color;
      ctx.fillRect(x, PAD_T + cH - h, barW - 0.5, h);
      xOffset++;
    }}
    xOffset += Math.max(1, totalBars * 0.01);
  }}

  // time labels
  ctx.fillStyle = '#8888a0';
  ctx.font = '10px system-ui';
  ctx.textAlign = 'center';
  let absIdx = 0;
  for (const seg of segments) {{
    for (let i = 0; i < seg.length; i++) {{
      if (i % 30 === 0 || i === seg.length - 1) {{
        const x = PAD_L + (absIdx + i) * barW + barW / 2;
        ctx.fillText(seg[i].time, x, H - 4);
      }}
    }}
    absIdx += seg.length + Math.max(1, totalBars * 0.01);
  }}
}}

// draw on load and on resize
function render() {{
  drawChart('mainChart', drawMain);
  drawChart('burdenChart', drawBurden);
}}
render();
window.addEventListener('resize', () => {{ setTimeout(render, 100); }});
</script>
</body>
</html>"""

    with open(out_path, "w", encoding="utf-8") as f:
        f.write(html)
    print(f"  Timeline HTML saved: {out_path}")


def _rec_row(rec):
    total = rec["n_qrs"] + rec["n_pac"] + rec["n_pvc"]
    pvc_pct = round(100 * rec["n_pvc"] / total, 1) if total else 0
    pac_pct = round(100 * rec["n_pac"] / total, 1) if total else 0
    dur_h = (rec["end_time"] - rec["start_time"]).total_seconds() / 3600
    return (
        f'<tr>'
        f'<td>{rec["filename"]}</td>'
        f'<td>{rec["start_time"].strftime("%H:%M:%S")}</td>'
        f'<td>{rec["end_time"].strftime("%H:%M:%S")}</td>'
        f'<td>{dur_h:.2f} h</td>'
        f'<td>{total:,}</td>'
        f'<td style="color:#44dd88">{rec["n_qrs"]:,}</td>'
        f'<td><span class="pill pill-pac">{rec["n_pac"]:,}</span> {pac_pct}%</td>'
        f'<td><span class="pill pill-pvc">{rec["n_pvc"]:,}</span> {pvc_pct}%</td>'
        f'<td style="color:#ff4d6a">{pvc_pct}%</td>'
        f'</tr>'
    )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    os.makedirs(PROCESSED_DIR, exist_ok=True)
    os.environ["TF_CPP_MIN_LOG_LEVEL"] = "2"

    print("=" * 60)
    print("ECG Processing Pipeline")
    print("=" * 60)

    # Find R-files
    if not os.path.isdir(IMPORT_DIR):
        print(f"Import directory not found: {IMPORT_DIR}")
        sys.exit(1)

    r_files = find_r_files(IMPORT_DIR)
    if not r_files:
        print("No R-files found in import directory.")
        sys.exit(0)

    print(f"Found {len(r_files)} R-file(s) in {IMPORT_DIR}")

    # Determine which files need processing
    to_process = []
    for fp in r_files:
        name = os.path.basename(fp)
        raw_out = os.path.join(PROCESSED_DIR, f"{name}_raw.parquet")
        beats_out = os.path.join(PROCESSED_DIR, f"{name}_beats.parquet")
        if os.path.exists(raw_out) and os.path.exists(beats_out):
            print(f"  SKIP (already processed): {name}")
        else:
            to_process.append(fp)

    if not to_process:
        print("\nAll files already processed.")
    else:
        print(f"\nFiles to process: {len(to_process)}")

        # Load model once
        print(f"\nLoading model: {MODEL_PATH}")
        import keras
        import physiokit as pk
        model = keras.models.load_model(MODEL_PATH)
        print(f"  Model loaded: input={model.input_shape}, output={model.output_shape}")

        for filepath in to_process:
            name = os.path.basename(filepath)
            raw_out = os.path.join(PROCESSED_DIR, f"{name}_raw.parquet")
            beats_out = os.path.join(PROCESSED_DIR, f"{name}_beats.parquet")

            print(f"\n{'─' * 60}")
            print(f"Processing: {name}  ({os.path.getsize(filepath):,} bytes)")

            # 1. Decode
            print("  Decoding...")
            raw_samples = decode_ecg_r_file(filepath)
            start_time = parse_timestamp_from_filename(filepath)
            duration_sec = len(raw_samples) / ORIG_SAMPLE_RATE
            end_time = start_time + timedelta(seconds=duration_sec)
            print(f"  {len(raw_samples):,} samples  |  {start_time} → {end_time}")

            # 2. Save raw parquet
            print("  Saving raw ECG parquet...")
            save_raw_parquet(raw_samples, start_time, raw_out)

            # 3. Resample + find peaks
            print("  Resampling 125→100 Hz and finding R-peaks...")
            ecg_125 = np.array(raw_samples, dtype=np.float32)
            ecg_100 = resample_125_to_100(ecg_125)
            ecg_clean = pk.ecg.clean(ecg_100, sample_rate=MODEL_SAMPLE_RATE)
            ecg_norm = pk.signal.normalize_signal(ecg_clean, eps=0.1, axis=None)
            peaks = np.array(pk.ecg.find_peaks(ecg_norm, sample_rate=MODEL_SAMPLE_RATE), dtype=np.int32)
            print(f"  {len(peaks):,} R-peaks  |  avg HR: {60 * len(peaks) / (len(ecg_100) / MODEL_SAMPLE_RATE):.0f} bpm")

            # 4. Classify beats
            print("  Classifying beats...")
            beat_classes, beat_probs = classify_beats(ecg_100, peaks, model)
            n_qrs = int(np.sum(beat_classes == 0))
            n_pac = int(np.sum(beat_classes == 1))
            n_pvc = int(np.sum(beat_classes == 2))
            n_unk = int(np.sum(beat_classes == -1))
            print(f"  QRS={n_qrs:,}  PAC={n_pac:,}  PVC={n_pvc:,}  UNK={n_unk}")

            # 5. Save beats parquet
            print("  Saving beats parquet...")
            save_beats_parquet(peaks, beat_classes, beat_probs, start_time, beats_out)

    # ── Generate timeline HTML from ALL processed parquet files ──────────────
    print(f"\n{'─' * 60}")
    print("Building timeline HTML from all processed data...")

    import pyarrow.parquet as pq

    all_records = []
    for fp in r_files:
        name = os.path.basename(fp)
        beats_out = os.path.join(PROCESSED_DIR, f"{name}_beats.parquet")
        if not os.path.exists(beats_out):
            continue

        table = pq.read_table(beats_out)
        meta = table.schema.metadata or {}
        start_str = meta.get(b"start_time", b"").decode()
        start_time = datetime.fromisoformat(start_str) if start_str else parse_timestamp_from_filename(fp)

        timestamps_ms = table.column("timestamp_ms").to_pylist()
        beat_classes_list = table.column("beat_class").to_pylist()

        n_qrs = sum(1 for c in beat_classes_list if c == 0)
        n_pac = sum(1 for c in beat_classes_list if c == 1)
        n_pvc = sum(1 for c in beat_classes_list if c == 2)
        total = len(beat_classes_list)
        duration_sec = total / 70  # approximate: avg 70 bpm

        # Better: use actual time span
        if timestamps_ms:
            actual_duration_ms = timestamps_ms[-1] - timestamps_ms[0]
            duration_sec = actual_duration_ms / 1000 + 1
        end_time = start_time + timedelta(seconds=duration_sec)

        all_records.append({
            "filename": name,
            "start_time": start_time,
            "end_time": end_time,
            "timestamps_ms": timestamps_ms,
            "beat_classes": beat_classes_list,
            "n_qrs": n_qrs,
            "n_pac": n_pac,
            "n_pvc": n_pvc,
        })

    all_records.sort(key=lambda r: r["start_time"])

    if all_records:
        generate_timeline_html(all_records, TIMELINE_HTML)
        print(f"\nDone. Open: {TIMELINE_HTML}")
    else:
        print("No processed beat data found — run processing first.")


if __name__ == "__main__":
    main()
