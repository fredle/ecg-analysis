# ECG Browser R-File Binary Format Specification

Binary format used by ECG Browser / Viatom / Vihealth Holter monitors.

---

## File Naming

| Pattern | Context |
|---|---|
| `R{YYYYMMDDHHMMSS}` | Import folder |
| `{device_id}R{YYYYMMDDHHMMSS}` | Device userfiles folder |

The 14-digit timestamp at the end of the filename encodes the recording start time (local device time). Example: `R20260305212215` → 2026-03-05 21:22:15.

---

## Overall Structure

```
[ Header: 9 bytes ][ Data section: variable length ]
```

Minimum valid file size: **12 bytes** (9-byte header + 3-byte data minimum for one sync point sample).

---

## Header (9 bytes)

| Offset | Size | Field | Observed Value | Description |
|---|---|---|---|---|
| 0 | 1 byte | `version` | `0x01` | Format version |
| 1 | 1 byte | `channels` | `0x02` | Channel count (only 1 channel is decoded) |
| 2–7 | 6 bytes | `reserved` | `0x00 × 6` | Unused, always zero |
| 8 | 1 byte | `header_size` | `0x09` | Header length in bytes; must equal 9 |

**Example header bytes:** `01 02 00 00 00 00 00 00 09`

The decoder validates that `header_size == 9` and rejects the file otherwise.

---

## Data Section (variable length)

Starts immediately after the header (byte offset 9).

### Layout

| Position | Description |
|---|---|
| Data byte 0 (file offset 9) | Padding byte — always `0x00`, always skipped |
| Data byte 1 onwards | Variable-length delta-encoded sample stream |

### Delta Encoding Scheme

Each encoded unit produces exactly **one decoded sample** by updating a running accumulator.

| Byte(s) | Type | Action | Range |
|---|---|---|---|
| `0x80 LL HH` | **Absolute sync point** | `acc = signed_16bit_LE(LL, HH)` | −32768 to +32767 |
| `0x7F XX` | **Extended positive delta** | `acc += 127 + XX` | +127 to +382 |
| `0x81 XX` | **Extended negative delta** | `acc -= 127 + XX` | −127 to −382 |
| `0x00`–`0x7E` | **Small positive/zero delta** | `acc += b` | 0 to +126 |
| `0x82`–`0xFF` | **Small negative delta** | `acc += b − 256` | −126 to −1 |

> `LL HH` = two-byte little-endian signed 16-bit integer. `XX` = unsigned byte value of the following byte.

### Sync Points

Absolute sync points (`0x80`) occur:
- At the **first sample** in the stream
- Periodically every **~7500 samples** (~60 seconds at 125 Hz)

They allow a decoder to resynchronise mid-stream without replaying the entire file from the start.

---

## Signal Characteristics

| Property | Value |
|---|---|
| Sample rate | 125 Hz |
| Sample interval | 8 ms |
| Sample resolution | 16-bit signed integer |
| Channel count | 1 (single-lead ECG) |
| Byte order | Little-endian (for absolute values) |

---

## Decoding Algorithm

```python
import struct

def decode(file_data: bytes) -> list[int]:
    header_size = file_data[8]           # Must be 9
    data = file_data[header_size:]
    samples = []
    acc = 0
    i = 1                                # Skip padding byte at data[0]

    while i < len(data):
        b = data[i]

        if b == 0x80:                    # Absolute sync point
            acc = struct.unpack_from('<h', data, i + 1)[0]
            samples.append(acc)
            i += 3

        elif b == 0x7F:                  # Extended positive delta
            acc += 127 + data[i + 1]
            samples.append(acc)
            i += 2

        elif b == 0x81:                  # Extended negative delta
            acc -= 127 + data[i + 1]
            samples.append(acc)
            i += 2

        else:                            # Small signed delta
            acc += b - 256 if b > 127 else b
            samples.append(acc)
            i += 1

    return samples
```

---

## Annotated Hex Example

```
Offset  Bytes              Description
------  -----------------  ----------------------------------
0       01                 version = 1
1       02                 channels = 2
2–7     00 00 00 00 00 00  reserved
8       09                 header_size = 9
9       00                 padding byte (skipped)
10      80 de 00           absolute sync: acc = 0x00DE = 222
13      04                 small delta: acc = 222 + 4 = 226
14      7F 1A              extended +delta: acc = 226 + 127 + 26 = 379
16      81 0A              extended -delta: acc = 379 − 127 − 10 = 242
18      F8                 small -delta: acc = 242 + (0xF8−256) = 242 − 8 = 234
```

---

## File Locations (ECG Browser on Windows)

| Purpose | Path |
|---|---|
| Import folder | `%LOCALAPPDATA%\ECG Browser\DATA\import\` |
| Device userfiles | `%LOCALAPPDATA%\ECG Browser\DATA\userfiles\subusr\1\` |
| File pattern | `R\d{14}` (regex) |
