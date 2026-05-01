# Flash WLED to the SnowFroc 2026 Badge

@description Flash WLED firmware to the SnowFroc 2026 ESP32-S3 badge. Handles prerequisites, firmware backup, erase, flash, config restore, and revert. Run from the workspace directory containing wled_backup.sh.

Execute each step in order using the Bash tool. Between steps that require the user to put the badge in download mode, output the button instructions as text and wait for the user to confirm before running the command. Do not stop between steps unless a step requires physical user action or a safety gate fails.

---

## Context

- **Chip**: ESP32-S3, 16 MB physical flash
- **Flash mode**: QSPI — always use the `_4M_qspi` binary variant, never `_opi`
- **Baud rates**: 921600 for reads, 460800 for writes
- **Port file**: `.wled-port` persists the detected serial port across steps
- **Container constraint**: USB passthrough must be configured at container start time; the Wi-Fi step must be performed from the host OS

---

## Prerequisites

Check if `dialout` is active in the current session:

```bash
id -nG | tr ' ' '\n' | grep -q '^dialout$' && echo "dialout: ok" || echo "dialout: MISSING"
```

If `dialout: MISSING`:

```bash
sudo usermod -aG dialout "$USER"
echo "Added $USER to dialout. Open a new terminal and re-run /flash-wled-snowfroc-2026-badge."
```

Stop here. Tell the user to open a new terminal before continuing — `usermod` takes effect in new sessions only. Do not proceed until the group check passes.

Check if esptool is installed. Only install if missing:

```bash
if command -v esptool >/dev/null 2>&1; then
  esptool version
  echo "esptool already installed"
else
  uv tool install esptool
  export PATH="$HOME/.local/bin:$PATH"
  esptool version
fi
```

Check if the WLED binary is already present. Only download if missing:

```bash
ls WLED_*_ESP32-S3_4M_qspi.bin 2>/dev/null | head -1
```

If no binary is found:

```bash
curl -s https://api.github.com/repos/Aircoookie/WLED/releases/latest \
  | python3 -c "
import json, sys
assets = json.load(sys.stdin)['assets']
url = next(a['browser_download_url'] for a in assets if 'ESP32-S3_4M_qspi' in a['name'])
print(url)
" | xargs curl -LO
ls -lh WLED_*_ESP32-S3_4M_qspi.bin
```

---

## Step 0 — Detect port

Check for devcontainer environment:

```bash
[[ -f /.dockerenv ]] || [[ -n "${REMOTE_CONTAINERS:-}" ]] && echo "DEVCONTAINER" || echo "HOST"
```

If in a devcontainer, tell the user:
> You are in a devcontainer. USB passthrough must have been configured before the container started (`--device` in `devcontainer.json` only applies at start time). Step 5 (WiFi) must be performed from the host OS.

Detect the port:

```bash
PORT=$(ls /dev/ttyUSB* 2>/dev/null | head -1)
[[ -z "$PORT" ]] && { echo "No device found — check USB cable and power switch"; exit 1; }
echo "Using port: $PORT"
echo "$PORT" > .wled-port
```

If detection fails, tell the user to check: USB-C data cable is connected, the power switch on the back of the badge is in the "On" position, and (if in a devcontainer) the container was started with the badge already plugged in.

---

## Step 1 — Back up the original firmware

Check for a valid existing backup:

```bash
if [[ -f esp32s3_flash_16mb.bin ]] && \
   [[ $(stat -c%s esp32s3_flash_16mb.bin) -eq 16777216 ]]; then
  echo "Valid backup already exists ($(stat -c%s esp32s3_flash_16mb.bin) bytes), skipping dump"
fi
```

If no valid backup exists, tell the user:
> **Physical action required:** Hold **BOOT**, tap **EN/RST**, release **BOOT** to enter download mode. Confirm when done.

After the user confirms:

```bash
PORT=$(cat .wled-port)
esptool \
  --chip esp32s3 \
  --port "$PORT" \
  --baud 921600 \
  read-flash 0x0 0x1000000 esp32s3_flash_16mb.bin
```

Verify the backup immediately — do not proceed if this fails:

```bash
[[ -f esp32s3_flash_16mb.bin ]] && \
  [[ $(stat -c%s esp32s3_flash_16mb.bin) -eq 16777216 ]] \
  || { echo "Backup failed — file missing or wrong size; do not proceed"; exit 1; }
echo "Backup verified: $(stat -c%s esp32s3_flash_16mb.bin) bytes"
```

---

## Step 2 — Extract bootloader and partition table

This step works entirely from the dump file — no device connection needed.

Check if already extracted:

```bash
[[ -s bootloader.bin ]] && [[ -s partitions.bin ]] && \
  echo "bootloader.bin and partitions.bin already exist, skipping"
```

If not:

```bash
python3 -c "
data = open('esp32s3_flash_16mb.bin','rb').read()
open('bootloader.bin','wb').write(data[0x0:0x8000])
open('partitions.bin','wb').write(data[0x8000:0x9000])
"
[[ -s bootloader.bin ]] && [[ -s partitions.bin ]] \
  || { echo "Extraction failed — check esp32s3_flash_16mb.bin is present and complete"; exit 1; }
echo "Extracted bootloader.bin and partitions.bin"
```

---

## Step 3 — Erase the flash

**Hard gate** — verify backup before erasing. Do not continue if this fails:

```bash
[[ -f esp32s3_flash_16mb.bin ]] && \
  [[ $(stat -c%s esp32s3_flash_16mb.bin) -eq 16777216 ]] \
  || { echo "Valid backup not found — refusing to erase; complete Step 1 first"; exit 1; }
echo "Backup confirmed, proceeding with erase"
```

Tell the user:
> **Physical action required:** Hold **BOOT**, tap **EN/RST**, release **BOOT** to enter download mode. Confirm when done.

After confirmation:

```bash
PORT=$(cat .wled-port)
esptool --chip esp32s3 --port "$PORT" erase-flash
```

---

## Step 4 — Flash WLED

Verify the binary is present:

```bash
WLED_BIN=$(ls WLED_*_ESP32-S3_4M_qspi.bin 2>/dev/null | head -1)
[[ -n "$WLED_BIN" ]] || { echo "WLED binary not found — run the Prerequisites step first"; exit 1; }
echo "Will flash: $WLED_BIN"
```

Tell the user:
> **Physical action required:** Hold **BOOT**, tap **EN/RST**, release **BOOT** to enter download mode. Confirm when done.

After confirmation:

```bash
PORT=$(cat .wled-port)
WLED_BIN=$(ls WLED_*_ESP32-S3_4M_qspi.bin 2>/dev/null | head -1)
esptool \
  --chip esp32s3 \
  --port "$PORT" \
  --baud 460800 \
  write-flash \
  0x0     bootloader.bin \
  0x8000  partitions.bin \
  0x10000 "$WLED_BIN"
```

After flashing succeeds, tell the user:
> Tap **EN/RST** to boot into WLED.

---

## Step 5 — Connect to WLED

Tell the user:
> WLED broadcasts a Wi-Fi access point on first boot. Connect from the host OS (not the container) to:
> - **SSID**: `WLED-AP`
> - **Password**: `wled1234`
>
> Confirm when connected.

After the user confirms, poll until WLED responds:

```bash
until curl -sf http://4.3.2.1/json/info >/dev/null; do echo "Waiting for WLED..."; sleep 2; done
echo "WLED is reachable at http://4.3.2.1"
```

---

## Step 6 — Restore configuration

```bash
until curl -sf http://4.3.2.1/json/info >/dev/null; do echo "Waiting for WLED..."; sleep 2; done
./wled_backup.sh restore
```

If `wled_backup.sh` is not present or fails, tell the user to enter these settings manually in the WLED UI:

**Config → LED Preferences → LED Outputs**

| Output | GPIO | Type   | Color Order | Count | Segment |
|--------|------|--------|-------------|-------|---------|
| LED 1  | 17   | WS281x | GRB         | 126   | 0       |
| LED 2  | 38   | WS281x | GRB         | 1     | 1       |

**Config → LED Preferences → 2D Configuration**

| Setting     | Value      |
|-------------|------------|
| Panels      | 1          |
| Width       | 18         |
| Height      | 7          |
| Serpentine  | off        |
| Orientation | vertical   |
| First pixel | top-left   |
| Orientation | horizontal |

---

## Revert to original firmware

If the user asks to revert or restore the original CTF firmware, follow these steps.

Verify the backup exists:

```bash
[[ -f esp32s3_flash_16mb.bin ]] \
  || { echo "Backup file not found — cannot revert"; exit 1; }
echo "Backup found: $(stat -c%s esp32s3_flash_16mb.bin) bytes"
```

Tell the user:
> **Physical action required:** Hold **BOOT**, tap **EN/RST**, release **BOOT** to enter download mode. Confirm when done.

After confirmation:

```bash
PORT=$(cat .wled-port)
esptool \
  --chip esp32s3 \
  --port "$PORT" \
  --baud 460800 \
  write-flash 0x0 esp32s3_flash_16mb.bin
```

The restored image includes the original NVS partition with RF calibration data and the factory Wi-Fi AP config (`SnowFroc-8D1678` / `ctfbadge2026`).
