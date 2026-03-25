# Viatom ER1-W BLE Protocol Reference

Device: **ER1-W 0780**
BLE Address: `FF:78:2B:D6:01:8B`
Chip: Nordic BLE (DFU service present)
Form factor: Chest strap, single-lead ECG

---

## GATT Services Overview

The device exposes three BLE services:

| Service | UUID | Description |
|---|---|---|
| Viatom Custom | `14839ac4-7d7e-415c-9a42-167340cf2339` | ECG data and device control |
| Standard Heart Rate | `0000180d-0000-1000-8000-00805f9b34fb` | BLE Heart Rate Profile |
| Nordic DFU | `0000fe59-0000-1000-8000-00805f9b34fb` | Firmware update (do not use) |

---

## Service 1: Viatom Custom ECG Service

**Service UUID:** `14839ac4-7d7e-415c-9a42-167340cf2339`

### Characteristics

| Characteristic | UUID | Properties | Description |
|---|---|---|---|
| Write | `8b00ace7-eb0b-49b0-bbe9-9aee0a26e1a3` | write-without-response | Send commands to device |
| Notify | `0734594a-a8e7-4b1a-a6b1-cd5243059a57` | notify | Receive ECG data and responses |

### Packet Frame Format

All command and response packets use the same framing:

```
[0xA5][CMD][~CMD][0x00][SEQ][LEN_L][LEN_H][PAYLOAD...][CRC8]
```

| Byte(s) | Field | Description |
|---|---|---|
| 0 | Start | Always `0xA5` |
| 1 | CMD | Command code |
| 2 | ~CMD | Bitwise NOT of CMD — integrity check |
| 3 | Reserved | `0x00` in requests; device sends `0x01` in responses |
| 4 | SEQ | Sequence number, 0–254, auto-increments per request |
| 5–6 | LEN | Payload length, uint16 little-endian |
| 7…N | PAYLOAD | Command-specific data |
| N+1 | CRC8 | CRC-8/SMBUS (poly=0x07) over all preceding bytes |

**CRC:** CRC-8/SMBUS with polynomial `0x07` (not CRC-8/MAXIM `0x31`).

### Commands

| CMD | Hex | Name | Payload | Description |
|---|---|---|---|---|
| `CMD_GET_VIBRATE_CONFIG` | `0x00` | getVibrateConfig | none | Query vibration settings; sent first on connect |
| `CMD_RT_DATA` | `0x03` | getRtData | `[0x7D]` | Start/keep-alive real-time ECG at 125 Hz |
| `CMD_SET_VIBRATE` | `0x04` | setVibrateConfig | — | Set vibration (not used in normal operation) |
| `CMD_RT_RRI` | `0x07` | getRtRri | `[0xFA]` | Poll RR interval (repeat every 100 ms) |
| `CMD_GET_INFO` | `0xE1` | getInfo | none | Query device info (model, firmware, serial) |
| `CMD_SYNC_TIME` | `0xEC` | syncTime | 7 bytes (see below) | Set device clock |

#### syncTime payload (7 bytes)

| Byte | Field | Example (2026-03-25 14:30:00) |
|---|---|---|
| 0 | year low byte | `0xEA` |
| 1 | year high byte | `0x07` |
| 2 | month | `0x03` |
| 3 | day | `0x19` |
| 4 | hour | `0x0E` |
| 5 | minute | `0x1E` |
| 6 | second | `0x00` |

Year is a full 2-byte little-endian integer (e.g. 2026 = `0x07EA`), **not** a year-2000 offset.

### BLE Fragmentation

The device splits large responses (~286 bytes) across 2–3 BLE notifications (MTU ≈ 247 bytes). The reassembly buffer in [er1_client.py](er1_client.py) accumulates fragments and parses complete `0xA5`-framed packets.

Common split patterns observed: `244+42`, `153+133`, `93+193`, `29+244+13`, `221+65`, `157+129`.

### Startup Sequence

Must be sent in order after connecting and subscribing to the notify characteristic:

```
1. getVibrateConfig  (CMD 0x00, no payload)
2. getInfo           (CMD 0xE1, no payload)
3. syncTime          (CMD 0xEC, 7-byte payload)
4. getRtData         (CMD 0x03, payload [0x7D])
```

Then re-send `getRtData` every **1 second** to keep the ECG stream alive (SDK polling pattern).

---

## Service 2: Standard Heart Rate Profile

**Service UUID:** `0000180d-0000-1000-8000-00805f9b34fb`

### Characteristics

| Characteristic | UUID | Properties | Description |
|---|---|---|---|
| Heart Rate Measurement | `00002a37-0000-1000-8000-00805f9b34fb` | notify | Auto-streams BPM at ~1 Hz |

### Heart Rate Measurement Packet Format

Standard [Bluetooth Heart Rate Measurement](https://www.bluetooth.com/specifications/assigned-numbers/) format:

```
[FLAGS][BPM_L][BPM_H (optional)]...
```

| Byte | Field | Description |
|---|---|---|
| 0 | Flags | Bit 0: `0` = BPM is uint8; `1` = BPM is uint16 LE |
| 1 | BPM | Heart rate in beats per minute (uint8 if flags bit 0 = 0) |
| 1–2 | BPM | Heart rate in beats per minute (uint16 LE if flags bit 0 = 1) |

**No command needed** — the device streams BPM automatically once subscribed. Observed values: 49–70 BPM at ~1 Hz cadence.

---

## ECG Data Stream

ECG data arrives via the Viatom custom notify characteristic in response to `getRtData` (CMD `0x03`).

### Response Packet

```
Total size: 286 bytes
  [7-byte frame header][278-byte payload][1-byte CRC]
```

### Payload Layout (278 bytes)

| Bytes | Field | Description |
|---|---|---|
| 0 | `battery_pct` | Battery percentage 0–100 (oscillates ±4 each second — use with caution) |
| 1 | `battery_state` | `0`=Not charging, `1`=Charging, `2`=Full, `3`=Low |
| 2–9 | Internal | Block counter, flags; byte 4 increments by 256 each second |
| 10 | `record_time` | Seconds elapsed, increments by 1/s |
| 11–21 | Reserved | Zeros / other status |
| 22–277 | ECG samples | 128 × int16 little-endian samples @ 125 Hz |

### ECG Signal

| Property | Value |
|---|---|
| Sample rate | 125 Hz (128 samples per packet = 1.024 s) |
| Sample type | int16 little-endian |
| Scale | `mV = sample × 0.002467` |
| Typical range | −0.62 to +1.55 mV |
| QRS amplitude | ~1.5–1.75 mV |
| Packets arrive | ~1 Hz (one 286-byte packet per second) |

### Device Status Codes

| Code | Status |
|---|---|
| 0 | Idle |
| 1 | Preparing |
| 2 | Measuring |
| 3 | Saving |
| 4 | Saved |
| 5 | Too short (<30 s) |
| 6 | Max retests |
| 7 | Lead disconnected |

---

## Service 3: Nordic DFU

**Service UUID:** `0000fe59-0000-1000-8000-00805f9b34fb`

Used for over-the-air firmware updates via the Nordic Semiconductor DFU protocol. Not used in normal operation.

---

## Connection Summary

```
On connect:
  Subscribe → Viatom notify char  (0734594a...)    ECG + responses
  Subscribe → HR notify char      (00002a37...)    BPM auto-streams

Send startup sequence:
  → getVibrateConfig  A5 00 FF 00 [SEQ] 00 00 [CRC]
  → getInfo           A5 E1 1E 00 [SEQ] 00 00 [CRC]
  → syncTime          A5 EC 13 00 [SEQ] 07 00 [year_lo year_hi mm dd hh mm ss] [CRC]
  → getRtData         A5 03 FC 00 [SEQ] 01 00 7D [CRC]

Every 1 second:
  → getRtData         (repeat to keep stream alive)

Receive every ~1 second:
  ← 286-byte ECG packet (Viatom notify) — 128 int16 samples + status header
  ← 2-byte HR packet    (HR notify)     — current BPM
```

---

## Example Packet: getRtData Request

```
A5 03 FC 00 00 01 00 7D [CRC]
│  │  │  │  │  └──┘ └─ payload: 0x7D = 125 Hz
│  │  │  │  └────── SEQ = 0
│  │  │  └───────── reserved = 0x00
│  │  └──────────── ~CMD = ~0x03 = 0xFC
│  └─────────────── CMD = 0x03 (getRtData)
└────────────────── start byte 0xA5
```
