<div align="center">

# Awesome HP Elite Dragonfly Chromebook (`redrix`)
### Native Linux Hardware Fixes, Root-Cause Analysis & AI Agent Workflow

[![Board](https://img.shields.io/badge/Board-Google_Redrix_(Brya)-blue)](https://mrchromebox.tech/)
[![CPU](https://img.shields.io/badge/SoC-Intel_Alder_Lake_i5--1245U-0071C5)](https://ark.intel.com/)
[![OS](https://img.shields.io/badge/OS-Fedora_44_Workstation_(GNOME_50)-51A2DA)](https://fedoraproject.org/)
[![Firmware](https://img.shields.io/badge/Firmware-MrChromebox_UEFI_2609.2-success)](https://mrchromebox.tech/)

**[English](#-english-documentation) · [简体中文](#-中文完整文档) · [中文独立文件 (README.zh-CN.md)](./README.zh-CN.md) · [Agent Workflow (AGENTS.md)](./AGENTS.md)**

</div>

---

<a id="-english-documentation"></a>

## 🇬🇧 English Documentation

Complete root-cause proofs, hardware/firmware disassembly findings, and one-click fixes for running native Linux on the **HP Elite Dragonfly Chromebook (`redrix`)** with MrChromebox UEFI Full ROM.

> **For AI Coding Agents**: If you are an automated agent tasked with provisioning this laptop or restoring fixes after a system reinstall, read **[`AGENTS.md`](./AGENTS.md)** first for the structured `Pre-check → Apply → Verify` workflow.

### Tested Environment

| Component | Specification |
| :--- | :--- |
| **Device / Board** | HP Elite Dragonfly Chromebook (`redrix`, Brya family, HWID `REDRIX-CLQY`) |
| **CPU / Platform** | Intel Core i5-1245U (12th Gen Alder Lake-P) |
| **Firmware** | MrChromebox `2609.2` UEFI Full ROM · EC RW `redrix_v2.0.27867` (Nuvoton NPCX993F) |
| **OS & Kernel** | Fedora 44 Workstation · Linux `7.2.11` / `7.2.13` · GNOME `50.6` |
| **Audio Stack** | SOF Firmware `2.2.0` (`sof-adl-max98390-rt5682.tplg`) · PipeWire `1.6.10` · WirePlumber `0.5.18` · `alsa-ucm` `1.2.16` |
| **Camera Stack** | OV5675 (MIPI CSI) → Intel IPU6 (`8086:465d`) → `libcamera` `0.7.2` (SoftISP) → PipeWire → Chrome Flatpak |
| **Backlight & ALS** | BOE 2678 eDP (`intel_backlight`, raw PWM `0–96000`) + TI OPT3001 (`cros-ec-light` / `iio:device0`) |

### Executive Summary (6 Independent Issues)

| # | Symptom | Root Cause | One-Line Fix |
| :-: | :--- | :--- | :--- |
| **[1](#issue-1-charging-stuck-at-8w)** | USB-PD negotiates 60W (20V/3A), but battery charging is clamped at **~8W (1024 mA)** | `thermald` writes `state=2` to `TCHG` cooling device every second → ACPI `SPPC(2)` → `CHGS(16)` → EC clamps `user_current_limit` to `16 × 64 mA = 1024 mA` | `sudo systemctl disable --now thermald` + write `0` to `TCHG` `cur_state` |
| **[2](#issue-2-missing-or-silent-built-in-microphone)** | Speakers work after audio fix, but **microphone is missing in GNOME or records silence** | Missing NHLT (`dmic_num=4` required); PipeWire 1.6 splits 4-ch DMIC into `Mic1` (live) and `Mic2` (dead DC channel), and WirePlumber defaults to `Mic2` | `./audio/install.sh` (installs SOF/WirePlumber configs & sets `Mic1` as default) |
| **[3](#issue-3-flatpak-chrome-camera-broken--green-tint)** | Camera **unavailable in Flatpak Chrome**; once enabled, image has a **heavy green tint** | Chrome PipeWire camera flag disabled + `xdg-desktop-portal-gnome` focus bug blocks prompt + `libcamera` falls back to `uncalibrated.yaml` | `./camera/install.sh` + enable `chrome://flags/#enable-webrtc-pipewire-camera` |
| **[4](#issue-4-erratic-auto-brightness--non-linear-slider)** | Auto-brightness **jumps erratically, stays blindingly bright in dark rooms, and pins GNOME slider at 100%** | `gsd-power` relative normalization bug + GNOME 50 slider acts as a fixed `+48.6%` bias + linear PWM lacks `γ = 2.2` perceptual curve + `EC_RATE=0` | `./brightness/install.sh` (udev 1Hz + logarithmic lux curve + `γ = 2.2` GNOME extension/daemon) |
| **[5](#issue-5-thunderbolt-3-dock-not-detected)** | Thunderbolt 3 dock **only charges the laptop**: no Thunderbolt device, no USB, no disk, no DP | Kernel `typec_displayport` auto-enters DP alt mode on attach → TBT3-only dock NAKs DP Configure and gets stuck, then NAKs TBT Enter/Exit; `cros_ec_typec` registers the TBT port altmode `inactive` and nothing on Fedora (no ChromeOS `typecd`) activates it | `./thunderbolt/install.sh` (udev alt mode policy: TBT3 preferred, DP fallback) |
| **[6](#issue-6-touchpad--cursor-frame-drops--initial-stroke-stutter)** | Touchpad cursor motion **feels choppy / drops frames (20–30fps-like)**, hitches after >1s idle, and occasionally skips | `i915` PSR2 Selective Fetch fails on Alder Lake-P Pipe A (`drmModeAtomicCommit -EBUSY` drops) + locking only LPSS PCI parent (`00:19.1`) leaves child `i2c_designware.5` autosuspending after 1000ms (`libinput` touch-jump discards) | `./touchpad/install.sh` (disables `i915` PSR + keeps LPSS & `i2c_designware` awake) |

### Quick Start (Apply All Fixes)

```bash
git clone git@github.com:lazysaltyfish/awesome-hp-dragonfly.git
cd awesome-hp-dragonfly

# 1. Fix 8W slow charging (disable thermald & clear EC TCHG limit)
sudo systemctl disable --now thermald
for d in /sys/class/thermal/cooling_device*; do
  [ "$(cat "$d/type" 2>/dev/null)" = "TCHG" ] && echo 0 | sudo tee "$d/cur_state"
done

# 2. Fix audio & built-in microphone (SOF DMIC + WirePlumber + default Mic1)
./audio/install.sh

# 3. Fix camera tuning & Flatpak permission
./camera/install.sh
# Also enable chrome://flags/#enable-webrtc-pipewire-camera in Chrome

# 4. Fix auto-brightness & perceptual Gamma 2.2 curve
./brightness/install.sh

# 5. Fix Thunderbolt 3 docks (Type-C alt mode policy: TBT3 > DP), then replug the dock
./thunderbolt/install.sh

# 6. Fix touchpad & cursor frame drops (disable i915 PSR + keep DesignWare I2C awake; reboot once)
./touchpad/install.sh
```

---

<a id="issue-1-charging-stuck-at-8w"></a>

### Issue 1: Charging Stuck at ~8W (EC 1024 mA Current Limit)

#### TL;DR
- **Symptom**: USB-PD negotiates 20V/3A (60W), total system input is ~20W, but battery charging current is clamped at a flat **~1024 mA (~8W)**. Rebooting, replugging the charger, switching USB-C ports, or running a 100% CPU load has no effect. Charging while powered off works normally.
- **Root Cause**: The distro's default **`thermald`** daemon is triggered by DPTF skin temperature thresholds (`TSR0`/`TSR1` at 45.05°C / 51.05°C, reached during normal use) and writes `cur_state=2` to the `TCHG` cooling device every second. The `int3403_thermal` driver translates this into ACPI `SPPC(2)` → `CHGS(16)` → ChromeOS EC sets `user_current_limit = 16 × 64 mA = 1024 mA` in EC RAM. Because the ACPI readback method `PPPC` is buggy (always returns `0` when AC is online), `thermald` thinks the state was not applied and rewrites it every second.
- **Fix**:
  ```bash
  sudo systemctl disable --now thermald
  for d in /sys/class/thermal/cooling_device*; do
    [ "$(cat "$d/type" 2>/dev/null)" = "TCHG" ] && echo 0 | sudo tee "$d/cur_state"
  done
  ```
- **Safety**: Disabling `thermald` on a Chromebook is completely safe. The ChromeOS Embedded Controller (EC) autonomously manages fan curves, `PROCHOT`, battery protection, and thermal shutdown. GNOME Power Profiles (`performance` / `balanced` / `power-saver`) remain fully functional via `tuned-ppd` → `cpufreq` EPP.

#### Root-Cause Chain & Evidence

```text
thermald (enabled by default on Fedora; Intel thermal daemon)
  │  Triggered by DPTF skin sensors TSR0/TSR1 at 45.05°C / 51.05°C
  ▼
Writes cur_state=2 to /sys/class/thermal/cooling_device15 (type=TCHG) every 1s
  │  ← Caught red-handed via ftrace kprobe on int3403_set_cur_state: caller thermald-927
  ▼
int3403_thermal driver → invokes ACPI method SPPC(2)
  │
  ▼
SPPC reads PPSS()[2][4] = 16 → invokes EC method CHGS(16)
  │  ← PPSS column [4] (24 / 16 / 8) is actually the number of 64 mA steps for CHGL
  ▼
EC firmware (charge_state.c): user_current_limit = 16 × 64 mA = 1024 mA
  │  ← requested_current = min(battery_desired_current, user_current_limit)
  ▼
Battery charging current clamped at 1024 mA (~1038 mA reported by gauge)
```

| `TCHG` State | `CHGL` Steps (× 64 mA) | Theoretical Limit | Measured Charging Current |
| :-: | :-: | :-: | :--- |
| `0` | `255` (`0xFF`) | Unlimited (`16320 mA`) | **2.4 – 4.6 A** ✓ (normal taper) |
| `1` | `24` | `1536 mA` | **1538 mA** ✓ |
| `2` | `16` | **`1024 mA`** | **987 – 1039 mA** ✓ (matches fault state) |
| `3` | `8` | `512 mA` | **530 mA** ✓ |

<details>
<summary><b>Click to expand: Diagnostic Methodology, Excluded Hypotheses & EC Tooling</b></summary>

#### Excluded Hypotheses
| Hypothesis | Evidence Ruling It Out |
| :--- | :--- |
| USB-PD negotiation / cable issue | Partner source-caps advertise 5/9/12/15/20V; contract is 20V/3A; EC `chg_input_current = 2800–3250 mA`. |
| Battery BMS low-temp derating | Direct Smart Battery read via EC I2C passthrough (`SBS 0x14`): at 28°C, BMS requests `4634 mA` while EC supplies `1024 mA`. |
| EC internal thermal throttling | EC temp sensors (44–51°C) show zero correlation with the constant 1024 mA clamp. |
| Kernel thermal governor (`step_wise`) | None of `/sys/class/thermal/thermal_zone*` bind to `TCHG`. |
| MrChromebox EC RW firmware bug | EC charge control is normal (`mode=NORMAL, sustain=-1/-1`); limit originates from host ACPI writes. |

#### Reproducible Diagnostic Steps (ftrace kprobe)
```bash
# 1. Locate TCHG cooling device
grep -l TCHG /sys/class/thermal/cooling_device*/type

# 2. Catch the process writing to TCHG using ftrace kprobe
echo 'p:tchg int3403_set_cur_state state=%si:u64' | sudo tee /sys/kernel/debug/tracing/kprobe_events
echo 1 | sudo tee /sys/kernel/debug/tracing/events/kprobes/tchg/enable
sudo cat /sys/kernel/debug/tracing/trace | grep tchg:
# Output shows TASK-PID = thermald

# 3. Inspect EC state directly via ./tools/ectool.py
sudo python3 ./tools/ectool.py
sudo python3 ./tools/ectool.py --csv
```

#### Bonus: USB-C DisplayPort Alt-Mode No Video After Suspend
- **Symptom**: USB-C monitor charges the laptop but shows no video signal after a long session or suspend/resume.
- **Cause**: Kernel module initialization order between `cros_ec_typec` and `intel_pmc_mux` (Red Hat Bugzilla #2192574).
- **Permanent Fix**:
  ```bash
  echo 'softdep cros_ec_typec pre: intel_pmc_mux' | sudo tee /etc/modprobe.d/cros-typec.conf
  sudo dracut -f
  ```

</details>

---

<a id="issue-2-missing-or-silent-built-in-microphone"></a>

### Issue 2: Missing or Silent Built-in Microphone (`sof-rt5682` DMIC)

#### TL;DR
- **Symptom**: After installing standard Chromebook audio fixes, speakers and headphones work, but GNOME Settings → Sound shows no input device, or selects **"Built-in Microphone 2"** which produces flat silence.
- **Root Cause (Two Independent Layers)**:
  1. **Missing NHLT table in UEFI firmware**: Kernel logs `DMICs detected in NHLT tables: 0`. Without `options snd_sof_intel_hda_generic dmic_num=4`, the 4-channel DMIC PCM (`hw:0,99`) is never created.
  2. **Dead DC channel selected by default**: PipeWire 1.6's `api.alsa.split` splits the 4-channel DMIC (`hw:0,99`) into two stereo sources: `HiFi__Mic1__source` (`AUX0/1`) and `HiFi__Mic2__source` (`AUX2/3`). Per-channel waveform analysis proves **only `Mic1` (`ch0/1`) is wired to physical microphones**, while `Mic2` (`ch2/3`) outputs a constant ~50% full-scale DC offset (`1.03e9` in `S32_LE`). Both routes have priority `100`, and WirePlumber picks `Mic2` by default.
  3. **GNOME Settings UI cache**: `libgnome-volume-control` caches the PulseAudio device list per session; logging out and back in refreshes the UI.
- **Fix**:
  ```bash
  ./audio/install.sh
  # Optional: also hide the dead Mic2 source from UI
  ./audio/install.sh --hide-mic2
  ```

#### Audio Configuration Files (`./audio/`)

| Target Path | Repo File | Purpose |
| :--- | :--- | :--- |
| `/etc/modprobe.d/adl-sof.conf` | `audio/adl-sof.conf` | `options snd_sof_intel_hda_generic dmic_num=4` — forces SOF to expose 4-ch DMIC PCM (`hw:0,99`) when NHLT is absent. |
| `/etc/wireplumber/wireplumber.conf.d/51-disable-pro-audio.conf` | `audio/51-disable-pro-audio.conf` | Sets `api.acp.disable-pro-audio = true` on `sof/avs/acp` cards so UCM profiles are used instead of raw Pro Audio. |
| `/etc/wireplumber/wireplumber.conf.d/51-increase-headroom.conf` | `audio/51-increase-headroom.conf` | Sets `api.alsa.headroom = 2048` on `alsa_output.*` to prevent audio crackling/underruns. |
| `/etc/wireplumber/wireplumber.conf.d/52-disable-mic2.conf` *(Optional)* | `audio/52-disable-mic2.conf` | Disables the dead `HiFi__Mic2__source` node (`--hide-mic2`). |

<details>
<summary><b>Click to expand: 4-Channel Hardware Liveness Test</b></summary>

```bash
arecord -D hw:0,99 -f S32_LE -r 48000 -c 4 -d 3 /tmp/dmic.wav
python3 - <<'EOF'
import wave, array
w = wave.open('/tmp/dmic.wav', 'rb')
a = array.array('i')
a.frombytes(w.readframes(w.getnframes()))
for c in range(w.getnchannels()):
    v = a[c::w.getnchannels()]
    print(f'ch{c}: max={max(map(abs, v))}, avg={sum(map(abs, v)) // len(v)}')
EOF
```
- **Live channels (`ch0`, `ch1` → `Mic1`)**: `max ≫ avg` (real acoustic signal).
- **Dead channels (`ch2`, `ch3` → `Mic2`)**: `avg ≈ max ≈ 1.03e9` (constant DC voltage, no physical mic attached).

</details>

---

<a id="issue-3-flatpak-chrome-camera-broken--green-tint"></a>

### Issue 3: Flatpak Chrome Camera Broken & Green Tint (`IPU6` + `OV5675`)

#### TL;DR
- **Symptom**:
  1. Camera is completely unavailable/black in Flatpak Google Chrome, and the permission dialog never appears.
  2. Once working, the video feed has a strong green/magenta cast and washed-out colors.
- **Root Cause (Three Layers)**:
  1. **Chrome PipeWire camera backend disabled by default**: Intel IPU6 exposes 32 raw Bayer `/dev/video*` nodes that require `libcamera` SoftISP via PipeWire. Chrome's WebRTC PipeWire camera support is behind `chrome://flags/#enable-webrtc-pipewire-camera`.
  2. **`xdg-desktop-portal-gnome` focus check bug**: Logs `Only the focused app is allowed to show a system access dialog` (`xdg-desktop-portal#1338`), silently denying camera access.
  3. **Missing `ov5675.yaml` tuning in `libcamera`**: `libcamera` falls back to `uncalibrated.yaml`, guessing black level from the scene (skewing red/green gain balance) and applying an identity color matrix.
- **Fix**:
  ```bash
  # 1. Install factory-calibrated ov5675.yaml + pre-authorize Chrome Flatpak permission
  ./camera/install.sh

  # 2. In Chrome, enable the PipeWire camera flag and relaunch:
  #    chrome://flags/#enable-webrtc-pipewire-camera -> Enabled
  ```

#### Calibration Provenance & Pitfalls
- **Factory CCM & Black Level (`camera/ov5675-clean.yaml`)**:
  - Extracted directly from the official Redrix ChromeOS recovery image (`chromeos_16836.19.0_brya_recovery_stable-channel_BryaMPKeys-v23.bin`, HWID `^REDRIX-CLQY`) at `/etc/camera/ov5675.aiqb` using `camera/parse_aiqb.py` (7 illuminant CCMs from 2300K to 6441K, record ID `25`).
  - Black level `4122` (16-bit scale) measured from dark-frame RAW capture (`64.4 / 1023` in 10-bit).
- **CRITICAL WARNING — Do NOT apply old `libcamera` 8-bit scaling patches**:
  - In `libcamera >= 0.7.2`, `swstats_cpu.cpp` already scales 10-bit unpacked sums (`sum_ >>= sumShift_` with `sumShift_ = 2`). Applying the old 0.7.0 `0002-soft-stats-scale-sums-to-8-bit.patch` (used by some Dell Latitude 7320 guides) causes **double division**, pegging the red AWB gain at `4.0` and turning the image bright red.
- **Known SoftISP Limitation**:
  - Because `libcamera` Simple IPA uses a full-frame grey-world AWB algorithm, sitting in front of a bright overcast window can skew color temperature. Front indoor lighting resolves this, or see [`camera/hw-isp-recon.md`](./camera/hw-isp-recon.md) for the hardware ISP (`intel-ipu6-psys`) feasibility study.

---

<a id="issue-4-erratic-auto-brightness--non-linear-slider"></a>

### Issue 4: Erratic Auto-Brightness & Non-Linear Slider (`cros-ec-light` + GNOME 50)

#### TL;DR
- **Symptom**:
  1. With "Automatic Screen Brightness" enabled, brightness changes feel non-linear and choppy (huge jumps at the low end, barely noticeable at the high end).
  2. In dark rooms (8–10 lux), the screen stays blindingly bright (`~40000/96000` or `94640/96000`), and the **GNOME quick-settings brightness slider is pinned near 100%**.
- **Root Cause (Four Layers Proven via Binary Disassembly & Source Audit)**:
  1. **GNOME 50 (`brightnessManager.js`) turns the slider into a fixed bias without syncing its position**:
     When auto-brightness is active (`_abTarget >= 0`), `gnome-shell` computes `target = clamp(_abTarget + scale.value - 0.5, 0.0, 1.0)` and **never updates `scale.value` or the UI slider**. Because the initial backlight cached by Mutter is `94640/96000` (`scale.value = 0.986`), the top-right slider stays pinned near 100% and **permanently adds `+48.6%` (`0.986 - 0.5`) to every auto-brightness target**—so 0% target becomes ~50% brightness, and 50% target pins the panel at 100%.
  2. **`gsd-power` uses broken dynamic relative normalization**:
     Disassembly of `/usr/libexec/gsd-power` (`0x5fb8–0x625c`) confirms that on login or after any manual slider adjustment (`BrightnessChanged`), `gsd-power` sets the 100% brightness reference to `ambient_norm_value = current_lux × 1.5` and initializes the accumulator to `66.7%`. Booting or touching the slider in a dim room (2–3 lux) defines `3–4.5 lux` as 100% full-sunlight brightness!
  3. **`intel_backlight` is linear PWM (`scale: unknown`) without `γ = 2.2` perceptual correction**:
     ChromiumOS `powerd` (`internal_backlight_controller.cc`) applies a `γ ≈ 2.0–2.2` power curve (`hw = min + span × p^γ`) whenever `max_brightness >= 100`. GNOME 50 maps slider percentage 1:1 linearly to raw PWM, so 40% raw PWM (`38485/96000`) looks like ~68% perceptual brightness to the human eye.
  4. **EC ALS sensor defaults to `EC_RATE = 0` (`buffer/hwfifo_timeout = 0`)** and GNOME performs single-step instant writes without interpolation.
- **Fix**:
  ```bash
  ./brightness/install.sh
  ```

#### Architecture of `./brightness/` Fix

| Installed Target | Repo Source | Function |
| :--- | :--- | :--- |
| `/etc/udev/rules.d/99-redrix-als.rules` | `brightness/99-redrix-als.rules` | Configures `cros-ec-light` (`sampling_frequency=1.000000`, `buffer/hwfifo_timeout=1.000000` → `EC_RATE=1000ms`) and grants `0666` permission on `intel_backlight/brightness`. |
| `dconf` (`ambient-enabled = false`) | Set by `brightness/install.sh` | Disables `gsd-power`'s broken relative normalization algorithm. |
| `~/.local/share/gnome-shell/extensions/redrix-auto-brightness@local/` | `brightness/redrix-auto-brightness@local/` | **Native GNOME Shell 50 Extension**: patches `MonitorBrightnessScale` with `γ = 2.2` perceptual mapping, implements logarithmic auto-brightness with 80ms smooth ramping, synced UI slider, and `±50%` manual user bias memory. |
| `~/.config/systemd/user/redrix-auto-brightness.service` | `brightness/redrix-auto-brightness` | **Immediate Session Fallback Daemon**: provides 50ms smooth logarithmic + `γ = 2.2` auto-brightness immediately before the user logs out/in to reload GNOME Shell; automatically exits when the GNOME Shell extension becomes `ACTIVE`. |

#### Logarithmic Illuminance → Perceptual Brightness → Raw PWM Table (`γ = 2.2`)

- **Auto Curve**: `p_auto(L) = clamp(0.15 + 0.28 × log10(L + 1.2), 0.12, 1.0)`
- **Hardware Mapping**: `hw = 960 + 95040 × p^2.2`

| Environment | Sensor Illuminance (`lux`) | Perceptual Brightness (GNOME Slider) | Hardware PWM (`intel_backlight`) | Physical Duty Cycle |
| :--- | :-: | :-: | :-: | :-: |
| Pitch dark | `0 lux` | **17.2%** | `~2,940 / 96000` | 3.1% |
| Dim nightlight | `3 lux` | **32.5%** | `~8,960 / 96000` | 9.3% |
| Dim indoor room | `9 lux` | **43.2%** | `~15,970 / 96000` | 16.6% |
| Standard indoor lighting | `30 lux` | **56.8%** | `~28,480 / 96000` | 29.7% |
| Bright office | `100 lux` | **71.1%** | `~45,550 / 96000` | 47.4% |
| Window / strong indoor light | `300 lux` | **84.4%** | `~66,300 / 96000` | 69.1% |
| Direct outdoor daylight | `1000+ lux` | **100.0%** | `96,000 / 96000` | 100.0% |

---

<a id="issue-5-thunderbolt-3-dock-not-detected"></a>

### Issue 5: Thunderbolt 3 Dock Not Detected (Type-C Alt Mode Policy)

#### TL;DR
- **Symptom**: A Thunderbolt 3 dock (verified: ACASIS TBT3 NVMe dock, Intel JHL7440 Titan Ridge DD, PD ID `042b:185e`) only charges the laptop at 20V/3A. `boltctl list` is empty, `/sys/bus/thunderbolt/devices/` shows only the host routers, and neither the dock's NVMe nor its DP output appear. Changing port (left/right) or dock connector makes no difference.
- **Root Cause** (three layers):
  1. On `redrix`, the EC has `EC_FEATURE_TYPEC_REQUIRE_AP_MODE_ENTRY` (inventory bit 42): it never enters an alt mode by itself, so the AP has to ask for it. On ChromeOS, the `typecd` daemon does this (TBT/USB4 first, then DP).
  2. `cros_ec_typec` registers the TBT port altmode (`8087`) with `desc.inactive = true` (by design, like ChromeOS's "peripheral data access" toggle), but the DP port altmode (`ff01`) is active. So on every attach, the `typec_displayport` driver immediately asks the EC to enter **DP** mode.
  3. A TBT3-only dock ACKs DP Enter but NAKs DP Configure (`NAK for cmd 17`, `DP alt mode protocol failed!`) and is then stuck. A later TBT Enter request is NAKed, and so is the EC's TBT Exit retry. The EC loops `TBT attempt to enter mode → exit mode SOP failed → alt mode protocol failed!` forever. The kernel log only shows `cros-ec-typec: No valid DP mode provided` / `Configure muxes failed, err = -22`.
- **Fix**: `./thunderbolt/install.sh` installs a udev policy that does what `typecd` does on ChromeOS. It disables DP auto-entry at port level and enables the TBT port altmode. When a partner appears, it activates TBT if the partner advertises SVID `8087`; otherwise it re-enables DP and activates that (USB-C monitors keep working). When the partner is removed, port DP is disabled again.

#### Files Installed (`./thunderbolt/`)

| Path | Source | Purpose |
| :--- | :--- | :--- |
| `/etc/udev/rules.d/90-typec-mode-policy.rules` | `thunderbolt/90-typec-mode-policy.rules` | Sets port altmode `ff01` `active=no` and `8087` `active=yes` when the port altmodes register; runs the policy script (via `systemd-run`) on partner altmode add, and a reset on partner remove. |
| `/usr/local/libexec/typec-mode-policy` | `thunderbolt/typec-mode-policy` | Waits 1.5s for PD discovery, then writes `yes` to the partner's TBT altmode `active` (`typec_thunderbolt` → `cros_typec_altmode_enter` → `EC_CMD_TYPEC_CONTROL` ENTER_MODE TBT), or falls back to DP. Logs to `journalctl -t typec-mode-policy`. |

#### Verified Result
```text
$ sudo ectool usbpdmuxinfo
Port 0: USB=0 DP=0 POLARITY=NORMAL HPD_IRQ=0 HPD_LVL=0 SAFE=0 TBT=1 USB4=0
$ boltctl list
 * Intel Tamales module 2   generation: Thunderbolt 3   status: authorized
   rx/tx speed: 40 Gb/s = 2 lanes * 20 Gb/s            policy: iommu
$ lspci -tv   →  JHL7440 Thunderbolt 3 USB Controller [Titan Ridge DD 2018] + MAXIO MAP1602 NVMe (4 TB)
```
Survives reboot and replug. Tested on kernel `7.2.15-300.fc45`, EC RW `redrix_16238.2+tbt5` (MrChromebox).

#### Diagnostic Methodology (EC console via `ectool`)
`./thunderbolt/build-ectool.sh` builds a standalone ChromiumOS `ectool` into `~/.cache/chromebook-fixes/ectool`. Upstream `main` needs clang + platform2 `libec`, so the script pins `release-R105-14989.B-main`, the last pure-C version, builds it with plain gcc, and stubs out libusb. Useful commands:
```bash
sudo ~/.cache/chromebook-fixes/ectool inventory          # bit 42 = host-controlled mode entry
sudo ~/.cache/chromebook-fixes/ectool typecdiscovery 0 0 # partner Identity + SVIDs (8087 = TBT, ff01 = DP)
sudo ~/.cache/chromebook-fixes/ectool typecdiscovery 0 1 # cable eMarker (TBT speed must be >= Gen2)
sudo ~/.cache/chromebook-fixes/ectool typecstatus 0      # EC-side mux: SAFE/USB/DP/TBT/USB4
sudo ~/.cache/chromebook-fixes/ectool console            # PD state machine log (NAKs, retries)
```
> Do not use `ectool typeccontrol <port> 2 1` to force TBT on a dock that is already stuck in DP mode: it starts an endless EC retry loop. Replug, or run `typeccontrol <port> 0`, to stop it.

---

<a id="issue-6-touchpad--cursor-frame-drops--initial-stroke-stutter"></a>

### Issue 6: Touchpad / Cursor Frame Drops & Initial-Stroke Stutter (`i915` PSR2 + `i2c_designware`)

#### TL;DR
- **Symptom**: Under GNOME Wayland, moving the pointer or scrolling gently on the built-in haptic touchpad (`ELAN2703:00 04F3:323B`) feels choppy with frequent frame drops (like 20–30 fps), hitches at the start of a stroke after >1 second of idle, and occasionally skips mid-swipe.
- **Root Cause (Two Independent Layers)**:
  1. **Display / Compositor Layer (Primary) — Broken `i915` PSR2 Selective Fetch on Alder Lake-P + BOE `0x0a76` eDP**: With default parameters (`enable_psr=-1`, `enable_psr2_sel_fetch=1`), every boot logs `i915 0000:00:02.0: [drm] Selective fetch area calculation failed in pipe A`. When the desktop is mostly static and only the hardware cursor plane (`Plane 145`, without `FB_DAMAGE_CLIPS`) or small scroll regions update, Pipe A repeatedly enters/exits PSR2 sleep and recalculates selective fetch bounding boxes, missing `16.67ms` VBlank deadlines and causing `gnome-shell` to drop frames with `Page flip failed: drmModeAtomicCommit: Device or resource busy` (25+ times per session on internal `eDP-1` alone). Because the BOE `2678` panel is physically `60.001 Hz`, dropping 1–2 frames halves instantaneous smoothness to 20–30 fps.
  2. **Touchpad I2C Bus Layer (Secondary) — Locking Only the LPSS PCI Parent Leaves Child `i2c_designware.5` Autosuspending Every 1s**: Setting `ATTR{power/control}="on"` only on PCI parent `0000:00:19.1` (`intel-lpss`) leaves its child platform controller `i2c_designware.5` at `control=auto`, `autosuspend_delay_ms=1000` (measured `suspended` 85.9% of uptime; touchscreen `i2c_designware.3` 99.98%). Touching the pad after >1s idle asserts IRQ 100 while `i2c_designware.5` is clock-gated, causing initial-stroke lag and coalesced deltas that trigger `libinput error: event5 - ELAN2703:00 04F3:323B Touchpad: kernel bug: Touch jump detected and discarded.` (hitting the 5/24h log rate limit daily).
- **Fix**:
  ```bash
  ./touchpad/install.sh
  # Optional power-saving fallback (PSR1 without broken PSR2 Selective Fetch):
  # ./touchpad/install.sh --psr1
  # Uninstall: ./touchpad/install.sh --uninstall
  ```
  The DesignWare I2C runtime PM fix takes effect immediately; reboot once to activate `i915.enable_psr=0`.

#### Excluded Hypotheses

| Hypothesis | Evidence Ruling It Out |
| :--- | :--- |
| Missing `libinput` pressure thresholds (`AttrPressureRange`) dropping light touches | Inspected `/usr/share/libinput/50-system-google.quirks` and disassembled `libinput.so.10` (`1.32.0`): `[Google Chromebook Redrix]` is already built in, and `hid-haptic` marks `event5` with `INPUT_PROP_PRESSUREPAD` (`properties=0x85`), causing `libinput` to disable `ABS_MT_PRESSURE` threshold gating automatically via `libevdev_disable_event_code`. |
| Static DRRS locking the panel to its `40.002 Hz` low-refresh EDID mode | Live `libdrm` (`drmWaitVBlank`) queries after 0.5s / 1.5s / 3.0s idle confirm VBlank remains steady at `16.667 ms` (`60.00 Hz`); frame drops come from PSR2 selective fetch wake/commit stalls rather than static 40 Hz throttling. |

#### Files Installed (`./touchpad/`)

| Path | Source | Purpose |
| :--- | :--- | :--- |
| `/etc/udev/rules.d/99-touchpad-i2c-no-pm.rules` | `touchpad/99-touchpad-i2c-no-pm.rules` | Sets `ATTR{power/control}="on"` on both LPSS PCI bridges (`0000:00:19.1`, `0000:00:15.3`) and their child `platform` `i2c_designware.*` controllers so neither touchpad nor touchscreen bus autosuspends after 1000ms. |
| `/etc/modprobe.d/i915-psr.conf` + BLS `cmdline` | `touchpad/i915-psr.conf` + `grubby` | Configures `options i915 enable_psr=0` and updates `/etc/kernel/cmdline`, `/etc/default/grub`, and BLS boot entries via `grubby --update-kernel=ALL --args="i915.enable_psr=0"`. |

---

<a id="-中文完整文档"></a>

## 🇨🇳 中文完整文档

**[切换到独立中文页面 (README.zh-CN.md)](./README.zh-CN.md) · [返回顶部](#-english-documentation)**

> **给 AI Agent 的提示**：如果你是负责在新系统上恢复配置或排查问题的 Agent，请优先阅读同目录下的 **[`AGENTS.md`](./AGENTS.md)** 获取结构化的幂等执行与验证工作流。

### 测试与实证环境

| 组件 | 规格与版本 |
| :--- | :--- |
| **实测机型 / 主板** | HP Elite Dragonfly Chromebook（主板代号 `redrix`，Brya 家族，HWID `REDRIX-CLQY`） |
| **处理器** | Intel Core i5-1245U（第 12 代 Alder Lake-P） |
| **固件版本** | MrChromebox `2609.2` UEFI Full ROM · EC RW `redrix_v2.0.27867`（Nuvoton NPCX993F） |
| **系统与桌面** | Fedora 44/45 Workstation（Kernel `7.2.11`–`7.2.15`）+ GNOME `50.6` / `51.1` |
| **音频栈** | SOF 固件 `2.2.0`（`sof-adl-max98390-rt5682.tplg`）+ PipeWire `1.6.10` + WirePlumber `0.5.18` + `alsa-ucm` `1.2.16` |
| **摄像头栈** | OV5675（MIPI CSI）→ Intel IPU6（`8086:465d`）→ `libcamera` `0.7.2`（SoftISP）→ PipeWire → Chrome Flatpak |
| **背光与光线传感器** | BOE 2678 eDP 面板（`intel_backlight`，线性 PWM `0–96000`）+ TI OPT3001（`cros-ec-light` / `iio:device0`） |

### 总览（六个独立问题与一键修复）

| # | 症状 | 根因 | 修复（一行命令） |
| :-: | :--- | :--- | :--- |
| **[一](#问题一充电只有-8w)** | PD 协商 20V/3A (60W) 但充电恒定 **~8W (1024 mA)** | `thermald` 每秒经 `TCHG` 把 EC 充电限流钳死在 `16 × 64 mA = 1024 mA` | `sudo systemctl disable --now thermald` + 写 `0` 清一次 `TCHG` 残留 |
| **[二](#问题二gnome-看不到麦克风或默认麦录不到音)** | 扬声器正常，但 **GNOME 看不到麦克风或默认麦是哑的** | 固件无 NHLT 表需强制 `dmic_num=4` + PipeWire 拆出死通道 `Mic2` 且被默认选中 | `./audio/install.sh`（部署 SOF/WirePlumber 配置并设 `Mic1` 为默认） |
| **[三](#问题三flatpak-chrome-摄像头不可用与画面偏绿)** | Flatpak Chrome **摄像头不可用**；打通后**画面明显偏绿** | Chrome PipeWire camera flag 未开 + portal 焦点检查 bug + 缺原厂 `ov5675.yaml` 调校 | `./camera/install.sh` + 开启 `chrome://flags/#enable-webrtc-pipewire-camera` |
| **[四](#问题四自动屏幕亮度怪异与滑块拉满)** | 自动亮度**变化不线性、暗光下依然刺眼且右上角滑块拉满** | `gsd-power` 相对归一化缺陷 + GNOME 50 滑块固定偏移 `+48.6%` + 线性 PWM 缺 `γ = 2.2` 校正 + `EC_RATE=0` | `./brightness/install.sh`（udev 1Hz + 对数曲线 + `γ = 2.2` 扩展/服务） |
| **[五](#问题五雷电-3-扩展坞无法识别)** | 雷电 3 扩展坞**只给电脑充电**：没有 Thunderbolt 设备，硬盘、DP、USB 都不出现 | 内核 `typec_displayport` 在插入时自动进入 DP 模式 → 只支持雷电 3 的扩展坞拒绝 DP 配置并卡住，之后连 TBT 的进入和退出请求也一并拒绝；`cros_ec_typec` 把 TBT 端口模式注册为 `inactive`，Fedora 上没有 ChromeOS 的 `typecd` 去开启它 | `./thunderbolt/install.sh`（udev 模式策略：优先 TBT3，没有再用 DP） |
| **[六](#问题六触控板掉帧光标卡顿与起手粘滞)** | 触控板滑动**感觉明显掉帧（像 20–30fps）、停手 >1s 再滑起手发粘、偶发跳帧丢点** | `i915` PSR2 Selective Fetch 在 Pipe A 计算失败并频繁报 `drmModeAtomicCommit -EBUSY` 丢帧 + 仅锁 PCI 父桥未锁子设备 `i2c_designware.5`（闲置 1s 自动休眠引发 `Touch jump` 丢包） | `./touchpad/install.sh`（禁用 `i915` PSR + 保持 LPSS 与 `i2c_designware` 常驻唤醒） |

---

<a id="问题一充电只有-8w"></a>

### 问题一：充电只有 ~8W（EC 1024 mA 充电限流）

#### TL;DR
- **症状**：PD 已协商 20V/3A = 60W，但电池充电电流被钳死在恒定 `~1024 mA`（≈ 8W），重启、重插充电器、换口、跑满载均无效；关机状态下充电正常。
- **根因**：发行版自带的 **`thermald`** 被 DPTF 皮肤温度阈值（`TSR0`/`TSR1` 45.05°C / 51.05°C，日常使用即达到）触发，每秒向 `TCHG` cooling device 写 `cur_state=2`；`int3403_thermal` 驱动调用 ACPI `SPPC(2)` → `CHGS(16)` → EC 写入 `user_current_limit = 16 × 64 mA = 1024 mA`。该值保存在 EC RAM，跨主机重启不复位；且 ACPI 读回接口 `PPPC` 有缺陷（AC 在线恒返回 `0`），导致 `thermald` 每秒重复写入。
- **一键修复**：
  ```bash
  sudo systemctl disable --now thermald
  for d in /sys/class/thermal/cooling_device*; do
    [ "$(cat "$d/type" 2>/dev/null)" = "TCHG" ] && echo 0 | sudo tee "$d/cur_state"
  done
  ```
- **安全性说明**：Chromebook 上禁用 `thermald` 完全安全。风扇曲线、`PROCHOT`、充电保护、过热关机全部由 EC 独立管理；GNOME 的电源模式（性能/平衡/省电）走 `tuned-ppd` → `cpufreq` EPP，不受任何影响。

#### 根因链条与实测数据

```text
thermald（Fedora 默认启用，Intel 温控守护进程）
  │  皮肤温度热区 TSR0/TSR1 触发点 45.05/51.05°C（DSDT 定义，正常使用即达到）
  ▼
每秒写 /sys/class/thermal/cooling_device15 (type=TCHG) cur_state=2
  │  ← 由 ftrace kprobe 在 int3403_set_cur_state 上抓到现行：thermald-927
  ▼
int3403_thermal 驱动 → ACPI 方法 SPPC(2)
  │
  ▼
SPPC 取 PPSS()[2][4] = 16 → 调 EC 的 CHGS(16)
  │  ← PPSS 第 [4] 列（24/16/8）实为 CHGL 的 "64mA 步数"，第 [5] 列只是文本标注
  ▼
EC 固件 charge_state.c：user_current_limit = 16 × 64mA = 1024mA
  │  ← requested_current = min(电池期望电流, user_current_limit)
  ▼
充电电流被钳在 1024mA（电表偏移后显示 ~1038mA）
```

| `TCHG` state | `CHGL` 步数 | 理论限流 | 手动实测充电电流 |
| :-: | :-: | :-: | :--- |
| `0` | `255` (`0xFF`) | 解除（`16320 mA`） | **2.4 ~ 4.6 A** ✓ |
| `1` | `24` | `1536 mA` | **1538 mA** ✓ |
| `2` | `16` | **`1024 mA`** | **987 ~ 1039 mA** ✓（故障时的恒定值） |
| `3` | `8` | `512 mA` | **530 mA** ✓ |

<details>
<summary><b>点击展开：排除假说、诊断方法学、USB-C 显示器修复与 Agent 清单</b></summary>

#### 排除过的假说
| 假说 | 排除依据 |
| :--- | :--- |
| PD 协商/充电器/线材问题 | partner source-caps 完整（5/9/12/15/20V），合同 20V/3A；EC `chg_input_current = 2800~3250 mA` 正常 |
| 电池 BMS 低温降额 | 直读电池（EC I2C 直通，`SBS 0x14`）：凉电池（28°C）时 BMS 仍请求 `4634 mA`，而 EC 只给 `1024 mA` |
| EC 内部热限流 / 电池温度 | EC 温度传感器 44–51°C 与限流无相关性；限流值恒定不随温度波动 |
| TCHG 被内核热管理触发 | 所有 `/sys/class/thermal/thermal_zone*` 均无 cdev 绑定，`step_wise` 管不到它 |
| MrChromebox ECRW 固件 bug | EC 的 charge control 状态全程正常（`mode=NORMAL, sustain=-1/-1`）；限流写入有明确 host 侧来源 |

#### 诊断与抓现行命令（ftrace kprobe）
```bash
echo 'p:tchg int3403_set_cur_state state=%si:u64' | sudo tee /sys/kernel/debug/tracing/kprobe_events
echo 1 | sudo tee /sys/kernel/debug/tracing/events/kprobes/tchg/enable
sudo cat /sys/kernel/debug/tracing/trace | grep tchg:
```

#### 附：USB-C 显示器无视频信号修复
- **现象**：USB-C 全功能线接显示器只充电、无信号（尤其挂起恢复后）。
- **根因**：`cros_ec_typec` 与 `intel_pmc_mux` 模块加载顺序问题（RH Bugzilla #2192574）。
- **永久修复**：
  ```bash
  echo 'softdep cros_ec_typec pre: intel_pmc_mux' | sudo tee /etc/modprobe.d/cros-typec.conf
  sudo dracut -f
  ```

</details>

---

<a id="问题二gnome-看不到麦克风或默认麦录不到音"></a>

### 问题二：GNOME 看不到麦克风或默认麦录不到音

#### TL;DR
- **症状**：装完常见 audio fix 后扬声器/耳机正常，但 GNOME 设置里看不到输入设备，或默认选中的“内置麦克风 2”电平条不动、录音无声。
- **根因（两层独立问题叠加）**：
  1. **MrChromebox UEFI 固件无 NHLT 表**：内核日志报 `DMICs detected in NHLT tables: 0`，必须通过 `/etc/modprobe.d/adl-sof.conf` 强制指定 `dmic_num=4` 才会暴露 `hw:0,99` 四通道 DMIC。
  2. **默认选中了硬件未接线的 DC 死通道**：Redrix 的 DMIC PCM（`hw:0,99`）是 4 声道，PipeWire 1.6 的 `api.alsa.split` 将其拆成“内置麦克风 1”（`AUX0/1`）和“内置麦克风 2”（`AUX2/3`）。实测**只有 `Mic1` 接了物理麦克风，`Mic2` 是恒定 ~1/2 满幅的 DC 死电平**；WirePlumber 两条路由优先级相同（100），默认挑中了 `Mic2`。
  3. **GNOME 显示层缓存**：GVC（`libgnome-volume-control`）维护会话级缓存，注销重登或重开设置面板即可刷新。
- **一键修复**：
  ```bash
  ./audio/install.sh
  # 可选：同时隐藏死掉的“内置麦克风 2”
  ./audio/install.sh --hide-mic2
  ```

#### 音频修复配置文件明细（已备份于 `./audio/`）

| 系统部署位置 | 仓库文件（`audio/`） | 作用说明 |
| :--- | :--- | :--- |
| `/etc/modprobe.d/adl-sof.conf` | `adl-sof.conf` | `options snd_sof_intel_hda_generic dmic_num=4`：强制暴露 4 通道 DMIC PCM（`hw:0,99`） |
| `/etc/wireplumber/wireplumber.conf.d/51-disable-pro-audio.conf` | `51-disable-pro-audio.conf` | 设 `api.acp.disable-pro-audio=true`，防止声卡被切到 Pro Audio profile 导致路由错乱 |
| `/etc/wireplumber/wireplumber.conf.d/51-increase-headroom.conf` | `51-increase-headroom.conf` | 设 `api.alsa.headroom=2048`，加大 ALSA 缓冲防止爆音 |
| `/etc/wireplumber/wireplumber.conf.d/52-disable-mic2.conf`（可选） | `52-disable-mic2.conf` | 禁用恒定 DC 死电平的 `HiFi__Mic2__source` 节点 |

---

<a id="问题三flatpak-chrome-摄像头不可用与画面偏绿"></a>

### 问题三：Flatpak Chrome 摄像头不可用与画面偏绿（`IPU6` + `OV5675`）

#### TL;DR
- **症状**：
  1. Flatpak 版 Chrome 里摄像头黑屏/不可用，且弹不出系统授权框；
  2. 打通后画面明显偏绿/偏紫、色彩寡淡。
- **根因（三层叠加）**：
  1. **Chrome 默认关闭 PipeWire 摄像头后端**：IPU6 的 32 个 `/dev/video*` 均为原始 Bayer 节点，必须经 `libcamera` SoftISP → PipeWire 访问。
  2. **`xdg-desktop-portal-gnome` 焦点检查 bug**：日志报 `Only the focused app is allowed to show a system access dialog`（`xdg-desktop-portal#1338`），导致弹窗失败并被记为拒绝。
  3. **`libcamera` 缺少 `ov5675.yaml` 原厂校准文件**：回落到 `uncalibrated.yaml`，黑电平靠猜、无色彩校正矩阵（CCM），导致红绿增益失衡偏绿。
- **一键修复**：
  ```bash
  # 1. 部署原厂 ov5675.yaml 调校 + Flatpak 免弹窗预授权 + 重启 PipeWire
  ./camera/install.sh

  # 2. 在 Chrome 地址栏打开以下 flag 设为 Enabled 并重启浏览器：
  #    chrome://flags/#enable-webrtc-pipewire-camera
  ```

#### 关键经验与避坑指南
- **原厂校准数据来源**：从本机 HWID (`^REDRIX-CLQY`) 对应的 ChromeOS 恢复镜像 `chromeos_16836.19.0_brya_recovery_stable-channel_BryaMPKeys-v23.bin` 提取 `/etc/camera/ov5675.aiqb`，用 `camera/parse_aiqb.py` 解析出 7 组色温（2300K–6441K）CCM，并配合实测暗帧黑电平 `4122` 生成 `camera/ov5675-clean.yaml`。
- **切勿套用旧版 8-bit 缩放补丁**：`libcamera 0.7.2` 原版 `swstats_cpu.cpp` 已内置 `sum_ >>= sumShift_`（8-bit 缩放）。切勿打针对 0.7.0 的 `0002-soft-stats-scale-sums-to-8-bit.patch`，否则会造成**双重除法**，导致红通道增益顶死 `4.0`、画面通红。
- **背光场景说明**：SoftISP 采用全帧灰度世界 AWB，阴天背光（落地窗前）可能被窗外冷光带偏。开启室内前向补光即可缓解；硬件 ISP（PSYS）路线可行性勘测详见 [`camera/hw-isp-recon.md`](./camera/hw-isp-recon.md)。

---

<a id="问题四自动屏幕亮度怪异与滑块拉满"></a>

### 问题四：自动屏幕亮度怪异与滑块拉满（`cros-ec-light` + GNOME 50）

#### TL;DR
- **症状**：
  1. 开启“自动屏幕亮度”后，屏幕亮度变化极不线性（低亮度区一跳一大截、高亮度区几乎无感，且一顿一顿不丝滑）；
  2. 在夜间昏暗室内（8–10 lux）屏幕依然刺眼（硬件背光高达 `~40000/96000` 甚至 `94640/96000`），且点开 GNOME 右上角菜单看到**亮度滑块永远停在近 100% 拉满状态**。
- **根因（四层叠加，均经反汇编与源码证实）**：
  1. **GNOME 50 (`brightnessManager.js`) 将滑块改成了固定偏移量（Bias）且不再同步滑块位置**：
     开启自动亮度（`_abTarget >= 0`）后，`gnome-shell` 按 `target = clamp(_abTarget + scale.value - 0.5, 0.0, 1.0)` 计算背光，但**从不更新 `scale.value` 和右上角滑块**。本机初始背光缓存在 `94640/96000`（`0.986`），导致右上角滑块永远显示近 100%，并向所有自动亮度目标**恒定硬加 `+48.6%`（`0.986 - 0.5`）的偏置**——全黑下最低也有近 50% 亮度，自动目标一到 50% 屏幕直接 100% 拉满。
  2. **`gsd-power` 采用有缺陷的“动态相对归一化”算法**：
     反汇编 `/usr/libexec/gsd-power` 证实：刚开机登录或手动动了滑块后，`gsd-power` 会把满亮度分母设为 `ambient_norm_value = 当前 lux × 1.5`，初始目标设为 `66.7%`。若在暗光（2–3 lux）下开机或拉滑块，系统立刻把 `3–4.5 lux` 当成 100% 满亮度标准。
  3. **`intel_backlight` 是纯线性 PWM（`scale: unknown`），GNOME 未做 `γ = 2.2` 人眼幂律校正**：
     ChromeOS `powerd` 对 `max_brightness >= 100` 的面板强制使用 `hw = min + span × p^2.2` 幂律映射；而 GNOME 50 采用 1:1 线性映射，导致 40% 硬件 PWM 在暗室下人眼感知高达 ~68% 亮度。
  4. **EC 传感器默认 `EC_RATE = 0`（`buffer/hwfifo_timeout = 0`）且无平滑过渡动画**。
- **一键修复**：
  ```bash
  ./brightness/install.sh
  ```

#### 自动亮度修复组件与感知曲线对照表（`γ = 2.2`）

- **对数照度公式**：`p_auto(L) = clamp(0.15 + 0.28 × log10(L + 1.2), 0.12, 1.0)`
- **硬件 PWM 转换**：`hw = 960 + 95040 × p^2.2`

| 环境场景 | 传感器照度 (`lux`) | 感知亮度百分比（GNOME 滑块位置） | 硬件 PWM (`intel_backlight`) | 物理占空比 |
| :--- | :-: | :-: | :-: | :-: |
| 全黑关灯 | `0 lux` | **17.2%** | `~2,940 / 96000` | 3.1% |
| 极暗夜灯 | `3 lux` | **32.5%** | `~8,960 / 96000` | 9.3% |
| 昏暗室内 | `9 lux` | **43.2%** | `~15,970 / 96000` | 16.6% |
| 普通室内灯光 | `30 lux` | **56.8%** | `~28,480 / 96000` | 29.7% |
| 明亮室内办公 | `100 lux` | **71.1%** | `~45,550 / 96000` | 47.4% |
| 靠窗 / 强室内光 | `300 lux` | **84.4%** | `~66,300 / 96000` | 69.1% |
| 户外 / 阳光直射 | `1000+ lux` | **100.0%** | `96,000 / 96000` | 100.0% |

> **手动微调记忆**：任何时候手动拖动 GNOME 亮度滑块或按键盘亮度键，系统会立即停止当前渐变并记录 `userBias = 用户设定感知亮度 - 当前照度基准感知亮度`（范围 `±50%`），后续环境光变化时自动在个人偏好偏移基础上平滑调节。

<a id="问题五雷电-3-扩展坞无法识别"></a>

### 问题五：雷电 3 扩展坞无法识别（Type-C 备用模式策略）

#### TL;DR
- **现象**：雷电 3 扩展坞（实测：ACASIS 雷电 3 NVMe 扩展坞，Intel JHL7440 Titan Ridge DD，PD ID `042b:185e`）插上后只以 20V/3A 给电脑充电。`boltctl list` 为空，`/sys/bus/thunderbolt/devices/` 里只有本机的两个主机控制器，扩展坞上的 NVMe 和 DP 都不出现。换左右口、换扩展坞上的接口都没有用。
- **根因**（三层）：
  1. `redrix` 的 EC 带有 `EC_FEATURE_TYPEC_REQUIRE_AP_MODE_ENTRY`（`inventory` 第 42 位）：EC 不会自己进入任何备用模式，必须由主机下令。ChromeOS 上由 `typecd` 守护进程负责（先 TBT/USB4，再 DP）。
  2. `cros_ec_typec` 注册 TBT 端口模式（`8087`）时故意设成 `desc.inactive = true`（对应 ChromeOS 的"外设数据访问"开关），DP 端口模式（`ff01`）却是开着的。所以每次插入，`typec_displayport` 驱动都会立刻让 EC 进入 **DP** 模式。
  3. 只支持雷电 3 的扩展坞接受了 DP 进入，却拒绝 DP 配置（`NAK for cmd 17`、`DP alt mode protocol failed!`），然后卡在这个状态。之后的 TBT 进入请求被拒，EC 重试时发的 TBT 退出也被拒。EC 会无限循环 `TBT attempt to enter mode → exit mode SOP failed → alt mode protocol failed!`。内核日志里只能看到 `cros-ec-typec: No valid DP mode provided` / `Configure muxes failed, err = -22`。
- **修复**：`./thunderbolt/install.sh` 安装一套 udev 策略，做 ChromeOS 上 `typecd` 做的事。它在端口层面关掉 DP 自动进入，打开 TBT 端口模式。有设备插入时，如果设备报了 SVID `8087`，就启用 TBT；否则重新打开 DP 并启用（USB-C 显示器照常可用）。设备拔出后，再把端口的 DP 关回去。

#### 部署的文件（`./thunderbolt/`）

| 系统路径 | 仓库来源 | 作用 |
| :--- | :--- | :--- |
| `/etc/udev/rules.d/90-typec-mode-policy.rules` | `thunderbolt/90-typec-mode-policy.rules` | 端口模式注册时，把 `ff01` 设为 `active=no`、`8087` 设为 `active=yes`；设备的备用模式出现时，通过 `systemd-run` 调用策略脚本；设备拔出时执行复位。 |
| `/usr/local/libexec/typec-mode-policy` | `thunderbolt/typec-mode-policy` | 等待 1.5 秒让 PD 发现流程完成，然后往设备 TBT 模式的 `active` 写 `yes`（`typec_thunderbolt` → `cros_typec_altmode_enter` → `EC_CMD_TYPEC_CONTROL` ENTER_MODE TBT）；设备没有 TBT 时改走 DP。日志用 `journalctl -t typec-mode-policy` 查看。 |

#### 验证结果
```text
$ sudo ectool usbpdmuxinfo
Port 0: USB=0 DP=0 POLARITY=NORMAL HPD_IRQ=0 HPD_LVL=0 SAFE=0 TBT=1 USB4=0
$ boltctl list
 * Intel Tamales module 2   generation: Thunderbolt 3   status: authorized
   rx/tx speed: 40 Gb/s = 2 lanes * 20 Gb/s            policy: iommu
$ lspci -tv   →  JHL7440 Thunderbolt 3 USB Controller [Titan Ridge DD 2018] + MAXIO MAP1602 NVMe (4 TB)
```
重启和拔插后依然有效。实测环境：内核 `7.2.15-300.fc45`，EC RW `redrix_16238.2+tbt5`（MrChromebox）。

#### 诊断方法（用 `ectool` 读 EC 控制台）
`./thunderbolt/build-ectool.sh` 会编译一个独立的 ChromiumOS `ectool`，输出到 `~/.cache/chromebook-fixes/ectool`。上游 `main` 需要 clang 和 platform2 的 `libec`，所以脚本固定使用最后一个纯 C 版本 `release-R105-14989.B-main`，用 gcc 编译，并去掉了 libusb 依赖。常用命令：
```bash
sudo ~/.cache/chromebook-fixes/ectool inventory          # 第 42 位 = 由主机控制进入模式
sudo ~/.cache/chromebook-fixes/ectool typecdiscovery 0 0 # 设备身份与 SVID（8087 = TBT，ff01 = DP）
sudo ~/.cache/chromebook-fixes/ectool typecdiscovery 0 1 # 线材 eMarker（TBT 速度需 >= Gen2）
sudo ~/.cache/chromebook-fixes/ectool typecstatus 0      # EC 侧端口切换器：SAFE/USB/DP/TBT/USB4
sudo ~/.cache/chromebook-fixes/ectool console            # PD 状态机日志（NAK、重试）
```
> 扩展坞已经卡在 DP 模式时，不要用 `ectool typeccontrol <port> 2 1` 强制进入 TBT，那会让 EC 进入无限重试循环。拔插一次，或者运行 `typeccontrol <port> 0`，就能停下来。

---

<a id="问题六触控板掉帧光标卡顿与起手粘滞"></a>

### 问题六：触控板掉帧、光标卡顿与起手粘滞（`i915` PSR2 + `i2c_designware` 休眠）

#### TL;DR
- **现象**：在 GNOME Wayland 下使用内置触控板（`ELAN2703:00 04F3:323B`）移动光标或轻滑滚动时，长期感觉指针不跟手、像掉到 20–30fps 一样一卡一卡；手指停顿超过 1 秒再次滑动时起手发粘，且滑动中途偶发停顿漏帧。
- **根因（两层独立问题叠加）**：
  1. **显示合成层主因——`i915` PSR2 Selective Fetch 在 Alder Lake-P + 内置 BOE 面板（`0x0a76`）上异常**：`i915` 默认启用 `enable_psr=-1`（自动开启到 PSR2）与 `enable_psr2_sel_fetch=1`。每次开机内核必报 `i915 0000:00:02.0: [drm] Selective fetch area calculation failed in pipe A`。当桌面大体静止、仅硬件光标层（`Plane 145`，无 `FB_DAMAGE_CLIPS`）或小块区域更新时，Pipe A 频繁进出 PSR2 自刷新并重算局部抓取框，错过 `16.67ms` VBlank 窗口，导致 `gnome-shell` 大量报 `Page flip failed: drmModeAtomicCommit: Device or resource busy` 直接丢帧（内置屏物理刷新率上限为 `60.001Hz`，连丢 1–2 帧即跌至 20–30fps）。
  2. **触控总线次因——仅锁住 LPSS PCI 父设备，子平台控制器 `i2c_designware.5` 仍在 1 秒自动休眠**：如果 udev 规则只对 PCI 父桥 `0000:00:19.1`（`intel-lpss`）设 `power/control="on"`，其子设备 `i2c_designware.5` 仍保持 `control=auto`、`autosuspend_delay_ms=1000`（实测 85.9% 的运行时间处于 `suspended`；触控屏 `i2c_designware.3` 更是 99.98% 挂起）。手指停顿 >1 秒再触碰时，`ELAN2703` 先拉低中断（IRQ 100），而 `i2c_designware.5` 需唤醒恢复时钟，引发起手延迟与首包积压，进而触发 `libinput` 每天刷满限流上限的 `kernel bug: Touch jump detected and discarded.`（坐标突变包被直接丢弃）。
- **修复**：
  ```bash
  ./touchpad/install.sh
  # 可选：若想保留基础 PSR1 省电、仅关闭出 Bug 的 PSR2 Selective Fetch：
  # ./touchpad/install.sh --psr1
  # 卸载恢复默认：./touchpad/install.sh --uninstall
  ```
  执行后 I2C 控制器常驻唤醒**立即生效**；重启一次使内核参数 `i915.enable_psr=0` 生效。

#### 部署的文件（`./touchpad/`）

| 系统路径 | 仓库来源 | 作用 |
| :--- | :--- | :--- |
| `/etc/udev/rules.d/99-touchpad-i2c-no-pm.rules` | `touchpad/99-touchpad-i2c-no-pm.rules` | 同时将 LPSS PCI 父桥（`0000:00:19.1`、`0000:00:15.3`）及其下属 `platform` 子设备 `i2c_designware.*` 设为 `ATTR{power/control}="on"`，彻底阻止 1 秒自动休眠。 |
| `/etc/modprobe.d/i915-psr.conf` + BLS `cmdline` | `touchpad/i915-psr.conf` + `grubby` | 写入 `options i915 enable_psr=0` 并通过 `grubby --update-kernel=ALL --args="i915.enable_psr=0"` 同步更新 `/etc/kernel/cmdline`、`/etc/default/grub` 与 BLS 启动项。 |

---

## Repository Structure / 仓库目录结构

```text
awesome-hp-dragonfly/
├── AGENTS.md                                  # AI Agent structured workflow entrypoint (Apply & Verify)
├── README.md                                  # Bilingual documentation (English + 简体中文)
├── README.zh-CN.md                            # Standalone Simplified Chinese manual (完整中文排障与反汇编档案)
├── audio/                                     # Issue 2: SOF DMIC & WirePlumber audio configs
│   ├── install.sh                             # One-click audio & default Mic1 installer
│   ├── adl-sof.conf                           # Forces 4-ch DMIC PCM (dmic_num=4)
│   ├── 51-disable-pro-audio.conf              # Prevents auto switching to Pro Audio profile
│   ├── 51-increase-headroom.conf              # Increases ALSA headroom to prevent crackling
│   └── 52-disable-mic2.conf                   # (Optional) Hides dead DC channel Mic2
├── brightness/                                # Issue 4: Perceptual Gamma 2.2 & ALS auto-brightness
│   ├── install.sh                             # One-click udev + daemon + GNOME extension installer
│   ├── 99-redrix-als.rules                    # Enables 1Hz EC_RATE & backlight write permissions
│   ├── redrix-auto-brightness                 # User-space smooth auto-brightness fallback daemon
│   ├── redrix-auto-brightness.service         # systemd user service unit
│   └── redrix-auto-brightness@local/          # Native GNOME Shell 50 extension (Gamma 2.2 + slider sync)
│       ├── metadata.json
│       └── extension.js
├── camera/                                    # Issue 3: IPU6 OV5675 SoftISP calibration & tools
│   ├── install.sh                             # One-click ov5675.yaml & Flatpak permission installer
│   ├── ov5675-clean.yaml                      # Calibrated BlackLevel + 7-illuminant CCMs (CC0-1.0)
│   ├── ov5675.aiqb                            # Factory ChromeOS AIQB calibration binary
│   ├── parse_aiqb.py                          # AIQB -> libcamera SoftISP YAML parser
│   └── hw-isp-recon.md                        # Intel IPU6 hardware ISP (PSYS) feasibility study
├── thunderbolt/                               # Issue 5: Type-C alt mode policy (TBT3 > DP) & EC tools
│   ├── install.sh                             # One-click udev policy installer (--uninstall to remove)
│   ├── 90-typec-mode-policy.rules             # Port altmode defaults + partner add/remove hooks
│   ├── typec-mode-policy                      # Enters TBT3 if offered, else DP (mimics ChromeOS typecd)
│   ├── build-ectool.sh                        # Builds standalone ChromiumOS ectool (R105, gcc only)
│   └── comm-usb-stub.c                        # libusb stub so ectool builds without libusb-devel
├── touchpad/                                  # Issue 6: i915 PSR disable & DesignWare I2C runtime PM fix
│   ├── install.sh                             # One-click udev + grubby/modprobe installer (--psr1 / --uninstall)
│   ├── 99-touchpad-i2c-no-pm.rules            # Keeps LPSS PCI bridges & child i2c_designware.* controllers awake
│   └── i915-psr.conf                          # Disables broken PSR2 Selective Fetch (options i915 enable_psr=0)
└── tools/                                     # Issue 1: ChromeOS EC & battery diagnostic tools
    ├── ectool.py                              # Direct /dev/cros_ec ioctl diagnostic utility
    ├── batt_logger.sh                         # Per-minute battery/EC CSV logger
    ├── drain_battery.sh                       # Forced battery discharge test script
    └── charge_log_snapshot_20261027.csv       # Verification telemetry snapshot
```
