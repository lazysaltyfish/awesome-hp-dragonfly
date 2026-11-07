# Agent Workflow Guide (`chromebook-fixes`)

This repository contains verified hardware/desktop fixes and diagnostic tools for Linux (Fedora Workstation / GNOME) running on **HP Elite Dragonfly Chromebook (`redrix`, Intel Alder Lake)** or similar ChromeOS devices with MrChromebox UEFI firmware.

## Operating Rules for Agents

1. **Choose the right mode**:
   - **Workflow A (Apply / Provisioning)**: When the user asks to "set up the laptop", "apply the fixes", or "restore configuration after a reinstall", execute **Workflow A** below. **Do NOT run destructive or slow diagnostic experiments** (such as forcing `TCHG=2`, draining the battery, or capturing 60 raw PPM frames) unless verification fails.
   - **Workflow B (Diagnose / Porting)**: When a fix does not work as expected or the user is on a different Chromebook board, consult `README.md` for root-cause proofs and diagnostic methodology.
2. **Use repository-relative paths**: Never assume this repo is cloned at `~/chromebook-fixes`. Always resolve paths relative to the repository root (`REPO_DIR="$(pwd)"`).
3. **Never apply obsolete libcamera 8-bit scaling patches**: On `libcamera >= 0.7.2`, `swstats_cpu` already shifts 10-bit unpacked stats (`sum_ >>= sumShift_`). Applying old 0.7.0 `0002-soft-stats-scale-sums-to-8-bit.patch` causes double division and extreme red tint.

---

## Workflow A: Idempotent Setup (Apply & Verify All Fixes)

Run from the root of this repository (`cd <repo-root>`).

### Step 1: Fix 8W Slow Charging (`thermald` → `TCHG` EC Current Limit)

- **Pre-check**:
  ```bash
  systemctl is-active thermald || true
  grep -l TCHG /sys/class/thermal/cooling_device*/type || true
  ```
- **Apply**:
  ```bash
  sudo systemctl disable --now thermald
  for d in /sys/class/thermal/cooling_device*; do
    [ "$(cat "$d/type" 2>/dev/null)" = "TCHG" ] && echo 0 | sudo tee "$d/cur_state"
  done
  ```
- **Verify**:
  - `systemctl is-enabled thermald` returns `disabled` or `not-found`.
  - Optional EC verification: `sudo python3 ./tools/ectool.py --csv` (first column `chg_current_mA` should match fourth column `bms_charging_current_mA`, e.g., `~4608` when AC is connected and battery SOC is 20–80%).

---

### Step 2: Fix Audio & Built-in Microphone (`sof-rt5682` DMIC + WirePlumber)

- **Pre-check**:
  ```bash
  cat /proc/asound/cards
  pactl get-default-source || true
  ```
- **Apply**:
  ```bash
  ./audio/install.sh
  # Optional: pass --hide-mic2 to hide the dead DC channel (Built-in Microphone 2)
  # ./audio/install.sh --hide-mic2
  ```
  *Note: If `/etc/modprobe.d/adl-sof.conf` (`options snd_sof_intel_hda_generic dmic_num=4`) was not present before running `./audio/install.sh`, a reboot is required for the kernel to expose `hw:0,99` (4-channel DMIC), followed by re-running `./audio/install.sh`.*
- **Verify**:
  - `arecord -l` lists `device 99: DMIC (*) []`.
  - `pactl get-default-source` outputs `alsa_input.pci-0000_00_1f.3-platform-adl_rt5682_def.HiFi__Mic1__source`.

---

### Step 3: Fix Camera in Flatpak Chrome & Green Tint (`IPU6` + `OV5675` Tuning)

- **Pre-check**:
  ```bash
  test -f /usr/share/libcamera/ipa/simple/ov5675.yaml && echo "installed" || echo "missing"
  flatpak permission-show com.google.Chrome || true
  ```
- **Apply**:
  ```bash
  ./camera/install.sh
  ```
  - **Chrome PipeWire Flag (`#enable-webrtc-pipewire-camera`)**:
    Check if `enable-webrtc-pipewire-camera@1` is present in `~/.var/app/com.google.Chrome/config/google-chrome/Local State` under `browser.enabled_labs_experiments`.
    - If missing and Chrome is **not running**, you can insert `"enable-webrtc-pipewire-camera@1"` into `browser.enabled_labs_experiments` via Python `json`, or ask the user to enable `chrome://flags/#enable-webrtc-pipewire-camera` and relaunch Chrome.
- **Verify**:
  - `/usr/share/libcamera/ipa/simple/ov5675.yaml` exists and matches `./camera/ov5675-clean.yaml`.
  - `flatpak permission-show com.google.Chrome` shows `devices` / `camera` allowed (`yes`).

---

### Step 4: Fix Auto-Brightness & Perceptual Gamma 2.2 Curve (`cros-ec-light` + GNOME)

- **Pre-check**:
  ```bash
  grep -H . /sys/class/backlight/intel_backlight/{type,brightness,max_brightness,scale}
  gsettings get org.gnome.settings-daemon.plugins.power ambient-enabled
  ```
- **Apply**:
  ```bash
  ./brightness/install.sh
  ```
- **Verify**:
  - `gsettings get org.gnome.settings-daemon.plugins.power ambient-enabled` is `false`.
  - `grep -H . /sys/bus/iio/devices/iio:device*/{sampling_frequency,buffer/hwfifo_timeout} 2>/dev/null` shows `1.000000` on `cros-ec-light`.
  - Either `redrix-auto-brightness@local` is ACTIVE in GNOME Shell (`gnome-extensions info redrix-auto-brightness@local | grep -i state`) OR the fallback service `systemctl --user is-active redrix-auto-brightness.service` is `active` for the current session until next login.

---

### Step 5 (Optional): Fix USB-C DP Alt-Mode Monitor Hotplug Order

If USB-C external display fails to light up after suspend/resume or boot:

```bash
echo 'softdep cros_ec_typec pre: intel_pmc_mux' | sudo tee /etc/modprobe.d/cros-typec.conf
sudo dracut -f
```

---

### Step 6: Fix Thunderbolt 3 Docks Not Detected (Type-C Alt Mode Policy: TBT3 > DP)

- **Pre-check**:
  ```bash
  test -f /etc/udev/rules.d/90-typec-mode-policy.rules && echo "installed" || echo "missing"
  for a in /sys/class/typec/port*/port*.[0-9]; do echo "$a svid=$(cat $a/svid) active=$(cat $a/active)"; done
  ```
- **Apply**:
  ```bash
  ./thunderbolt/install.sh
  # Uninstall: ./thunderbolt/install.sh --uninstall
  ```
  Ask the user to **replug** the Thunderbolt dock afterwards (a device attached before install keeps its stale DP state).
- **Verify**:
  - Port altmodes: `ff01` (DP) is `active=no`, `8087` (TBT) is `active=yes` on every port (`/sys/class/typec/port*/port*.N`).
  - With a TBT3 dock plugged in: `journalctl -t typec-mode-policy` shows `entered TBT3 alt mode`, `boltctl list` lists the dock as `authorized`, and `/sys/bus/thunderbolt/devices/` contains a `0-1`/`1-1` device.
  - With a plain USB-C DP monitor (no `8087` SVID): the log shows `entered DP alt mode` and the monitor lights up.

---

## Workflow B: Diagnostics & Porting to Other Chromebooks

If any verification above fails or you are diagnosing a different Chromebook board, refer to the detailed sections in `README.md`:

| Issue | Root Cause Summary | Detailed Guide & Diagnostic Commands |
|---|---|---|
| **Slow Charging (~8W)** | `thermald` writes `state=2` to `TCHG` cooling device → ACPI `SPPC(2)` → EC `user_current_limit = 1024mA` | `README.md` **问题一 (§1–§10)** + `./tools/ectool.py` |
| **Missing / Silent Mic** | Missing NHLT (`dmic_num=4` needed) + PipeWire splits 4ch DMIC into `Mic1` (live) and `Mic2` (dead DC) | `README.md` **问题二 (§A–§F)** |
| **Camera Broken / Green** | IPU6 requires PipeWire camera flag + portal focus bug + missing `ov5675.yaml` BlackLevel/CCM | `README.md` **问题三 (§A–§F)** + `./camera/parse_aiqb.py` |
| **Auto-Brightness Broken** | `gsd-power` relative normalization bug + GNOME 50 slider bias (`+0.5`) + linear PWM lacking $\gamma=2.2$ | `README.md` **问题四 (§A–§E)** |
| **TBT3 Dock Not Detected** | Kernel `typec_displayport` auto-enters DP on attach (TBT3-only dock NAKs DP Configure, then NAKs TBT Enter/Exit); `cros_ec_typec` registers TBT port altmode `inactive` and nothing (no `typecd`) activates it | `README.md` **Issue 5 / 问题五** + `./thunderbolt/build-ectool.sh` (EC `console`) |

## Repository Layout

```
.
├── AGENTS.md                                  # Structured workflow entrypoint for AI agents
├── README.md                                  # Deep-dive root cause analysis, disassembly & manual
├── audio/                                     # Issue 2: SOF DMIC & WirePlumber configs
│   ├── install.sh
│   ├── adl-sof.conf
│   ├── 51-disable-pro-audio.conf
│   ├── 51-increase-headroom.conf
│   └── 52-disable-mic2.conf
├── brightness/                                # Issue 4: Perceptual Gamma 2.2 & ALS auto-brightness
│   ├── install.sh
│   ├── 99-redrix-als.rules
│   ├── redrix-auto-brightness
│   ├── redrix-auto-brightness.service
│   └── redrix-auto-brightness@local/
│       ├── metadata.json
│       └── extension.js
├── camera/                                    # Issue 3: IPU6 OV5675 SoftISP calibration & tools
│   ├── install.sh
│   ├── ov5675-clean.yaml
│   ├── ov5675.aiqb
│   ├── parse_aiqb.py
│   └── hw-isp-recon.md
├── thunderbolt/                               # Issue 5: Type-C alt mode policy (TBT3 > DP) & EC tools
│   ├── install.sh
│   ├── 90-typec-mode-policy.rules
│   ├── typec-mode-policy
│   ├── build-ectool.sh
│   └── comm-usb-stub.c
└── tools/                                     # Issue 1: ChromeOS EC & battery diagnostic tools
    ├── ectool.py
    ├── batt_logger.sh
    ├── drain_battery.sh
    └── charge_log_snapshot_20261027.csv
```
