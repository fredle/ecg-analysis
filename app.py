"""
ECG Analyser Web Application
============================
Flask web app that accepts ECG R-file uploads, decodes them,
runs beat classification with HeartKit BEAT-3-EFF-SM, detects
bigeminy episodes, and displays an interactive timeline report.
"""

import os
import re
import json
import uuid
import struct
import shutil
import logging
import threading
from datetime import datetime, timedelta, timezone

import numpy as np
import pandas as pd
import duckdb
from scipy.signal import resample_poly
from flask import (Flask, request, redirect, url_for, render_template,
                     flash, jsonify, Response, stream_with_context)

os.environ["TF_CPP_MIN_LOG_LEVEL"] = "3"

# ---------------------------------------------------------------------------
# App config
# ---------------------------------------------------------------------------
app = Flask(__name__)
app.secret_key = os.environ.get("SECRET_KEY", "ecg-bigeminy-analysis-key")

UPLOAD_FOLDER   = os.path.join(os.path.dirname(__file__), "uploads")
DATA_DIR        = os.path.join(os.path.dirname(__file__), "data")
RAW_DIR         = os.path.join(DATA_DIR, "raw")
ECG_PARQUET_DIR = os.path.join(DATA_DIR, "ecg_raw")
PARQUET_PATH = os.path.join(DATA_DIR, "bigeminy_episodes.parquet")
HOURLY_PARQUET_PATH = os.path.join(DATA_DIR, "hourly_hr.parquet")
MODEL_DIR = os.path.join(os.path.dirname(__file__), "models", "beat-3-eff-sm")
MODEL_PATH = os.path.join(MODEL_DIR, "model.keras")
UPLOAD_REGISTRY_PATH = os.path.join(DATA_DIR, "upload_registry.json")
ACTIVITIES_PARQUET_PATH = os.path.join(DATA_DIR, "activities.parquet")
EVENTS_PARQUET_PATH = os.path.join(DATA_DIR, "events.parquet")
INFERENCE_STATUS_PATH = os.path.join(DATA_DIR, "inference_status.json")

# In-memory inference status: {session_id: {status, error?, files}}
_inference_lock = threading.Lock()

def _load_inference_status() -> dict:
    if os.path.exists(INFERENCE_STATUS_PATH):
        try:
            with open(INFERENCE_STATUS_PATH, "r", encoding="utf-8") as fh:
                return json.load(fh)
        except Exception:
            pass
    return {}

def _save_inference_status(store: dict) -> None:
    with open(INFERENCE_STATUS_PATH, "w", encoding="utf-8") as fh:
        json.dump(store, fh, indent=2)

def _set_inference_status(session_id: str, status: str, error: str | None = None):
    with _inference_lock:
        store = _load_inference_status()
        entry = store.get(session_id, {})
        entry["status"] = status
        if error:
            entry["error"] = error
        elif "error" in entry:
            del entry["error"]
        store[session_id] = entry
        _save_inference_status(store)

def _get_inference_status(session_id: str) -> dict | None:
    with _inference_lock:
        store = _load_inference_status()
        return store.get(session_id)

os.makedirs(UPLOAD_FOLDER, exist_ok=True)
os.makedirs(RAW_DIR, exist_ok=True)
os.makedirs(ECG_PARQUET_DIR, exist_ok=True)


def _load_upload_registry() -> dict:
    """Return {filename: size_bytes} registry of previously uploaded files."""
    if os.path.exists(UPLOAD_REGISTRY_PATH):
        try:
            with open(UPLOAD_REGISTRY_PATH, "r", encoding="utf-8") as fh:
                return json.load(fh)
        except Exception:
            pass
    return {}


def _save_upload_registry(registry: dict) -> None:
    with open(UPLOAD_REGISTRY_PATH, "w", encoding="utf-8") as fh:
        json.dump(registry, fh, indent=2)

logging.basicConfig(level=logging.INFO, format="%(asctime)s  %(message)s")
log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
ORIG_SAMPLE_RATE = 125
MODEL_SAMPLE_RATE = 100
FRAME_SIZE = 512
CONFIDENCE_THRESHOLD = 0.5
MIN_BIGEMINY_BEATS = 6
MIN_TRIGEMINY_BEATS = 6   # ≥ 2 complete QRS-QRS-PVC triplets
MIN_VTACH_BEATS = 3       # ≥ 3 consecutive PVCs
CLASS_NAMES = ["QRS", "PAC", "PVC"]
RAW_CHUNK_SAMPLES = 1250   # 10 s @ 125 Hz per chunk
RAW_CHUNK_ROW_GROUP = 60   # 60 chunks = 10-minute row group

# ---------------------------------------------------------------------------
# Lazy model loading — loads in background so the server starts immediately
# ---------------------------------------------------------------------------
_model = None
_model_status = "loading"   # "loading" | "ready" | "error"
_model_error = None
_model_ready_event = threading.Event()


def _load_model_bg():
    global _model, _model_status, _model_error
    try:
        log.info("Loading HeartKit model from %s …", MODEL_PATH)
        import keras as _keras  # import here so TF initialisation is off the main thread
        _model = _keras.models.load_model(MODEL_PATH)
        log.info("Model ready: input=%s  output=%s", _model.input_shape, _model.output_shape)
        _model_status = "ready"
    except Exception as exc:
        log.error("Model load failed: %s", exc)
        _model_error = str(exc)
        _model_status = "error"
    finally:
        _model_ready_event.set()


threading.Thread(target=_load_model_bg, daemon=True).start()


def get_model(on_progress=None):
    """Return the loaded model, blocking until it becomes ready.

    If the model is still loading, wait for it rather than failing. A progress
    callback may be provided to surface a "waiting" message to the caller.
    """
    if _model_status == "loading":
        msg = "Model is still loading — waiting for it to become ready…"
        log.info(msg)
        if on_progress:
            on_progress(msg)
        _model_ready_event.wait()
    if _model_status == "ready":
        return _model
    raise RuntimeError(f"Model failed to load: {_model_error}")


def _migrate_parquet():
    """Add episode_type column to existing parquet if the column is missing."""
    if not os.path.isfile(PARQUET_PATH):
        return
    df = pd.read_parquet(PARQUET_PATH)
    if "episode_type" not in df.columns:
        df["episode_type"] = "bigeminy"
        df.to_parquet(PARQUET_PATH, index=False)
        log.info("Parquet migrated: added episode_type column")


_migrate_parquet()

# ---------------------------------------------------------------------------
# ECG decoder
# ---------------------------------------------------------------------------

def decode_ecg_r_file(filepath):
    with open(filepath, "rb") as f:
        file_data = f.read()

    if len(file_data) < 12:
        raise ValueError("File too small to be a valid R-file")

    header = file_data[:9]
    header_size = header[8]
    if header_size != 9:
        raise ValueError(f"Unexpected header size: {header_size}")

    data = file_data[9:]
    samples = []
    acc = 0
    i = 1

    while i < len(data):
        b = data[i]
        if b == 0x80:
            if i + 2 < len(data):
                acc = struct.unpack_from("<h", data, i + 1)[0]
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
    match = re.search(r"R(\d{14})$", basename)
    if not match:
        raise ValueError(f"Cannot extract timestamp from filename: {basename}")
    return datetime.strptime(match.group(1), "%Y%m%d%H%M%S")


# ---------------------------------------------------------------------------
# Signal processing
# ---------------------------------------------------------------------------

def resample_125_to_100(signal_125):
    return resample_poly(signal_125, up=4, down=5).astype(np.float32)


def layer_norm(x, epsilon=0.01):
    mean = np.mean(x)
    std = np.std(x)
    return (x - mean) / (std + epsilon)


# ---------------------------------------------------------------------------
# Beat classification (batched)
# ---------------------------------------------------------------------------

def classify_beats(ecg_100hz, peaks, mdl, batch_size=256, on_progress=None):
    from scipy.special import softmax as scipy_softmax

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
        window = ecg_100hz[start:stop].copy()
        window = layer_norm(window, epsilon=0.01)
        windows.append(window)
        valid_indices.append(i)

    if not windows:
        return beat_classes, beat_probs

    X = np.array(windows, dtype=np.float32).reshape(-1, FRAME_SIZE, 1)
    msg = f"  Running batched inference on {len(X)} windows …"
    log.info(msg)
    if on_progress:
        on_progress(msg)
    logits = mdl.predict(X, batch_size=batch_size, verbose=0)
    probs = scipy_softmax(logits, axis=-1)

    pred_classes = np.argmax(probs, axis=-1)
    pred_probs = np.max(probs, axis=-1)

    for idx, vi in enumerate(valid_indices):
        if pred_probs[idx] >= CONFIDENCE_THRESHOLD:
            beat_classes[vi] = int(pred_classes[idx])
        else:
            beat_classes[vi] = 0
        beat_probs[vi] = float(pred_probs[idx])

    return beat_classes, beat_probs


# ---------------------------------------------------------------------------
# Arrhythmia episode detection
# Detects: VTach, Bigeminy, Trigeminy, Couplet (in priority order)
# ---------------------------------------------------------------------------

def _make_episode(peaks, beat_classes, beat_probs, start_idx, end_idx, rec_start, ep_type):
    """Build an episode dict for a contiguous range of beat indices."""
    run_indices = range(start_idx, end_idx + 1)
    peak_start = peaks[start_idx]
    peak_end = peaks[end_idx]
    ts_start = rec_start + timedelta(seconds=peak_start / MODEL_SAMPLE_RATE)
    ts_end = rec_start + timedelta(seconds=peak_end / MODEL_SAMPLE_RATE)
    duration = (peak_end - peak_start) / MODEL_SAMPLE_RATE
    n_normal = sum(1 for idx in run_indices if beat_classes[idx] == 0)
    n_pvc = sum(1 for idx in run_indices if beat_classes[idx] == 2)
    avg_conf = float(np.mean([beat_probs[idx] for idx in run_indices]))
    return {
        "episode_type": ep_type,
        "start_time": ts_start.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3],
        "end_time": ts_end.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3],
        "duration_seconds": round(duration, 2),
        "total_beats": end_idx - start_idx + 1,
        "normal_beats": n_normal,
        "pvc_beats": n_pvc,
        "avg_confidence": round(avg_conf, 3),
        "start_sample_100hz": int(peak_start),
        "end_sample_100hz": int(peak_end),
    }


def detect_arrhythmia_episodes(peaks, beat_classes, beat_probs, start_time):
    """Detect bigeminy, trigeminy, couplets, and VTach episodes.

    Patterns are detected in priority order so they are not double-counted:
      VTach (≥3 consecutive PVCs) > Bigeminy (QRS-PVC alternating ≥6 beats)
      > Trigeminy (QRS-QRS-PVC repeating ≥6 beats) > Couplet (exactly 2 PVCs)
    """
    episodes = []
    n = len(beat_classes)
    i = 0

    while i < n:
        cls = beat_classes[i]

        # ── Consecutive PVCs → VTach or Couplet ────────────────────────────
        if cls == 2:
            j = i
            while j < n and beat_classes[j] == 2:
                j += 1
            run_len = j - i
            if run_len >= MIN_VTACH_BEATS:
                episodes.append(_make_episode(
                    peaks, beat_classes, beat_probs, i, j - 1, start_time, "vtach"))
                i = j
            elif run_len == 2:
                episodes.append(_make_episode(
                    peaks, beat_classes, beat_probs, i, i + 1, start_time, "couplet"))
                i = j
            else:
                i += 1  # single PVC

        # ── QRS followed by PVC → try Bigeminy first ───────────────────────
        elif cls == 0 and i + 1 < n and beat_classes[i + 1] == 2:
            j = i
            while j < n:
                expected = 0 if (j - i) % 2 == 0 else 2
                if beat_classes[j] == expected:
                    j += 1
                else:
                    break
            if j - i >= MIN_BIGEMINY_BEATS:
                episodes.append(_make_episode(
                    peaks, beat_classes, beat_probs, i, j - 1, start_time, "bigeminy"))
                i = j
            else:
                i += 1

        # ── QRS-QRS-PVC → try Trigeminy ────────────────────────────────────
        elif (cls == 0 and i + 2 < n
              and beat_classes[i + 1] == 0 and beat_classes[i + 2] == 2):
            j = i
            while (j + 2 < n
                   and beat_classes[j] == 0
                   and beat_classes[j + 1] == 0
                   and beat_classes[j + 2] == 2):
                j += 3
            if j - i >= MIN_TRIGEMINY_BEATS:
                episodes.append(_make_episode(
                    peaks, beat_classes, beat_probs, i, j - 1, start_time, "trigeminy"))
                i = j
            else:
                i += 1

        else:
            i += 1

    return episodes


# ---------------------------------------------------------------------------
# Hourly summary
# ---------------------------------------------------------------------------

BUCKET_SEC = 300  # 5-minute HR buckets


def _hr_from_rr(rr_sec: np.ndarray) -> float:
    """Estimate heart rate (BPM) from an array of RR intervals (seconds).

    The physiokit peak detector uses an adaptive gradient threshold whose
    baseline rises with QRS density, causing it to miss ~35% of beats at
    elevated heart rates.  This produces two clusters of RR intervals: the
    true RR and a 2×RR cluster from consecutive missed beats.

    Algorithm:
      1. Find the modal RR bin (40 ms resolution).
      2. If a significant cluster exists at modal/2 (i.e. the modal bin is
         the doubled RR), use the mean of that sub-harmonic cluster instead.
      3. Otherwise use the modal RR directly.

    This gives accurate results at both resting (~40 BPM) and exercise
    (~125 BPM) rates.
    """
    if len(rr_sec) < 2:
        return 0.0
    bins = np.arange(0.27, 2.01, 0.04)
    counts, edges = np.histogram(rr_sec, bins=bins)
    if counts.max() == 0:
        return 0.0
    modal_idx = int(np.argmax(counts))
    modal_rr = float((edges[modal_idx] + edges[modal_idx + 1]) / 2)
    # Check for sub-harmonic: the modal might be 2×RR when beats are missed
    half_rr = modal_rr / 2
    if half_rr >= 0.27:
        half_mask = (rr_sec >= half_rr * 0.85) & (rr_sec <= half_rr * 1.15)
        if np.sum(half_mask) >= 0.15 * len(rr_sec):
            modal_rr = float(np.mean(rr_sec[half_mask]))
    return round(60.0 / modal_rr, 1)


def compute_hourly_summary(peaks, beat_classes, start_time, total_duration_sec):
    n_buckets = int(np.ceil(total_duration_sec / BUCKET_SEC))
    summary = []

    # Build an extended peak list: include one peak either side of each bucket
    # boundary so median-RR spans the full bucket even when few peaks fall inside.
    for b in range(n_buckets):
        bucket_start_sec = b * BUCKET_SEC
        bucket_end_sec = min((b + 1) * BUCKET_SEC, total_duration_sec)
        bucket_start_sample = int(bucket_start_sec * MODEL_SAMPLE_RATE)
        bucket_end_sample = int(bucket_end_sec * MODEL_SAMPLE_RATE)

        mask = (peaks >= bucket_start_sample) & (peaks < bucket_end_sample)
        bucket_classes = beat_classes[mask]
        bucket_peaks = peaks[mask]

        n_total = int(np.sum(mask))
        n_normal = int(np.sum(bucket_classes == 0))
        n_pac = int(np.sum(bucket_classes == 1))
        n_pvc = int(np.sum(bucket_classes == 2))
        n_unclassified = int(np.sum(bucket_classes == -1))

        # ── Heart rate via median RR interval ─────────────────────────────
        # Extend window by one peak on each side to improve RR coverage at
        # bucket edges. Physiological RR filter: 0.27 s – 2.0 s (30–220 BPM).
        idx_in = np.where(mask)[0]
        extra_before = peaks[idx_in[0] - 1:idx_in[0]] if len(idx_in) > 0 and idx_in[0] > 0 else np.array([], dtype=np.int32)
        extra_after  = peaks[idx_in[-1] + 1:idx_in[-1] + 2] if len(idx_in) > 0 and idx_in[-1] + 1 < len(peaks) else np.array([], dtype=np.int32)
        extended_peaks = np.concatenate([extra_before, bucket_peaks, extra_after])

        if len(extended_peaks) >= 2:
            rr_samples = np.diff(extended_peaks)
            rr_sec = rr_samples / MODEL_SAMPLE_RATE
            valid = rr_sec[(rr_sec >= 0.27) & (rr_sec <= 2.0)]
            hr_bpm = _hr_from_rr(valid)
        else:
            hr_bpm = 0

        ts = start_time + timedelta(seconds=bucket_start_sec)

        summary.append({
            "hour": ts.strftime("%Y-%m-%d %H:%M"),
            "total_beats": n_total,
            "normal_beats": n_normal,
            "pac_beats": n_pac,
            "pvc_beats": n_pvc,
            "unclassified_beats": n_unclassified,
            "pvc_burden_pct": round(100 * n_pvc / n_total, 2) if n_total > 0 else 0,
            "hr_bpm": hr_bpm,
        })

    return summary


# ---------------------------------------------------------------------------
# Full pipeline for a list of R-files
# ---------------------------------------------------------------------------

def analyse_files(filepaths, on_progress=None):
    import physiokit as pk

    def emit(msg):
        log.info(msg)
        if on_progress:
            on_progress(msg)

    all_results = []

    for file_idx, filepath in enumerate(filepaths):
        basename = os.path.basename(filepath)
        emit(f"[{file_idx+1}/{len(filepaths)}] Processing: {basename}")

        raw_samples = decode_ecg_r_file(filepath)
        start_time = parse_timestamp_from_filename(filepath)
        emit(f"  Decoded {len(raw_samples):,} samples @ {ORIG_SAMPLE_RATE} Hz")

        save_raw_ecg_to_parquet(basename, raw_samples, start_time)
        emit(f"  Raw ECG saved to data/ecg_raw/ecg_raw_{start_time.strftime('%Y%m%d')}.parquet")

        ecg_125 = np.array(raw_samples, dtype=np.float32)
        ecg_100 = resample_125_to_100(ecg_125)
        duration_sec = len(ecg_100) / MODEL_SAMPLE_RATE
        emit(f"  Resampled to {len(ecg_100):,} samples @ {MODEL_SAMPLE_RATE} Hz ({duration_sec/3600:.2f} h)")

        emit("  Cleaning signal and detecting R-peaks…")
        ecg_clean = pk.ecg.clean(ecg_100, sample_rate=MODEL_SAMPLE_RATE)
        ecg_norm = pk.signal.normalize_signal(ecg_clean, eps=0.1, axis=None)
        peaks = pk.ecg.find_peaks(ecg_norm, sample_rate=MODEL_SAMPLE_RATE)
        peaks = np.array(peaks, dtype=np.int32)
        emit(f"  Found {len(peaks):,} R-peaks")

        if len(peaks) == 0:
            emit("  ⚠ No R-peaks found, skipping file.")
            continue

        emit("  Classifying beats…")
        model = get_model(on_progress=emit)
        beat_classes, beat_probs = classify_beats(ecg_100, peaks, model,
                                                  on_progress=on_progress)

        n_normal = int(np.sum(beat_classes == 0))
        n_pac = int(np.sum(beat_classes == 1))
        n_pvc = int(np.sum(beat_classes == 2))
        n_unk = int(np.sum(beat_classes == -1))
        emit(f"  Beats: QRS={n_normal:,}, PAC={n_pac:,}, PVC={n_pvc:,}, Unk={n_unk:,}")

        emit("  Detecting arrhythmia episodes…")
        episodes = detect_arrhythmia_episodes(peaks, beat_classes, beat_probs, start_time)
        by_type = {t: [e for e in episodes if e["episode_type"] == t]
                   for t in ("bigeminy", "trigeminy", "couplet", "vtach")}
        emit(f"  Episodes — bigeminy:{len(by_type['bigeminy'])}, "
             f"trigeminy:{len(by_type['trigeminy'])}, "
             f"couplet:{len(by_type['couplet'])}, "
             f"vtach:{len(by_type['vtach'])}")

        hourly = compute_hourly_summary(peaks, beat_classes, start_time, duration_sec)
        end_time = start_time + timedelta(seconds=duration_sec)

        file_result = {
            "file": basename,
            "start_time": start_time.strftime("%Y-%m-%d %H:%M:%S"),
            "end_time": end_time.strftime("%Y-%m-%d %H:%M:%S"),
            "duration_hours": round(duration_sec / 3600, 2),
            "sample_rate_original": ORIG_SAMPLE_RATE,
            "sample_rate_analysis": MODEL_SAMPLE_RATE,
            "total_beats": len(peaks),
            "beat_summary": {
                "normal_qrs": n_normal,
                "pac": n_pac,
                "pvc": n_pvc,
                "unclassified": n_unk,
                "pvc_burden_pct": round(100 * n_pvc / len(peaks), 2) if len(peaks) > 0 else 0,
            },
            "episodes": episodes,
            "episode_summary": {
                "total": len(episodes),
                "bigeminy": len(by_type["bigeminy"]),
                "trigeminy": len(by_type["trigeminy"]),
                "couplet": len(by_type["couplet"]),
                "vtach": len(by_type["vtach"]),
                "total_seconds": round(sum(e["duration_seconds"] for e in episodes), 2),
                "total_beats": sum(e["total_beats"] for e in episodes),
            },
            "hourly_summary": hourly,
        }
        all_results.append(file_result)

    emit("Building report…")

    total_pvc = sum(r["beat_summary"]["pvc"] for r in all_results)
    total_beats = sum(r["total_beats"] for r in all_results)
    all_episodes = [e for r in all_results for e in r["episodes"]]

    report = {
        "analysis": "ECG Arrhythmia Detection",
        "model": "HeartKit BEAT-3-EFF-SM (EfficientNetV2, 3-class)",
        "model_classes": CLASS_NAMES,
        "confidence_threshold": CONFIDENCE_THRESHOLD,
        "analysis_timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "recordings": all_results,
        "overall_summary": {
            "total_recordings": len(all_results),
            "total_beats_analysed": total_beats,
            "total_pvc": total_pvc,
            "overall_pvc_burden_pct": round(100 * total_pvc / total_beats, 2) if total_beats > 0 else 0,
            "total_episodes": len(all_episodes),
            "total_episode_seconds": round(sum(e["duration_seconds"] for e in all_episodes), 2),
            "episodes_by_type": {
                t: sum(1 for e in all_episodes if e["episode_type"] == t)
                for t in ("bigeminy", "trigeminy", "couplet", "vtach")
            },
        },
    }

    return report


# ---------------------------------------------------------------------------
# Parquet episode storage
# ---------------------------------------------------------------------------

def save_episodes_to_parquet(report):
    """Save bigeminy episodes to the persistent parquet file.

    Episodes from the time range of each recording in *report* are replaced
    (i.e. any previously stored episodes whose start_time falls within the
    recording window are deleted before inserting the new ones).
    """
    new_rows = []
    time_ranges = []  # (start, end) per recording – used to purge old data

    for rec in report.get("recordings", []):
        rec_start = pd.Timestamp(rec["start_time"])
        rec_end = pd.Timestamp(rec["end_time"])
        time_ranges.append((rec_start, rec_end))

        for ep in rec.get("episodes", []):
            new_rows.append({
                "recording_file": rec["file"],
                "rec_start": rec_start,
                "rec_end": rec_end,
                "episode_type": ep.get("episode_type", "bigeminy"),
                "start_time": pd.Timestamp(ep["start_time"]),
                "end_time": pd.Timestamp(ep["end_time"]),
                "duration_seconds": ep["duration_seconds"],
                "total_beats": ep["total_beats"],
                "normal_beats": ep["normal_beats"],
                "pvc_beats": ep["pvc_beats"],
                "avg_confidence": ep["avg_confidence"],
                "start_sample_100hz": ep["start_sample_100hz"],
                "end_sample_100hz": ep["end_sample_100hz"],
            })

    new_df = pd.DataFrame(new_rows)

    # Load existing parquet (if any) and remove rows in the overlapping ranges
    if os.path.isfile(PARQUET_PATH):
        existing = pd.read_parquet(PARQUET_PATH)
        if not existing.empty and "start_time" in existing.columns:
            mask = pd.Series(True, index=existing.index)
            for r_start, r_end in time_ranges:
                mask &= ~((existing["start_time"] >= r_start) &
                          (existing["start_time"] <= r_end))
            existing = existing[mask]
            combined = pd.concat([existing, new_df], ignore_index=True)
        else:
            combined = new_df
    else:
        combined = new_df

    if not combined.empty:
        combined = combined.sort_values("start_time").reset_index(drop=True)

    combined.to_parquet(PARQUET_PATH, index=False)
    log.info("Parquet updated: %d total episodes in %s", len(combined), PARQUET_PATH)
    return combined


def save_hourly_to_parquet(report):
    """Save per-hour beat counts (for heart rate) to hourly_hr.parquet."""
    new_rows = []
    time_ranges = []

    for rec in report.get("recordings", []):
        rec_start = pd.Timestamp(rec["start_time"])
        rec_end = pd.Timestamp(rec["end_time"])
        time_ranges.append((rec_start, rec_end))

        for h_entry in rec.get("hourly_summary", []):
            hour_ts = pd.Timestamp(h_entry["hour"])
            # Actual slot duration: may be < BUCKET_SEC at the end of a recording
            slot_end = min(hour_ts + pd.Timedelta(seconds=BUCKET_SEC), rec_end)
            duration_sec = max((slot_end - hour_ts).total_seconds(), 1.0)
            new_rows.append({
                "recording_file": rec["file"],
                "rec_start": rec_start,
                "rec_end": rec_end,
                "hour_start": hour_ts,
                "total_beats": h_entry["total_beats"],
                "normal_beats": h_entry["normal_beats"],
                "pac_beats": h_entry["pac_beats"],
                "pvc_beats": h_entry["pvc_beats"],
                "duration_seconds": duration_sec,
                "hr_bpm": h_entry.get("hr_bpm", 0),
            })

    new_df = pd.DataFrame(new_rows)
    if new_df.empty:
        return

    if os.path.isfile(HOURLY_PARQUET_PATH):
        existing = pd.read_parquet(HOURLY_PARQUET_PATH)
        if not existing.empty and "hour_start" in existing.columns:
            mask = pd.Series(True, index=existing.index)
            for r_start, r_end in time_ranges:
                mask &= ~((existing["hour_start"] >= r_start) &
                          (existing["hour_start"] <= r_end))
            existing = existing[mask]
            combined = pd.concat([existing, new_df], ignore_index=True)
        else:
            combined = new_df
    else:
        combined = new_df

    combined = combined.sort_values("hour_start").reset_index(drop=True)
    combined.to_parquet(HOURLY_PARQUET_PATH, index=False)
    log.info("Hourly HR parquet updated: %d rows in %s", len(combined), HOURLY_PARQUET_PATH)


def save_raw_ecg_to_parquet(recording_file, samples, start_time):
    """Save raw 125 Hz ECG samples into day-based parquet files.

    Each file covers one calendar day: data/ecg_raw_YYYYMMDD.parquet
    Samples are stored as 10-second chunks (RAW_CHUNK_SAMPLES = 1,250 samples).
    Recordings that span midnight are split across two day files automatically.
    If the day file already exists, any existing chunks for *recording_file* are
    replaced (same upsert pattern as the episode / hourly parquet writers).
    """
    import pyarrow as pa
    import pyarrow.parquet as pq
    import pyarrow.compute as pc

    arr = np.array(samples, dtype=np.int32)
    n = len(arr)

    # Build chunks grouped by calendar day (handles midnight-spanning recordings)
    day_chunks: dict[str, list] = {}
    for i in range(0, n, RAW_CHUNK_SAMPLES):
        chunk_start = start_time + timedelta(seconds=i / ORIG_SAMPLE_RATE)
        day_str = chunk_start.strftime("%Y%m%d")
        day_chunks.setdefault(day_str, []).append(
            (chunk_start, arr[i:i + RAW_CHUNK_SAMPLES].tolist())
        )

    for day_str, chunks in day_chunks.items():
        out_path = os.path.join(ECG_PARQUET_DIR, f"ecg_raw_{day_str}.parquet")

        new_table = pa.table({
            "recording_file": pa.array([recording_file] * len(chunks), type=pa.string()),
            "chunk_start":    pa.array([c[0] for c in chunks], type=pa.timestamp("ms")),
            "samples":        pa.array([c[1] for c in chunks], type=pa.list_(pa.int32())),
        })

        if os.path.isfile(out_path):
            existing = pq.read_table(out_path)
            existing = existing.filter(
                pc.not_equal(existing.column("recording_file"), recording_file)
            )
            combined = pa.concat_tables([existing, new_table])
        else:
            combined = new_table

        combined = combined.sort_by([("recording_file", "ascending"),
                                     ("chunk_start", "ascending")])
        pq.write_table(combined, out_path,
                       compression="zstd",
                       row_group_size=RAW_CHUNK_ROW_GROUP)
        log.info("Raw ECG parquet saved: %s (%d chunks)", out_path, len(chunks))


def load_all_episodes():
    """Load every episode from the persistent parquet file."""
    if not os.path.isfile(PARQUET_PATH):
        return pd.DataFrame()
    return pd.read_parquet(PARQUET_PATH)


def query_episodes(start: str, end: str) -> list[dict]:
    """Query episodes from the parquet file using DuckDB.

    *start* and *end* are ISO-8601 datetime strings (e.g. '2026-03-05 00:00:00').
    Returns a list of episode dicts for episodes whose start_time falls within
    the [start, end) window.
    """
    if not os.path.isfile(PARQUET_PATH):
        return []
    sql = """
        SELECT
            recording_file,
            rec_start,
            rec_end,
            episode_type,
            start_time,
            end_time,
            duration_seconds,
            total_beats,
            normal_beats,
            pvc_beats,
            avg_confidence,
            start_sample_100hz,
            end_sample_100hz
        FROM read_parquet(?)
        WHERE start_time >= ?::TIMESTAMP
          AND start_time <  ?::TIMESTAMP
        ORDER BY start_time
    """
    con = duckdb.connect()
    try:
        rows = con.execute(sql, [PARQUET_PATH, start, end]).fetchdf()
    finally:
        con.close()
    # Convert timestamps to strings for JSON serialisation
    for col in ["rec_start", "rec_end", "start_time", "end_time"]:
        if col in rows.columns:
            rows[col] = rows[col].dt.strftime("%Y-%m-%d %H:%M:%S.%f").str[:-3]
    return rows.to_dict(orient="records")


def query_date_range() -> dict:
    """Return the earliest and latest episode timestamps in the parquet file."""
    if not os.path.isfile(PARQUET_PATH):
        return {"min": None, "max": None}
    con = duckdb.connect()
    try:
        row = con.execute(
            "SELECT MIN(start_time) AS mn, MAX(start_time) AS mx "
            "FROM read_parquet(?)", [PARQUET_PATH]
        ).fetchone()
    finally:
        con.close()
    if row and row[0] is not None:
        return {
            "min": row[0].strftime("%Y-%m-%d %H:%M:%S"),
            "max": row[1].strftime("%Y-%m-%d %H:%M:%S"),
        }
    return {"min": None, "max": None}


def query_raw_ecg(center_dt, window_sec=120):
    """Return raw ECG samples for a window centred on *center_dt*.

    Returns a dict:
        start_ms     – epoch-ms of the first sample in the result array
        sample_rate  – 125
        window_sec   – actual window used
        samples      – list[int], length = window_sec * 125, zeros where no data
        data_ranges  – list of [start_ms, end_ms] for contiguous recorded segments
    """
    import pyarrow.parquet as pq

    half        = timedelta(seconds=window_sec / 2)
    t_start     = center_dt - half
    t_end       = center_dt + half
    n_target    = int(window_sec * ORIG_SAMPLE_RATE)
    epoch       = datetime(1970, 1, 1)
    target_start_ms = int((t_start - epoch).total_seconds() * 1000)
    interval_ms = 1000.0 / ORIG_SAMPLE_RATE  # 8 ms per sample

    result   = np.zeros(n_target, dtype=np.int32)
    has_data = np.zeros(n_target, dtype=bool)
    chunk_sec = RAW_CHUNK_SAMPLES / ORIG_SAMPLE_RATE  # 10 s

    d = t_start.date()
    while d <= t_end.date():
        path = os.path.join(ECG_PARQUET_DIR, f"ecg_raw_{d.strftime('%Y%m%d')}.parquet")
        if os.path.isfile(path):
            try:
                table = pq.read_table(
                    path,
                    columns=["chunk_start", "samples"],
                    filters=[
                        ("chunk_start", ">=", t_start - timedelta(seconds=chunk_sec)),
                        ("chunk_start", "<",  t_end),
                    ],
                )
                for row_idx in range(len(table)):
                    cs: datetime = table["chunk_start"][row_idx].as_py()
                    raw: list    = table["samples"][row_idx].as_py()
                    cs_ms  = int((cs - epoch).total_seconds() * 1000)
                    offset = round((cs_ms - target_start_ms) * ORIG_SAMPLE_RATE / 1000)
                    arr    = np.array(raw, dtype=np.int32)
                    src_lo = max(0, -offset)
                    src_hi = min(len(arr), n_target - offset)
                    if src_lo >= src_hi:
                        continue
                    dst_lo = offset + src_lo
                    dst_hi = offset + src_hi
                    result  [dst_lo:dst_hi] = arr[src_lo:src_hi]
                    has_data[dst_lo:dst_hi] = True
            except Exception as exc:
                log.warning("Failed to read raw parquet %s: %s", path, exc)
        d = (datetime(d.year, d.month, d.day) + timedelta(days=1)).date()

    # Compute contiguous data ranges
    data_ranges = []
    in_range = False
    range_start = 0
    for i in range(n_target):
        if has_data[i] and not in_range:
            in_range = True
            range_start = i
        elif not has_data[i] and in_range:
            in_range = False
            data_ranges.append([
                target_start_ms + round(range_start * interval_ms),
                target_start_ms + round(i * interval_ms),
            ])
    if in_range:
        data_ranges.append([
            target_start_ms + round(range_start * interval_ms),
            target_start_ms + round(n_target * interval_ms),
        ])

    return {
        "start_ms":    target_start_ms,
        "sample_rate": ORIG_SAMPLE_RATE,
        "window_sec":  window_sec,
        "samples":     result.tolist(),
        "data_ranges": data_ranges,
    }


def build_report_from_parquet(df):
    """Reconstruct a report dict (same shape as analyse_files output)
    from the parquet DataFrame so the results.html template works unchanged."""
    if "episode_type" not in df.columns:
        df = df.copy()
        df["episode_type"] = "bigeminy"

    if df.empty:
        return {
            "analysis": "ECG Arrhythmia Detection (all-time)",
            "recordings": [],
            "overall_summary": {
                "total_recordings": 0,
                "total_beats_analysed": 0,
                "total_pvc": 0,
                "overall_pvc_burden_pct": 0,
                "total_episodes": 0,
                "total_episode_seconds": 0,
                "episodes_by_type": {"bigeminy": 0, "trigeminy": 0, "couplet": 0, "vtach": 0},
            },
        }

    recordings = []
    for (rec_file, rec_start, rec_end), grp in df.groupby(
            ["recording_file", "rec_start", "rec_end"]):
        episodes = []
        for _, row in grp.iterrows():
            episodes.append({
                "episode_type": row.get("episode_type", "bigeminy"),
                "start_time": row["start_time"].strftime("%Y-%m-%d %H:%M:%S.%f")[:-3],
                "end_time": row["end_time"].strftime("%Y-%m-%d %H:%M:%S.%f")[:-3],
                "duration_seconds": row["duration_seconds"],
                "total_beats": int(row["total_beats"]),
                "normal_beats": int(row["normal_beats"]),
                "pvc_beats": int(row["pvc_beats"]),
                "avg_confidence": row["avg_confidence"],
                "start_sample_100hz": int(row["start_sample_100hz"]),
                "end_sample_100hz": int(row["end_sample_100hz"]),
            })

        duration_sec = (rec_end - rec_start).total_seconds()
        total_pvc_in_episodes = sum(e["pvc_beats"] for e in episodes)

        by_type = {t: sum(1 for e in episodes if e["episode_type"] == t)
                   for t in ("bigeminy", "trigeminy", "couplet", "vtach")}

        recordings.append({
            "file": rec_file,
            "start_time": rec_start.strftime("%Y-%m-%d %H:%M:%S"),
            "end_time": rec_end.strftime("%Y-%m-%d %H:%M:%S"),
            "duration_hours": round(duration_sec / 3600, 2),
            "total_beats": sum(e["total_beats"] for e in episodes),
            "beat_summary": {
                "normal_qrs": 0, "pac": 0,
                "pvc": total_pvc_in_episodes, "unclassified": 0, "pvc_burden_pct": 0,
            },
            "episodes": episodes,
            "episode_summary": {
                "total": len(episodes),
                **by_type,
                "total_seconds": round(sum(e["duration_seconds"] for e in episodes), 2),
                "total_beats": sum(e["total_beats"] for e in episodes),
            },
            "hourly_summary": [],
        })

    recordings.sort(key=lambda r: r["start_time"])
    all_eps = [e for r in recordings for e in r["episodes"]]
    total_pvc = sum(r["beat_summary"]["pvc"] for r in recordings)
    total_beats = sum(r["total_beats"] for r in recordings)

    return {
        "analysis": "ECG Arrhythmia Detection (all-time)",
        "recordings": recordings,
        "overall_summary": {
            "total_recordings": len(recordings),
            "total_beats_analysed": total_beats,
            "total_pvc": total_pvc,
            "overall_pvc_burden_pct": round(100 * total_pvc / total_beats, 2) if total_beats > 0 else 0,
            "total_episodes": len(all_eps),
            "total_episode_seconds": round(sum(e["duration_seconds"] for e in all_eps), 2),
            "episodes_by_type": {
                t: sum(1 for e in all_eps if e["episode_type"] == t)
                for t in ("bigeminy", "trigeminy", "couplet", "vtach")
            },
        },
    }


# ---------------------------------------------------------------------------
# Validate uploaded file looks like an R-file
# ---------------------------------------------------------------------------

def is_valid_r_filename(filename):
    return bool(re.search(r"R\d{14}$", filename))


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.route("/")
def index():
    return redirect(url_for("analytics"))


@app.route("/ble")
def ble_monitor():
    return render_template("ble_monitor.html")


@app.route("/api/model_status")
def api_model_status():
    return jsonify({"status": _model_status, "error": _model_error})


@app.route("/reprocess")
def reprocess_page():
    """Show raw files available for reprocessing, newest first, paginated."""
    raw_files = sorted(
        [f for f in os.listdir(RAW_DIR) if is_valid_r_filename(f)],
        reverse=True,
    )
    file_info = []
    for fname in raw_files:
        m = re.search(r"R(\d{14})$", fname)
        ts = datetime.strptime(m.group(1), "%Y%m%d%H%M%S") if m else None
        size_kb = os.path.getsize(os.path.join(RAW_DIR, fname)) // 1024
        file_info.append({"name": fname, "ts": ts, "size_kb": size_kb})

    per_page = 20
    total_files = len(file_info)
    total_pages = max(1, (total_files + per_page - 1) // per_page)
    try:
        page = int(request.args.get("page", 1))
    except (TypeError, ValueError):
        page = 1
    page = max(1, min(page, total_pages))
    start = (page - 1) * per_page
    page_files = file_info[start:start + per_page]

    return render_template(
        "reprocess.html",
        files=page_files,
        total_files=total_files,
        page=page,
        total_pages=total_pages,
        per_page=per_page,
    )


@app.route("/api/reprocess", methods=["POST"])
def api_reprocess():
    """Create a new session from selected raw files and redirect to analyse."""
    selected = request.form.getlist("files")
    if not selected:
        flash("No files selected.", "error")
        return redirect(url_for("reprocess_page"))

    session_id = uuid.uuid4().hex[:12]
    session_dir = os.path.join(UPLOAD_FOLDER, session_id)
    os.makedirs(session_dir, exist_ok=True)

    copied = []
    for fname in selected:
        src = os.path.join(RAW_DIR, fname)
        if os.path.isfile(src) and is_valid_r_filename(fname):
            shutil.copy2(src, os.path.join(session_dir, fname))
            copied.append(fname)

    if not copied:
        shutil.rmtree(session_dir, ignore_errors=True)
        flash("None of the selected files could be found.", "error")
        return redirect(url_for("reprocess_page"))

    return redirect(url_for("analyse", session_id=session_id))


@app.route("/upload", methods=["GET", "POST"])
def upload():
    if request.method == "GET":
        return render_template("index.html")

    wants_json = (
        request.accept_mimetypes.best_match(["application/json", "text/html"])
        == "application/json"
    )

    if "files" not in request.files:
        if wants_json:
            return jsonify({"error": "No files selected"}), 400
        flash("No files selected.", "error")
        return redirect(url_for("upload"))

    files = request.files.getlist("files")
    if not files or all(f.filename == "" for f in files):
        if wants_json:
            return jsonify({"error": "No files selected"}), 400
        flash("No files selected.", "error")
        return redirect(url_for("upload"))

    # Create session upload dir
    session_id = uuid.uuid4().hex[:12]
    session_dir = os.path.join(UPLOAD_FOLDER, session_id)
    os.makedirs(session_dir, exist_ok=True)

    registry = _load_upload_registry()
    saved = []
    for f in files:
        if not f.filename or not is_valid_r_filename(f.filename):
            flash(f"Skipped '{f.filename}' — not a valid R-file name (must end with R followed by 14 digits).", "warning")
            continue

        # Save to a temp path first so we can measure size before committing
        tmp_dest = os.path.join(session_dir, f.filename + ".tmp")
        f.save(tmp_dest)
        file_size = os.path.getsize(tmp_dest)

        # Dedup check: same filename AND same size → already uploaded
        if registry.get(f.filename) == file_size:
            os.remove(tmp_dest)
            log.info("Skipped duplicate upload: %s (%d bytes)", f.filename, file_size)
            flash(f"Skipped '{f.filename}' — already uploaded ({file_size:,} bytes).", "warning")
            continue

        # Commit the file
        dest = os.path.join(session_dir, f.filename)
        os.rename(tmp_dest, dest)
        saved.append(dest)

        # Keep a permanent copy in data/raw/
        raw_dest = os.path.join(RAW_DIR, f.filename)
        shutil.copy2(dest, raw_dest)
        log.info("Stored raw file: %s", raw_dest)

        # Register for future dedup
        registry[f.filename] = file_size
        _save_upload_registry(registry)

    if not saved:
        flash("No valid R-files were uploaded.", "error")
        shutil.rmtree(session_dir, ignore_errors=True)
        if wants_json:
            return jsonify({"error": "No valid R-files were uploaded"}), 400
        return redirect(url_for("upload"))

    if wants_json:
        filenames = [os.path.basename(p) for p in saved]
        return jsonify({
            "session_id": session_id,
            "files": filenames,
            "count": len(filenames),
        }), 200

    return redirect(url_for("analyse", session_id=session_id))


@app.route("/api/upload", methods=["POST"])
def api_upload():
    """JSON-only upload endpoint for the iOS app."""
    if "files" not in request.files:
        return jsonify({"error": "No files selected"}), 400

    files = request.files.getlist("files")
    if not files or all(f.filename == "" for f in files):
        return jsonify({"error": "No files selected"}), 400

    session_id = uuid.uuid4().hex[:12]
    session_dir = os.path.join(UPLOAD_FOLDER, session_id)
    os.makedirs(session_dir, exist_ok=True)

    registry = _load_upload_registry()
    accepted = []
    for f in files:
        if not f.filename or not is_valid_r_filename(f.filename):
            continue

        tmp_dest = os.path.join(session_dir, f.filename + ".tmp")
        f.save(tmp_dest)
        file_size = os.path.getsize(tmp_dest)
        dest = os.path.join(session_dir, f.filename)

        if registry.get(f.filename) == file_size:
            # Already have this file — copy from raw archive into session
            os.remove(tmp_dest)
            raw_src = os.path.join(RAW_DIR, f.filename)
            if os.path.isfile(raw_src):
                shutil.copy2(raw_src, dest)
                accepted.append(f.filename)
            continue

        os.rename(tmp_dest, dest)
        accepted.append(f.filename)

        raw_dest = os.path.join(RAW_DIR, f.filename)
        shutil.copy2(dest, raw_dest)
        log.info("Stored raw file: %s", raw_dest)

        registry[f.filename] = file_size
        _save_upload_registry(registry)

    if not accepted:
        shutil.rmtree(session_dir, ignore_errors=True)
        return jsonify({"error": "No valid R-files were uploaded"}), 400

    return jsonify({
        "session_id": session_id,
        "files": accepted,
        "count": len(accepted),
    }), 200


@app.route("/api/inference/<session_id>", methods=["POST"])
def api_inference_start(session_id):
    """Kick off inference for an uploaded session. Returns immediately."""
    session_dir = os.path.join(UPLOAD_FOLDER, session_id)
    if not os.path.isdir(session_dir):
        return jsonify({"error": "Session not found"}), 404

    r_files = sorted([
        os.path.join(session_dir, f)
        for f in os.listdir(session_dir)
        if re.search(r"R\d{14}$", f)
    ])
    if not r_files:
        return jsonify({"error": "No R-files found"}), 400

    existing = _get_inference_status(session_id)
    if existing and existing.get("status") == "processing":
        return jsonify({"session_id": session_id, "status": "processing"}), 200

    _set_inference_status(session_id, "processing")

    def run():
        try:
            report = analyse_files(r_files)
            save_episodes_to_parquet(report)
            save_hourly_to_parquet(report)
            report_path = os.path.join(session_dir, "report.json")
            with open(report_path, "w") as f:
                json.dump(report, f)
            _set_inference_status(session_id, "done")
            log.info("Inference complete for session %s", session_id)
        except Exception as e:
            log.exception("Inference failed for session %s", session_id)
            _set_inference_status(session_id, "error", str(e))

    t = threading.Thread(target=run, daemon=True)
    t.start()

    return jsonify({
        "session_id": session_id,
        "status": "processing",
        "file_count": len(r_files),
    }), 202


@app.route("/api/inference/<session_id>/status")
def api_inference_status(session_id):
    """Poll inference status for a session."""
    session_dir = os.path.join(UPLOAD_FOLDER, session_id)
    if not os.path.isdir(session_dir):
        return jsonify({"error": "Session not found"}), 404

    entry = _get_inference_status(session_id)

    # Fallback: if no status entry exists but report.json is present,
    # inference completed via the SSE stream or before status tracking.
    if entry is None or entry.get("status") == "pending":
        report_path = os.path.join(session_dir, "report.json")
        if os.path.isfile(report_path):
            _set_inference_status(session_id, "done")
            return jsonify({"session_id": session_id, "status": "done"}), 200

    if entry is None:
        return jsonify({"session_id": session_id, "status": "pending"}), 200

    resp = {"session_id": session_id, "status": entry["status"]}
    if "error" in entry:
        resp["error"] = entry["error"]
    return jsonify(resp), 200


@app.route("/analyse/<session_id>")
def analyse(session_id):
    session_dir = os.path.join(UPLOAD_FOLDER, session_id)
    if not os.path.isdir(session_dir):
        flash("Session not found.", "error")
        return redirect(url_for("upload"))

    # Find R-files
    r_files = sorted([
        os.path.join(session_dir, f)
        for f in os.listdir(session_dir)
        if re.search(r"R\d{14}$", f)
    ])

    if not r_files:
        flash("No R-files found in session.", "error")
        return redirect(url_for("upload"))

    return render_template("processing.html", session_id=session_id, file_count=len(r_files),
                           filenames=[os.path.basename(f) for f in r_files])


@app.route("/api/run/<session_id>", methods=["POST"])
def api_run(session_id):
    """Legacy POST endpoint — runs analysis without streaming."""
    session_dir = os.path.join(UPLOAD_FOLDER, session_id)
    if not os.path.isdir(session_dir):
        return jsonify({"error": "Session not found"}), 404

    r_files = sorted([
        os.path.join(session_dir, f)
        for f in os.listdir(session_dir)
        if re.search(r"R\d{14}$", f)
    ])

    if not r_files:
        return jsonify({"error": "No R-files found"}), 400

    try:
        report = analyse_files(r_files)
    except Exception as e:
        log.exception("Analysis failed")
        return jsonify({"error": str(e)}), 500

    # Save episodes to persistent parquet (overwrites episodes in this time range)
    save_episodes_to_parquet(report)
    save_hourly_to_parquet(report)

    # Save report JSON for this session
    report_path = os.path.join(session_dir, "report.json")
    with open(report_path, "w") as f:
        json.dump(report, f)

    return jsonify({"status": "ok", "session_id": session_id})


@app.route("/api/stream/<session_id>")
def api_stream(session_id):
    """SSE endpoint — streams analysis progress to the browser."""
    session_dir = os.path.join(UPLOAD_FOLDER, session_id)
    if not os.path.isdir(session_dir):
        return jsonify({"error": "Session not found"}), 404

    r_files = sorted([
        os.path.join(session_dir, f)
        for f in os.listdir(session_dir)
        if re.search(r"R\d{14}$", f)
    ])

    if not r_files:
        return jsonify({"error": "No R-files found"}), 400

    def generate():
        import queue, threading

        q = queue.Queue()

        def on_progress(msg):
            q.put(("log", msg))

        def run():
            try:
                report = analyse_files(r_files, on_progress=on_progress)
                save_episodes_to_parquet(report)
                save_hourly_to_parquet(report)
                report_path = os.path.join(session_dir, "report.json")
                with open(report_path, "w") as f:
                    json.dump(report, f)
                q.put(("done", session_id))
            except Exception as e:
                log.exception("Analysis failed")
                q.put(("error", str(e)))

        t = threading.Thread(target=run, daemon=True)
        t.start()

        while True:
            try:
                kind, payload = q.get(timeout=30)
            except queue.Empty:
                # Keep-alive
                yield "event: ping\ndata: keepalive\n\n"
                continue

            if kind == "log":
                # Escape newlines for SSE
                safe = payload.replace("\n", " ")
                yield f"event: log\ndata: {safe}\n\n"
            elif kind == "done":
                yield f"event: done\ndata: {payload}\n\n"
                break
            elif kind == "error":
                yield f"event: error\ndata: {payload}\n\n"
                break

    return Response(
        stream_with_context(generate()),
        mimetype="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
        },
    )


@app.route("/results/<session_id>")
def results(session_id):
    session_dir = os.path.join(UPLOAD_FOLDER, session_id)
    report_path = os.path.join(session_dir, "report.json")

    if not os.path.isfile(report_path):
        flash("Results not found. Run analysis first.", "error")
        return redirect(url_for("upload"))

    with open(report_path) as f:
        report = json.load(f)

    # Determine time range for subtitle
    all_starts = [r["start_time"] for r in report["recordings"]]
    all_ends = [r["end_time"] for r in report["recordings"]]
    earliest = min(all_starts) if all_starts else ""
    latest = max(all_ends) if all_ends else ""

    return render_template("results.html",
                           report_json=json.dumps(report),
                           earliest=earliest,
                           latest=latest)


# ---------------------------------------------------------------------------
# Timeline – day-by-day browser
# ---------------------------------------------------------------------------

@app.route("/timeline")
def timeline():
    """Day-navigable timeline of bigeminy episodes, queried via DuckDB."""
    return render_template("timeline.html")


@app.route("/api/episodes")
def api_episodes():
    """JSON endpoint: query episodes by date range.

    Query params:
        start  – ISO datetime (default: yesterday 00:00:00)
        end    – ISO datetime (default: today 00:00:00)
    """
    today = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
    yesterday = today - timedelta(days=1)
    start = request.args.get("start", yesterday.strftime("%Y-%m-%d %H:%M:%S"))
    end = request.args.get("end", today.strftime("%Y-%m-%d %H:%M:%S"))

    episodes = query_episodes(start, end)

    total_beats = sum(e["total_beats"] for e in episodes)
    total_pvc = sum(e["pvc_beats"] for e in episodes)
    total_duration = sum(e["duration_seconds"] for e in episodes)

    return jsonify({
        "start": start,
        "end": end,
        "episodes": episodes,
        "summary": {
            "total_episodes": len(episodes),
            "total_beats": total_beats,
            "total_pvc": total_pvc,
            "total_bigeminy_seconds": round(total_duration, 2),
        },
        "data_range": query_date_range(),
    })


@app.route("/api/summary")
def api_summary():
    """All-time summary stats plus per-day episode counts queried via DuckDB."""
    if not os.path.isfile(PARQUET_PATH):
        return jsonify({
            "data_range": {"min": None, "max": None},
            "total_episodes": 0,
            "total_bigeminy_seconds": 0,
            "total_beats": 0,
            "total_pvc": 0,
            "daily": [],
        })

    con = duckdb.connect()
    try:
        # Overall stats
        overall = con.execute(
            "SELECT COUNT(*) AS n, "
            "       COALESCE(SUM(duration_seconds), 0) AS dur, "
            "       COALESCE(SUM(total_beats), 0) AS beats, "
            "       COALESCE(SUM(pvc_beats), 0) AS pvcs, "
            "       MIN(start_time) AS mn, "
            "       MAX(start_time) AS mx "
            "FROM read_parquet(?)", [PARQUET_PATH]
        ).fetchone()

        # Per-day counts
        daily = con.execute(
            "SELECT CAST(start_time AS DATE) AS day, "
            "       COUNT(*) AS episodes, "
            "       SUM(duration_seconds) AS dur "
            "FROM read_parquet(?) "
            "GROUP BY day ORDER BY day", [PARQUET_PATH]
        ).fetchdf()
    finally:
        con.close()

    daily_list = []
    for _, row in daily.iterrows():
        daily_list.append({
            "date": str(row["day"]),
            "episodes": int(row["episodes"]),
            "bigeminy_seconds": round(float(row["dur"]), 2),
        })

    return jsonify({
        "data_range": {
            "min": overall[4].strftime("%Y-%m-%d %H:%M:%S") if overall[4] else None,
            "max": overall[5].strftime("%Y-%m-%d %H:%M:%S") if overall[5] else None,
        },
        "total_episodes": int(overall[0]),
        "total_bigeminy_seconds": round(float(overall[1]), 2),
        "total_beats": int(overall[2]),
        "total_pvc": int(overall[3]),
        "daily": daily_list,
    })


@app.route("/api/hourly")
def api_hourly():
    """Per-hour heart rate and recording spans for a date range.

    Query params:
        start  – ISO datetime (default: yesterday 00:00:00)
        end    – ISO datetime (default: today 00:00:00)
    """
    today = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
    yesterday = today - timedelta(days=1)
    start = request.args.get("start", yesterday.strftime("%Y-%m-%d %H:%M:%S"))
    end = request.args.get("end", today.strftime("%Y-%m-%d %H:%M:%S"))

    if not os.path.isfile(HOURLY_PARQUET_PATH):
        return jsonify({"hourly": [], "recordings": []})

    con = duckdb.connect()
    try:
        rows = con.execute(
            "SELECT hour_start, total_beats, normal_beats, pac_beats, pvc_beats, "
            "       duration_seconds, recording_file, rec_start, rec_end "
            "FROM read_parquet(?) "
            "WHERE hour_start >= ?::TIMESTAMP AND hour_start < ?::TIMESTAMP "
            "ORDER BY hour_start",
            [HOURLY_PARQUET_PATH, start, end]
        ).fetchdf()

        # Recording spans that overlap with the requested window (for "has data" indicator)
        rec_spans = con.execute(
            "SELECT DISTINCT recording_file, rec_start, rec_end "
            "FROM read_parquet(?) "
            "WHERE rec_start < ?::TIMESTAMP AND rec_end > ?::TIMESTAMP "
            "ORDER BY rec_start",
            [HOURLY_PARQUET_PATH, end, start]
        ).fetchdf()
    finally:
        con.close()

    hourly_list = []
    for _, row in rows.iterrows():
        n = int(row["total_beats"])
        # Use median-RR-derived hr_bpm if available (accurate at high HR);
        # fall back to count-based for legacy rows that predate the field.
        if "hr_bpm" in row and row["hr_bpm"] and float(row["hr_bpm"]) > 0:
            hr_bpm = round(float(row["hr_bpm"]), 1)
        else:
            dur = float(row["duration_seconds"]) if float(row["duration_seconds"]) > 0 else BUCKET_SEC
            hr_bpm = round((n / dur) * 60, 1) if dur > 0 and n > 0 else 0
        hourly_list.append({
            "hour_start": str(row["hour_start"]),
            "total_beats": n,
            "hr_bpm": hr_bpm,
            "pvc_beats": int(row["pvc_beats"]),
        })

    rec_list = []
    for _, row in rec_spans.iterrows():
        rec_list.append({
            "file": str(row["recording_file"]),
            "rec_start": str(row["rec_start"]),
            "rec_end": str(row["rec_end"]),
        })

    return jsonify({"hourly": hourly_list, "recordings": rec_list})


@app.route("/viewer")
def viewer():
    return render_template("viewer.html")


@app.route("/api/ecg_raw")
def api_ecg_raw():
    """Raw ECG samples for a time window centred on *center*.

    Query params:
        center  – ISO datetime string (e.g. 2026-03-05T21:22:38)
        window  – window length in seconds (default 120, max 3600)
    """
    center_str = request.args.get("center", "").strip()
    if not center_str:
        return jsonify({"error": "center parameter required"}), 400
    try:
        center_dt = datetime.fromisoformat(center_str.replace("Z", "+00:00"))
    except ValueError:
        return jsonify({"error": f"Invalid center timestamp: {center_str!r}"}), 400
    if center_dt.tzinfo is not None:
        center_dt = center_dt.astimezone(timezone.utc).replace(tzinfo=None)
    try:
        window_sec = max(10, min(3600, int(request.args.get("window", 120))))
    except ValueError:
        window_sec = 120
    return jsonify(query_raw_ecg(center_dt, window_sec))


@app.route("/analytics")
def analytics():
    return render_template("analytics.html")


@app.route("/api/pvc_burden")
def api_pvc_burden():
    """PVC burden aggregated by day or hour.

    Query params:
        granularity – 'day' or 'hour' (default: 'day')
        start       – ISO datetime
        end         – ISO datetime
    """
    granularity = request.args.get("granularity", "day")
    today = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
    thirty_days_ago = today - timedelta(days=30)
    start = request.args.get("start", thirty_days_ago.strftime("%Y-%m-%d %H:%M:%S"))
    end = request.args.get("end", (today + timedelta(days=1)).strftime("%Y-%m-%d %H:%M:%S"))

    if not os.path.isfile(HOURLY_PARQUET_PATH):
        return jsonify({"data": [], "granularity": granularity})

    con = duckdb.connect()
    try:
        if granularity == "day":
            rows = con.execute(
                "SELECT CAST(hour_start AS DATE) AS bucket, "
                "       SUM(total_beats) AS total_beats, "
                "       SUM(pvc_beats) AS pvc_beats "
                "FROM read_parquet(?) "
                "WHERE hour_start >= ?::TIMESTAMP AND hour_start < ?::TIMESTAMP "
                "GROUP BY bucket ORDER BY bucket",
                [HOURLY_PARQUET_PATH, start, end]
            ).fetchdf()
        else:
            rows = con.execute(
                "SELECT DATE_TRUNC('hour', hour_start) AS bucket, "
                "       SUM(total_beats) AS total_beats, "
                "       SUM(pvc_beats) AS pvc_beats "
                "FROM read_parquet(?) "
                "WHERE hour_start >= ?::TIMESTAMP AND hour_start < ?::TIMESTAMP "
                "GROUP BY bucket ORDER BY bucket",
                [HOURLY_PARQUET_PATH, start, end]
            ).fetchdf()
    finally:
        con.close()

    data = []
    for _, row in rows.iterrows():
        tb = int(row["total_beats"])
        pvc = int(row["pvc_beats"])
        burden = round((pvc / tb * 100), 2) if tb > 0 else 0
        data.append({
            "bucket": str(row["bucket"]),
            "total_beats": tb,
            "pvc_beats": pvc,
            "pvc_burden": burden,
        })

    return jsonify({"data": data, "granularity": granularity})


# ---------------------------------------------------------------------------
# Strava activities
# ---------------------------------------------------------------------------
ACTIVITY_COLUMNS = [
    "activity_id", "activity_type", "date", "start_time", "title",
    "duration_seconds", "distance", "elevation", "pace", "url",
]


def _parse_strava_duration(s: str) -> int:
    """Parse 'MM:SS' or 'HH:MM:SS' into total seconds."""
    parts = str(s).strip().split(":")
    if len(parts) == 2:
        return int(parts[0]) * 60 + int(parts[1])
    if len(parts) == 3:
        return int(parts[0]) * 3600 + int(parts[1]) * 60 + int(parts[2])
    raise ValueError(f"Unrecognised duration: {s!r}")


def _extract_strava_id(url: str) -> str:
    m = re.search(r"/activities/(\d+)", str(url or ""))
    if not m:
        raise ValueError(f"Cannot extract activity id from URL: {url!r}")
    return m.group(1)


def _build_start_dt(date_str: str, time_str) -> str | None:
    """Combine 'YYYY-MM-DD' + 'HH:MM' or 'HH:MM:SS' into 'YYYY-MM-DD HH:MM:SS'."""
    if time_str is None:
        return None
    t = str(time_str).strip()
    if not t or t.lower() in ("nan", "none"):
        return None
    parts = t.split(":")
    if len(parts) == 2:
        return f"{date_str} {t}:00"
    if len(parts) == 3:
        return f"{date_str} {t}"
    return None


def _load_activities() -> pd.DataFrame:
    if not os.path.isfile(ACTIVITIES_PARQUET_PATH):
        return pd.DataFrame(columns=ACTIVITY_COLUMNS)
    df = pd.read_parquet(ACTIVITIES_PARQUET_PATH)
    df["activity_id"] = df["activity_id"].astype(str)
    # Migrate older parquets that lack start_time / pace columns
    if "start_time" not in df.columns:
        df["start_time"] = None
    if "pace" not in df.columns:
        df["pace"] = ""
    return df


def _save_activities(df: pd.DataFrame) -> None:
    df.to_parquet(ACTIVITIES_PARQUET_PATH, index=False)


def _parse_strava_csv(text: str) -> pd.DataFrame:
    import io
    df = pd.read_csv(io.StringIO(text))
    expected = {"Activity Type", "Date", "Title", "Duration", "Distance", "Elevation", "URL"}
    missing = expected - set(df.columns)
    if missing:
        raise ValueError(f"CSV is missing required columns: {sorted(missing)}")

    has_time = "Time" in df.columns
    has_pace = "Pace" in df.columns

    if has_time:
        start_time_col = [_build_start_dt(d, t)
                          for d, t in zip(df["Date"].astype(str), df["Time"])]
    else:
        start_time_col = [None] * len(df)

    out = pd.DataFrame({
        "activity_id":      df["URL"].map(_extract_strava_id).astype(str),
        "activity_type":    df["Activity Type"].astype(str),
        "date":             df["Date"].astype(str),
        "start_time":       start_time_col,
        "title":            df["Title"].astype(str),
        "duration_seconds": df["Duration"].map(_parse_strava_duration).astype(int),
        "distance":         df["Distance"].astype(str),
        "elevation":        df["Elevation"].astype(str),
        "pace":             df["Pace"].fillna("").astype(str) if has_pace else "",
        "url":              df["URL"].astype(str),
    })
    return out.drop_duplicates(subset=["activity_id"], keep="first")


def _activity_to_dict(row) -> dict:
    """Coerce a parquet row to a JSON-friendly dict."""
    st = row.get("start_time") if hasattr(row, "get") else row["start_time"]
    if pd.isna(st) or not str(st).strip() or str(st) in ("None", "nan", "NaT"):
        st_clean = None
    else:
        st_clean = str(st)
    pace = row.get("pace") if hasattr(row, "get") else row["pace"]
    if pd.isna(pace):
        pace = ""
    return {
        "activity_id":      str(row["activity_id"]),
        "activity_type":    str(row["activity_type"]),
        "date":             str(row["date"]),
        "start_time":       st_clean,
        "title":            str(row["title"]),
        "duration_seconds": int(row["duration_seconds"]),
        "distance":         str(row["distance"]),
        "elevation":        str(row["elevation"]),
        "pace":             str(pace),
        "url":              str(row["url"]),
    }


def _guess_start_hour(title: str) -> int:
    t = (title or "").lower()
    if "morning" in t:   return 8
    if "lunch" in t:     return 12
    if "afternoon" in t: return 14
    if "evening" in t:   return 18
    if "night" in t:     return 21
    return 12


@app.route("/activities")
def activities_page():
    return render_template("activities.html")


@app.route("/api/activities")
def api_activities_list():
    df = _load_activities()
    if df.empty:
        return jsonify({"activities": []})
    df = df.sort_values(["date", "start_time"], ascending=[False, False], na_position="last")
    return jsonify({"activities": [_activity_to_dict(r) for _, r in df.iterrows()]})


@app.route("/api/activities/upload", methods=["POST"])
def api_activities_upload():
    if "file" not in request.files:
        return jsonify({"error": "No file uploaded"}), 400
    f = request.files["file"]
    if not f.filename:
        return jsonify({"error": "No file selected"}), 400
    try:
        text = f.read().decode("utf-8-sig")
        parsed = _parse_strava_csv(text)
    except Exception as exc:
        return jsonify({"error": f"Could not parse CSV: {exc}"}), 400

    existing = _load_activities()
    n_total = len(parsed)
    parsed_ids = set(parsed["activity_id"])
    existing_ids = set(existing["activity_id"]) if not existing.empty else set()
    n_new = len(parsed_ids - existing_ids)
    n_dup = n_total - n_new

    # Replace existing rows whose IDs appear in the new CSV so re-uploading a
    # CSV that adds new fields (e.g. Time, Pace) refreshes those values.
    if not existing.empty:
        existing = existing[~existing["activity_id"].isin(parsed_ids)]
    combined = pd.concat([existing, parsed], ignore_index=True) if not existing.empty else parsed
    combined = combined.drop_duplicates(subset=["activity_id"], keep="last")
    _save_activities(combined)
    log.info("Activities CSV: added %d, refreshed %d duplicates", n_new, n_dup)

    return jsonify({
        "added": n_new,
        "skipped": n_dup,
        "total": int(len(combined)),
    })


@app.route("/activities/<activity_id>")
def activity_detail_page(activity_id):
    df = _load_activities()
    if df.empty or activity_id not in set(df["activity_id"]):
        flash("Activity not found.", "error")
        return redirect(url_for("activities_page"))
    activity = _activity_to_dict(df[df["activity_id"] == activity_id].iloc[0])

    if activity["start_time"]:
        default_start_iso = activity["start_time"].replace(" ", "T")
        display_when = activity["start_time"][:16]
    else:
        d = datetime.fromisoformat(activity["date"]).replace(
            hour=_guess_start_hour(activity["title"]))
        default_start_iso = d.strftime("%Y-%m-%dT%H:%M:%S")
        display_when = activity["date"]

    return render_template("activity_report.html",
                           activity=activity,
                           activity_json=json.dumps(activity),
                           default_start_iso=default_start_iso,
                           display_when=display_when)


@app.route("/api/activities/<activity_id>/report")
def api_activity_report(activity_id):
    """Aggregated HR / episode / beat-count report for an activity window."""
    df = _load_activities()
    if df.empty or activity_id not in set(df["activity_id"]):
        return jsonify({"error": "Activity not found"}), 404
    activity = _activity_to_dict(df[df["activity_id"] == activity_id].iloc[0])

    start_param = (request.args.get("start") or "").strip()
    if start_param:
        try:
            start_dt = datetime.fromisoformat(start_param)
        except ValueError:
            return jsonify({"error": f"Invalid start: {start_param!r}"}), 400
    elif activity["start_time"]:
        start_dt = datetime.fromisoformat(activity["start_time"].replace(" ", "T"))
    else:
        start_dt = datetime.fromisoformat(activity["date"]).replace(
            hour=_guess_start_hour(activity["title"]))

    duration_sec = int(activity["duration_seconds"])
    try:
        recovery_min = max(0, min(240, int(request.args.get("recovery", 0))))
    except ValueError:
        recovery_min = 0

    end_dt = start_dt + timedelta(seconds=duration_sec)
    window_end = end_dt + timedelta(minutes=recovery_min)
    end_str = end_dt.strftime("%Y-%m-%d %H:%M:%S")

    # ── Hourly buckets in [start - 5m, window_end] ────────────────────────
    hourly = []
    if os.path.isfile(HOURLY_PARQUET_PATH):
        con = duckdb.connect()
        try:
            rows = con.execute(
                "SELECT hour_start, total_beats, normal_beats, pac_beats, pvc_beats, "
                "       duration_seconds, hr_bpm "
                "FROM read_parquet(?) "
                "WHERE hour_start >= ?::TIMESTAMP "
                "  AND hour_start <  ?::TIMESTAMP "
                "ORDER BY hour_start",
                [HOURLY_PARQUET_PATH,
                 (start_dt - timedelta(seconds=BUCKET_SEC)).strftime("%Y-%m-%d %H:%M:%S"),
                 window_end.strftime("%Y-%m-%d %H:%M:%S")]
            ).fetchdf()
        finally:
            con.close()
        for _, r in rows.iterrows():
            n = int(r["total_beats"])
            if "hr_bpm" in r and r["hr_bpm"] and float(r["hr_bpm"]) > 0:
                hr = round(float(r["hr_bpm"]), 1)
            else:
                d = float(r["duration_seconds"]) if float(r["duration_seconds"]) > 0 else BUCKET_SEC
                hr = round((n / d) * 60, 1) if d > 0 and n > 0 else 0
            hourly.append({
                "ts": str(r["hour_start"]),
                "total_beats": n,
                "pvc_beats": int(r["pvc_beats"]),
                "duration_seconds": float(r["duration_seconds"]),
                "hr_bpm": hr,
            })

    # ── Episodes in window ────────────────────────────────────────────────
    episodes = query_episodes(
        start_dt.strftime("%Y-%m-%d %H:%M:%S"),
        window_end.strftime("%Y-%m-%d %H:%M:%S"),
    )

    # ── Activity-only stats (exclude recovery buckets) ────────────────────
    act_buckets = [h for h in hourly if h["ts"] < end_str]
    valid_hr = [h["hr_bpm"] for h in act_buckets if h["hr_bpm"] > 0]
    total_beats = sum(h["total_beats"] for h in act_buckets)
    pvc_beats   = sum(h["pvc_beats"]   for h in act_buckets)
    activity_episodes = [e for e in episodes if e["start_time"] < end_str]

    summary = {
        "start_time":       start_dt.strftime("%Y-%m-%d %H:%M:%S"),
        "end_time":         end_str,
        "window_end":       window_end.strftime("%Y-%m-%d %H:%M:%S"),
        "duration_seconds": duration_sec,
        "recovery_minutes": recovery_min,
        "avg_hr":           round(sum(valid_hr) / len(valid_hr), 1) if valid_hr else 0,
        "peak_hr":          max(valid_hr) if valid_hr else 0,
        "min_hr":           min(valid_hr) if valid_hr else 0,
        "total_beats":      total_beats,
        "pvc_beats":        pvc_beats,
        "pvc_burden":       round(pvc_beats / total_beats * 100, 2) if total_beats > 0 else 0,
        "episode_count":    len(activity_episodes),
        "has_data":         bool(act_buckets),
    }

    return jsonify({
        "activity": {k: (str(v) if k == "activity_id" else v) for k, v in activity.items()},
        "summary":  summary,
        "hourly":   hourly,
        "episodes": episodes,
    })


# ---------------------------------------------------------------------------
# Events (annotations shown on analytics chart)
# ---------------------------------------------------------------------------
EVENT_COLUMNS = ["event_id", "date", "event", "created_at"]


def _load_events() -> pd.DataFrame:
    if not os.path.isfile(EVENTS_PARQUET_PATH):
        return pd.DataFrame(columns=EVENT_COLUMNS)
    df = pd.read_parquet(EVENTS_PARQUET_PATH)
    df["event_id"] = df["event_id"].astype(str)
    df["date"] = df["date"].astype(str)
    df["event"] = df["event"].astype(str)
    return df


def _save_events(df: pd.DataFrame) -> None:
    df.to_parquet(EVENTS_PARQUET_PATH, index=False)


def _validate_event_payload(data: dict) -> tuple[str, str] | None:
    date = (data.get("date") or "").strip()
    text = (data.get("event") or "").strip()
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
        return None
    try:
        datetime.fromisoformat(date)
    except ValueError:
        return None
    if not text or len(text) > 500:
        return None
    return date, text


@app.route("/events")
def events_page():
    return render_template("events.html")


@app.route("/api/events", methods=["GET"])
def api_events_list():
    df = _load_events()
    if df.empty:
        return jsonify({"events": []})
    df = df.sort_values("date", ascending=False)
    out = []
    for _, r in df.iterrows():
        out.append({
            "event_id":   str(r["event_id"]),
            "date":       str(r["date"]),
            "event":      str(r["event"]),
            "created_at": (pd.Timestamp(r["created_at"]).strftime("%Y-%m-%d %H:%M:%S")
                           if pd.notna(r["created_at"]) else None),
        })
    return jsonify({"events": out})


@app.route("/api/events", methods=["POST"])
def api_events_create():
    data = request.get_json(silent=True) or {}
    parsed = _validate_event_payload(data)
    if parsed is None:
        return jsonify({"error": "date (YYYY-MM-DD) and non-empty event text required"}), 400
    date, text = parsed
    df = _load_events()
    new_row = pd.DataFrame([{
        "event_id":   uuid.uuid4().hex,
        "date":       date,
        "event":      text,
        "created_at": pd.Timestamp.now(),
    }])
    combined = pd.concat([df, new_row], ignore_index=True) if not df.empty else new_row
    _save_events(combined)
    return jsonify({
        "event_id":   new_row.iloc[0]["event_id"],
        "date":       date,
        "event":      text,
        "created_at": new_row.iloc[0]["created_at"].strftime("%Y-%m-%d %H:%M:%S"),
    }), 201


@app.route("/api/events/<event_id>", methods=["PUT"])
def api_events_update(event_id):
    data = request.get_json(silent=True) or {}
    parsed = _validate_event_payload(data)
    if parsed is None:
        return jsonify({"error": "date (YYYY-MM-DD) and non-empty event text required"}), 400
    date, text = parsed
    df = _load_events()
    mask = df["event_id"] == event_id
    if not mask.any():
        return jsonify({"error": "Event not found"}), 404
    df.loc[mask, "date"] = date
    df.loc[mask, "event"] = text
    _save_events(df)
    return jsonify({"event_id": event_id, "date": date, "event": text})


@app.route("/api/events/<event_id>", methods=["DELETE"])
def api_events_delete(event_id):
    df = _load_events()
    mask = df["event_id"] == event_id
    if not mask.any():
        return jsonify({"error": "Event not found"}), 404
    df = df[~mask].reset_index(drop=True)
    _save_events(df)
    return jsonify({"deleted": event_id})


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5000))
    app.run(host="0.0.0.0", port=port, debug=False)
