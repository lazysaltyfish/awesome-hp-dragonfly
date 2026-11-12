<div align="center">

# HP Elite Dragonfly Chromebook (`redrix`) Linux 完整修复手册
### 充电限流 · 音频麦克风 · IPU6 摄像头调校 · 自动亮度感知曲线 · 雷电 3 扩展坞 · 触控板与显示防掉帧

**[🇬🇧 English / Bilingual Overview (README.md)](./README.md) · [🤖 AI Agent 工作流 (AGENTS.md)](./AGENTS.md)**

</div>

---

## 测试环境与适用范围

| 项目 | 详细规格 |
| :--- | :--- |
| **适用范围** | 刷入 MrChromebox UEFI 固件或安装原生 Linux 的 ChromeOS 设备（特别是 Brya 家族） |
| **实测机型** | HP Elite Dragonfly Chromebook（主板：`redrix`，Alder Lake i5-1245U，HWID：`REDRIX-CLQY`） |
| **操作系统** | Fedora 44/45 Workstation（Kernel `7.2.11`–`7.2.15`）+ MrChromebox `2609.2` UEFI Full ROM |
| **音频环境** | SOF 固件 `2.2.0` + PipeWire `1.6.10` + WirePlumber `0.5.18` + `alsa-ucm` `1.2.16` + GNOME `50.6` / `51.1` |
| **摄像头环境** | `libcamera` `0.7.2-2.fc44` + `pipewire-plugin-libcamera` + Google Chrome `156` Flatpak |
| **自动亮度环境** | `gnome-shell` `50.6` / `51.1` + `gnome-settings-daemon` `50.1` + `iio-sensor-proxy` `3.8` + `cros-ec-light` (`TI OPT3001`) |
| **实证日期** | 2026-10-27（问题一/二/三）、2026-11-01（问题四）、2026-11-07（问题五）、2026-11-12（问题六，Fedora 45 / Kernel `7.2.15`），全程在本机实证完成 |

---

## 总览（六个问题，各自独立）

| # | 症状 | 根因 | 修复（一行版） |
| :-: | :--- | :--- | :--- |
| **[一](#问题一充电只有-8w)** | PD 20V/3A 但充电恒定 ~8W | `thermald` 经 `TCHG` 把 EC 充电限流钳在 `1024 mA` | `sudo systemctl disable --now thermald` + 清一次 `TCHG` 残留 |
| **[二](#问题二audio-fix-后-gnome-看不到麦克风或默认麦录不到音)** | GNOME 看不到麦克风 / 默认麦是哑的 | 显示层缓存 + 默认选中 DC 死通道 `Mic2` | `./audio/install.sh`（配置 SOF DMIC + 切换默认输入到 `Mic1`） |
| **[三](#问题三flatpak-chrome-摄像头不可用与画面偏绿)** | Chrome 摄像头不可用；打通后偏绿 | flag 未开 + portal 弹窗 bug + 无原厂色彩调校 | `./camera/install.sh` + 开启 Chrome PipeWire camera flag |
| **[四](#问题四自动屏幕亮度怪异与滑块拉满)** | 自动亮度变化不线性、暗光下过亮且滑块拉满 | `gsd-power` 相对归一化缺陷 + GNOME 50 滑块固定偏移 + 线性 PWM 未做 `γ = 2.2` 校正 + `EC_RATE=0` | `./brightness/install.sh`（udev + 对数曲线 + `γ = 2.2` 扩展/服务） |
| **[五](#问题五雷电-3-扩展坞无法识别)** | 雷电 3 扩展坞只充电，硬盘、DP、USB 都不出现 | 内核自动进入 DP 模式，扩展坞拒绝后卡住，再也不接受 TBT；`cros_ec_typec` 的 TBT 模式默认未启用，又没有 `typecd` 去开启 | `./thunderbolt/install.sh`（udev 策略：优先 TBT3，没有再用 DP） |
| **[六](#问题六触控板掉帧光标卡顿与起手粘滞)** | 触控板滑动感觉明显掉帧、起手粘滞、偶发跳帧丢点 | `i915` PSR2 Selective Fetch 在 Pipe A 计算失败并频繁触发 `drmModeAtomicCommit -EBUSY` 丢帧 + 仅锁定 PCI 父桥未锁子设备 `i2c_designware.5`（闲置 1s 自动休眠导致 `Touch jump` 丢包） | `./touchpad/install.sh`（禁用 `i915` PSR + 保持 LPSS 与 `i2c_designware` 常驻唤醒） |

> **给 AI Agent 的提示**：如果你是负责在新系统上恢复配置或排查问题的 Agent，请优先阅读同目录下的 **[`AGENTS.md`](./AGENTS.md)** 获取结构化的幂等执行与验证工作流。

---

<a id="问题一充电只有-8w"></a>

## 问题一：充电只有 ~8W

### TL;DR

- **症状**：PD 已协商 20V/3A = 60W，但电池充电电流被钳死在恒定 `~1024 mA`（≈ 8W），重启、重插充电器、换口、加负载都无效。
- **根因**：发行版自带的 **`thermald`**（Intel 温控守护进程）被 DPTF 皮肤温度阈值（45/51°C，正常使用即达到）触发，每秒向 `TCHG` cooling device 写 `state=2`；`int3403_thermal` 驱动把它翻译成 ACPI `SPPC(2)` → `CHGS(16 步)` → EC 写入 `user_current_limit = 16 × 64 mA = 1024 mA`。该值保存在 EC RAM，跨主机重启、跨充电器拔插。ACPI 读回接口 `PPPC` 有缺陷（AC 在线恒返回 `0`），`thermald` 以为没写生效，每秒重写。
- **修复**：
  ```bash
  sudo systemctl disable --now thermald
  # 清除 EC 内可能残留的限流（对 type=TCHG 的 cdev 写一次 0）：
  for d in /sys/class/thermal/cooling_device*; do
    [ "$(cat "$d/type" 2>/dev/null)" = "TCHG" ] && echo 0 | sudo tee "$d/cur_state"
  done
  ```
  Chromebook 上禁用 `thermald` 是安全的：风扇曲线、`PROCHOT`、充电保护、过热关机全部由 EC 独立管理，`thermald` 在这类机器上是多余的一层。

### 1. 症状全貌

- 机器总输入 ~20W（= 整机功耗），电池只有 ~8W：`current_now` 恒定 `1,037,000 ~ 1,039,000 µA`
- **重启无效**（限流值在 EC RAM，主机重启 EC 不复位）
- **充电器重插/换口无效**（`thermald` 仍在跑，每秒重写）
- **8 线程满载时充电电流纹丝不动**（排除“输入功率不足”）
- `upower` 功率历史：数小时恒定 8.0W 平线
- 关机状态下充电正常（此时 `thermald` 没在运行）
- 原厂 ChromeOS 下一切正常（ChromeOS 不跑 `thermald`，热管理由 EC + `powerd` 负责）

### 2. 根因链条（每一环都有实证）

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
  │  ← 注意：PPSS 第 [4] 列（24/16/8）其实是 CHGL 的 "64mA 步数"，不是百分比；
  │     第 [5] 列 (1500/1000/500mA) 只是给人看的标注
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
| `2` | `16` | **`1024 mA`** | **987 ~ 1039 mA** ✓（= 故障时的恒定值） |
| `3` | `8` | `512 mA` | **530 mA** ✓ |

**为什么“卡住”永远不好**：
1. EC 的 `user_current_limit` 没有任何 EC 内部清除路径，只在收到新的 host 写入时变化。
2. ACPI 的 `PPPC`（get state）逻辑：`AC在线 → return 0；不在线 → return 3`，**从不反映真实状态** → `thermald`/内核视角永远是 `0`，与 EC 实际状态失同步。
3. `thermald` 见温度仍在阈值上就持续写 `2`。

### 3. 排除过的其他假说（节省后来者时间）

| 假说 | 排除依据 |
| :--- | :--- |
| PD 协商/充电器/线材问题 | partner source-caps 完整（5/9/12/15/20V），合同 20V/3A；EC `chg_input_current = 2800~3250 mA` 正常 |
| 电池 BMS 低温降额 | 直读电池（EC I2C 直通，`SBS 0x14`）：凉电池（28°C）时 BMS 仍请求 `4634 mA`，而 EC 只给 `1024 mA` —— 是 EC 侧钳制 |
| EC 内部热限流 / 电池温度 | EC 温度传感器 44–51°C 与限流无相关性；限流值恒定不随温度波动 |
| TCHG 被内核热管理触发 | 所有 `/sys/class/thermal/thermal_zone*` 均无 cdev 绑定，`step_wise` 管不到它 |
| MrChromebox ECRW 固件 bug | EC 的 charge control 状态全程正常（`mode=NORMAL, sustain=-1/-1`）；限流写入有明确 host 侧来源 |
| `tuned` / `power-profiles-daemon` | `tuned` 无 thermal 插件；`ppd` 未安装（Fedora 44 用 `tuned-ppd`） |

### 4. 诊断方法学（可直接复用）

1. **确认 PD 正常**：
   ```bash
   cat /sys/class/power_supply/CROS_USBPD_CHARGER0/{online,voltage_now,current_max}
   ```
2. **确认是恒定限流而非热/输入问题**：跑满载看 `current_now` 是否纹丝不动。
3. **定位 `TCHG`**：
   ```bash
   grep -l TCHG /sys/class/thermal/cooling_device*/type
   # 手动写 1/2/3 看电流阶梯（64mA 步：1536/1024/512）：
   echo 2 | sudo tee $(grep -l TCHG /sys/class/thermal/cooling_device*/type | xargs dirname)/cur_state
   ```
4. **抓写入者（关键一步，一行命令抓现行）**：
   ```bash
   echo 'p:tchg int3403_set_cur_state state=%si:u64' | sudo tee /sys/kernel/debug/tracing/kprobe_events
   echo 1 | sudo tee /sys/kernel/debug/tracing/events/kprobes/tchg/enable
   # ...等待/复现（挂起恢复、插拔充电器、加负载）...
   sudo cat /sys/kernel/debug/tracing/trace | grep tchg:
   # 输出里 TASK-PID 一列就是写入者进程名（本例：thermald）
   ```
5. **深挖 EC 状态（可选）**：使用 `./tools/ectool.py` 直读 EC 的 `chg_current / chg_input_current / LIMIT_POWER`、电池期望电流与电池温度。

### 5. 修复与验证

```bash
sudo systemctl disable --now thermald
```

验证（电量 20~80% 区间最准，>90% 有正常 CV 降流）：
```bash
cat /sys/class/power_supply/BAT0/current_now      # 应 > 2,000,000 (2A)
upower -i /org/freedesktop/UPower/devices/battery_BAT0 | grep energy-rate
```

- **修复后实测**：EC 充电电流 `4608 mA`、实际 `2.1 ~ 4.6 A`（随电量正常锥降）、BMS 请求 `4634 mA` 全额满足。
- **如需恢复 `thermald`**：`sudo systemctl enable --now thermald`。

### 6. 禁用 `thermald` 安全吗？/ 性能模式还生效吗？

- **安全**。ChromeOS 设备的 EC 是热管理最终权威：风扇曲线、`PROCHOT`、充电保护、过热关机全部 EC 自管；AP 侧的 `thermald` 是给“Windows 笔记本装 Linux”补位的，在 Chromebook 上只会拿 DPTF 的保守阈值乱动。
- **GNOME 的电源模式（性能/平衡/省电）照常生效**，链路是 `GNOME → tuned-ppd → tuned → cpufreq`，与 `thermald` 无关：
  - `performance` → `tuned throughput-performance`：`governor=performance`、`EPP=performance`
  - `balanced` → `balanced`（插电）/ `balanced-battery`（电池）：`EPP=balance_performance/balance_power`

### 7. 附：USB-C 显示器无视频信号修复

- **现象**：USB-C 全功能线接显示器只充电、无信号。
- **诊断**：热插拔后整条链路实际是通的（DP alt mode 协商成功、mux 切到 DP、HPD 拉高、DRM connector connected、4K@240Hz 可点亮）。故障发生在一个“老化”的系统会话里（`typec/mux` 状态卡死）。
- **解决**：重启后正常。若复发（尤其挂起恢复后），执行模块顺序修复（Fedora 已知问题，RH Bugzilla #2192574）：
  ```bash
  # 临时：按正确顺序重载
  sudo modprobe -r cros_ec_typec intel_pmc_mux
  sudo modprobe intel_pmc_mux && sudo modprobe cros_ec_typec

  # 永久：
  echo 'softdep cros_ec_typec pre: intel_pmc_mux' | sudo tee /etc/modprobe.d/cros-typec.conf
  sudo dracut -f
  ```

### 8. 附录 A：本机硬件与 EC 工具说明（`./tools/`）

- **主板**：Google Redrix（HP Elite Dragonfly Chromebook，Brya 家族）
- **固件**：MrChromebox-2609.2；EC RW：`redrix_v2.0.27867 redrix_16238.2+tbt5 2026-09-12`（Nuvoton NPCX993F）
- **充电芯片**：TI BQ25720（电池检流电阻 10mΩ）
- **电池**：DK04050XL（DynaPack 333-2C-14-A，设计 6620mAh / 7.7V）
- **DPTF**：`TSR0` 触发点 45.05°C、`TSR1` 51.05°C；`TCHG` `PPSS` 阶梯 1536 / 1024 / 512 mA
- **配套工具**：
  - `tools/ectool.py` —— EC 诊断工具（`ioctl` 直通 `/dev/cros_ec`）：
    ```bash
    sudo python3 ./tools/ectool.py                        # 全量 dump（充电状态/电池/EC温度/PD）
    sudo python3 ./tools/ectool.py --csv                  # 单行：充电电流,输入限流,电池温度,BMS请求电流,BMS请求电压
    sudo python3 ./tools/ectool.py --watch                # 每 2s 刷新
    sudo python3 ./tools/ectool.py --clear-current-limit  # 清 EC 充电限流（0xFFFFFFFF）
    ```
  - `tools/batt_logger.sh` —— 每分钟记录电池与 EC 状态到 CSV
  - `tools/drain_battery.sh` —— 强制放电到目标电量（配合 `charge_behaviour`）
- **关键协议常量**：
  - **EC host 命令号**：`0x0096` `CHARGE_CONTROL`、`0x0097/98` `CONSOLE`、`0x009E` `I2C_PASSTHRU`、`0x00A0` `CHARGE_STATE`、`0x00A1` `CHARGE_CURRENT_LIMIT`、`0x0121` `GET_UPTIME_INFO`
  - **ioctl**：`CROS_EC_DEV_IOCXCMD = _IOWR(0xEC, 0, struct cros_ec_command)` = `0xC014EC00`
  - **SBS 电池寄存器**：`0x08` 温度 (0.1K)、`0x0A` 电流、`0x14` 期望充电电流、`0x15` 期望充电电压

---

<a id="问题二audio-fix-后-gnome-看不到麦克风或默认麦录不到音"></a>

## 问题二：audio fix 后 GNOME 看不到麦克风或默认麦录不到音

### TL;DR

- **症状**：网上 audio fix 装完，扬声器/耳机能出声；GNOME 设置 → 声音里看不到输入设备，或能看到“内置麦克风 2”但电平条不动、录音是哑的。
- **根因（两个独立问题叠加，都要处理）**：
  1. **GNOME 显示层缓存**：设置面板/`gnome-shell` 用 GVC（`libpulse`）维护设备列表，补丁生效前打开的会话里是旧状态。重开设置或注销重登即可看到——不是 PipeWire 的问题。
  2. **默认选中的是死通道**：Redrix 的 DMIC PCM（`hw:0,99`）是 4 声道，PipeWire 1.6 的 `api.alsa.split` 特性把它拆成“内置麦克风 1”（`AUX0/1`）和“内置麦克风 2”（`AUX2/3`）两个 source。**实测只有 `Mic1` 接了真麦克风，`Mic2` 是恒定 ~1/2 满幅的 DC 死电平**；WirePlumber 两条 route 优先级相同（100），默认挑了 `Mic2`。
- **修复**：
  ```bash
  ./audio/install.sh
  # 或单独切换默认输入源（WirePlumber 自动持久化到 ~/.local/state/wireplumber/default-nodes）：
  pactl set-default-source alsa_input.pci-0000_00_1f.3-platform-adl_rt5682_def.HiFi__Mic1__source
  ```

### A. 本机音频链路快照

- **声卡**：`sof-rt5682`（`hw:0`），驱动 `snd_soc_sof_rt5682`，machine driver `adl_rt5682_def`
- **固件/拓扑**：均为 Fedora 官方包（`alsa-sof-firmware`），**无需手动覆盖任何 `/lib/firmware` 文件**
- **PCM 布局**：`0`=Speakers，`1`=Headset(录+放)，`2–5`=HDMI，`6`=EchoRef，`7`=Bluetooth，**`99`=DMIC(4ch)**，`100`=DMIC16kHz
- **UCM**：官方 `sof-rt5682/HiFi.conf` 定义 `Mic1`/`Mic2` 两个 `SectionDevice`，都映射到 `PCM99`
- **dmesg 关键行**：`DMICs detected in NHLT tables: 0`（MrChromebox 固件无 NHLT 表 → 必须用 `dmic_num=4` 强制暴露）

### B. 音频配置文件明细（已备份至 `audio/` 目录）

可通过 `./audio/install.sh` 一键部署：

| 部署位置 | 仓库备份文件（`audio/`） | 内容与作用 |
| :--- | :--- | :--- |
| `/etc/modprobe.d/adl-sof.conf` | `adl-sof.conf` | `options snd_sof_intel_hda_generic dmic_num=4`：无 NHLT 时强制暴露 4 通道 DMIC PCM（`hw:0,99`）。**没有它连麦克风 PCM 都不出现** |
| `/etc/wireplumber/wireplumber.conf.d/51-disable-pro-audio.conf` | `51-disable-pro-audio.conf` | `sof/avs/acp` 卡设 `api.acp.disable-pro-audio=true`：防止 UCM 声卡被自动切到 Pro Audio profile |
| `/etc/wireplumber/wireplumber.conf.d/51-increase-headroom.conf` | `51-increase-headroom.conf` | `alsa_output` 节点设 `api.alsa.headroom=2048`：加大 ALSA 缓冲防爆音 |
| `/etc/wireplumber/wireplumber.conf.d/52-disable-mic2.conf`（可选） | `52-disable-mic2.conf` | 将恒定 DC 死电平的 `HiFi__Mic2__source` 设为 `node.disabled = true`（传 `--hide-mic2` 安装） |

### C. 诊断方法学（四通道硬件判活）

```bash
arecord -D hw:0,99 -f S32_LE -r 48000 -c 4 -d 3 /tmp/dmic.wav
python3 - <<'EOF'
import wave, array
w = wave.open('/tmp/dmic.wav','rb')
a = array.array('i'); a.frombytes(w.readframes(w.getnframes()))
for c in range(w.getnchannels()):
    v = a[c::w.getnchannels()]
    print(f'ch{c}: max={max(map(abs,v))}, avg={sum(map(abs,v))//len(v)}')
EOF
```

- **判读标准**：
  - `ch0/1`（对应 `Mic1`）：`max ≫ avg`（>10 倍）= **活通道**（真实声音信号）
  - `ch2/3`（对应 `Mic2`）：`avg ≈ max ≈ 1.03e9`（`S32` 满幅 `2.1e9` 的一半，恒定 DC）= **硬件未接麦克风的死通道**

---

<a id="问题三flatpak-chrome-摄像头不可用与画面偏绿"></a>

## 问题三：Flatpak Chrome 摄像头不可用与画面偏绿（`IPU6` + `OV5675`）

### TL;DR

- **症状**：
  1. Chrome（Flatpak 版）里摄像头完全不可用/黑屏，授权弹窗也弹不出来；
  2. 打通后画面明显偏绿/偏紫、颜色像水洗过。
- **根因（三层独立问题叠加）**：
  1. **Flatpak Chrome 默认不走 PipeWire 摄像头**：IPU6 的 32 个 `/dev/video*` 节点都是原始 Bayer 输出，应用只能经 PipeWire/`libcamera` 使用；Chrome 的 PipeWire camera 支持默认关闭。
  2. **`xdg-desktop-portal-gnome` 焦点检查 bug 弹不出授权框**：日志报 `Only the focused app is allowed to show a system access dialog`（`flatpak/xdg-desktop-portal#1338`），弹窗失败还可能被记成“已拒绝”。
  3. **`libcamera` 没有 `ov5675` 的调校文件**：回落到 `uncalibrated.yaml`——黑电平靠场景猜（猜错全砸到红通道增益上 → 偏绿）、无色彩校正矩阵（颜色寡淡）。
- **修复（一键脚本 + Chrome Flag）**：
  ```bash
  # 1. 安装原厂色彩调校 + Flatpak 免弹窗预授权 + 重启 PipeWire：
  ./camera/install.sh

  # 2. Chrome 地址栏打开 chrome://flags/#enable-webrtc-pipewire-camera → 设为 Enabled → 重启 Chrome
  ```

### A. 最终生效的配置

| 位置 | 内容 | 说明 |
| :--- | :--- | :--- |
| `/usr/share/libcamera/ipa/simple/ov5675.yaml` | 黑电平 `4122` + 原厂 CCM（7 组色温 2300–6441K） | 不属于任何 RPM 包，系统升级不会覆盖；若删除则回落 `uncalibrated.yaml` 重新偏绿 |
| `flatpak permission-set devices camera com.google.Chrome yes` | Chrome 免弹窗授权 | 绕开 portal 焦点 bug |
| Chrome flag `#enable-webrtc-pipewire-camera` | `Enabled` | IPU6 摄像头必须走 PipeWire |

- **测试页**：`https://mozilla.github.io/webrtc-landing/gum_test.html`（设备选 `ov5675`）
- **交叉验证**：GNOME Snapshot（茄子）走同一条 PipeWire 链路

### B. 原厂调校数据来源与提取方法

从本机对应的 ChromeOS 恢复镜像 `chromeos_16836.19.0_brya_recovery_stable-channel_BryaMPKeys-v23.bin`（`recovery.json` 里 `hwidmatch ^REDRIX-CLQY` = 本机）rootfs 的 `/etc/camera/ov5675.aiqb`，使用 `camera/parse_aiqb.py` 提取 `record id=25` 的 7 组色温 CCM；黑电平 `4122` 由盖镜头抓 RAW 实测 `64.4`（10-bit）× 64 得出。

```bash
# 挂载 ChromeOS 恢复镜像 rootfs 提取命令备忘：
sudo mount -o ro,loop,offset=<ROOT-A起始字节>,noload -t ext4 <镜像.bin> /mnt
cp /mnt/etc/camera/ov5675.aiqb .
python3 ./camera/parse_aiqb.py ov5675.aiqb --sensor-name ov5675
```

### C. 验证标准（白纸法）

```bash
# 白纸正对摄像头 20-30cm 填满画面，连抓 60 帧取尾帧（AGC/AWB 收敛需 ~2 秒）
timeout 40 cam -c1 --capture=60 --file=w_#.ppm
magick w_cam0-stream0-000059.ppm -set colorspace sRGB -colorspace RGB \
  -format "G/R=%[fx:mean.g/mean.r] G/B=%[fx:mean.g/mean.b]\n" info:
# G/R、G/B 越接近 1.000 越中性。修复前 ~1.10（明显偏绿），修复后 ~1.04-1.07（纸的色差范围内）
```

### D. 经验与避坑（重要！）

1. **`libcamera 0.7.2` 原版的 soft-AWB 统计已经是正确的**（`swstats_cpu.cpp` 的 `finishFrame()` 里 `sum_ >>= sumShift_`，解包 10-bit 路径 `sumShift_ = 2`，已做 8-bit 缩放）。针对 0.7.0 的 `0002-soft-stats-scale-sums-to-8-bit.patch` 在 0.7.2 上会**双重除法**导致白平衡增益爆炸（R 通道顶死 `4.0`、画面通红）——切勿套用。
2. 传感器确认 `sensor_type="BAYER" bayer_order="GRBG"`，无 RGB-IR 特殊阵列；`IPU6 in secure mode` 内核日志无害。
3. 抓帧测试必须连抓 ≥ 60 帧取尾帧；8 帧/12 帧短连发会被 AGC/AWB 过渡期污染。
4. V4L2 原生程序（RPM 版 Zoom 等）可用 `LD_PRELOAD=/usr/libexec/libcamera/v4l2-compat.so` 启动兼容。
5. **背光白平衡限制**：软 ISP 的灰度世界 AWB 对整帧求均值，阴天坐在落地窗前时大面积冷色窗户会主导统计。视频通话时开启室内前向补光即可缓解；硬件 ISP（PSYS）可行性勘测见 [`camera/hw-isp-recon.md`](./camera/hw-isp-recon.md)。

---

<a id="问题四自动屏幕亮度怪异与滑块拉满"></a>

## 问题四：自动屏幕亮度怪异与滑块拉满（`cros-ec-light` + GNOME 50）

### TL;DR

- **症状**：
  1. 开启“自动屏幕亮度”后，体感屏幕亮度变化非常不线性（低亮度区一跳一大截、高亮度区几乎没感觉，且调整时一顿一顿不丝滑）。
  2. 在暗光环境下（如夜间 8–10 lux 昏暗室内）屏幕依然很亮（硬件背光高达 `~40000/96000` 甚至直接顶到 `94640/96000`），且点开 GNOME 右上角菜单看到**屏幕亮度滑块是拉满的（接近 100%）**。
- **根因（四层问题叠加，每一层均有反汇编/源码实证）**：
  1. **GNOME 50 (`brightnessManager.js`) 把亮度滑块改成了“固定偏移量（Bias）”且不再随自动亮度同步位置**：
     开启自动亮度（`_abTarget >= 0`）后，`gnome-shell` 只写硬件背光而不更新 UI 滑块 `scale.value`，计算公式为 `target = clamp(_abTarget + scale.value - 0.5, 0.0, 1.0)`。本机开机初始背光缓存在 `94640/96000`（`98.6%`），导致右上角滑块永远停在近 `100%`（拉满），同时向自动亮度**恒定硬加 `+48.6%`（`0.986 - 0.5`）的偏置**——哪怕全黑下自动亮度目标算出来是 `0%`，屏幕最低也有近 `50%` 亮度；只要自动亮度目标达 `50%`，屏幕直接 `100%` 拉满。
  2. **`gsd-power` 采用“动态相对归一化”而非绝对照度曲线，暗光下极易把微光定义为满亮度基准**：
     反汇编 `/usr/libexec/gsd-power` 证实：每当刚开机登录或用户手动动了一下亮度滑块（触发 `BrightnessChanged`），`gsd-power` 就会执行 `Normalizing light level`，将满亮度基准值设为 `ambient_norm_value = 当前 lux × 1.5`，并把初始目标设为 `66.7%` (`100 / 1.5`)。若在暗光（如 `2~3 lux`）下开机或嫌亮手动拉滑块，系统立刻把 `3~4.5 lux` 当成 `100%` 满亮度标准，稍微一点屏幕反光跳到 `4~5 lux` 就直接输出 `100%` 满亮度。
  3. **`intel_backlight` 是纯线性 PWM（`scale: unknown`），GNOME 未做人眼幂律（`γ = 2.2`）校正**：
     对照 ChromiumOS 官方 `powerd`（`internal_backlight_controller.cc`）源码：当 `scale` 为 `unknown` 且 `max_brightness >= 100`（本机为 `96000`）时，ChromeOS 强制使用 `kDefaultLevelToPercentExponent = 0.5`（即百分比转硬件 PWM 为 `p^2.2` 幂函数）。而 GNOME 50 使用 1:1 纯线性映射，导致 `20%` 硬件 PWM 在人眼看来已有 `~48%` 亮度、`40%` 硬件 PWM（`38485/96000`）在暗室下人眼感知高达 `~68%` 亮度，且低亮度区稍微变化就引起体感剧烈跳变。
  4. **EC 传感器默认 `EC_RATE = 0`（`buffer/hwfifo_timeout = 0`）且无过渡动画**：
     通过 `/dev/cros_ec` 发起 `EC_CMD_MOTION_SENSE_CMD (0x002B)` 实测：虽然 `SENSOR_ODR` 为 `1000 mHz` (1Hz)，但 `EC_RATE` 为 `0`，且 GNOME 的 `setBacklight()` 是单步瞬时写入，没有平滑插值过渡，造成 1Hz 阶跃感。
- **一键修复**：
  ```bash
  ./brightness/install.sh
  ```

### A. 本机背光与环境光传感器（ALS）链路快照

| 组件 | 路径 / 接口 | 本机实测值与特性 |
| :--- | :--- | :--- |
| **内置面板** | `/sys/class/drm/card1-eDP-1` | BOE 2678（2256×1504 @ 60Hz/40Hz，3:2） |
| **背光接口** | `/sys/class/backlight/intel_backlight` | `type: raw`，`max_brightness: 96000`，Mutter `min: 960`，`scale: unknown`（纯线性 PWM） |
| **环境光传感器** | `/sys/bus/iio/devices/iio:device0` | `name: cros-ec-light`，`id: 3`，`label: accel-camera`（位于屏幕上方摄像头旁） |
| **ALS 硬件芯片** | EC `MOTIONSENSE_CMD_INFO` (sensor 3) | `chip: 20` = **TI OPT3001**，硬件支持频率 `0.149 Hz` / `1.000 Hz` |
| **EC 采样参数** | `SENSOR_ODR` (subcmd 3) / `EC_RATE` (subcmd 2) | 默认 `SENSOR_ODR=1000` (1Hz)，但 `EC_RATE=0`（对应 `buffer/hwfifo_timeout=0.000000`） |

### B. 根因链条与反汇编 / 源码级实证

#### 1. `gsd-power` 反汇编实证（相对归一化算法缺陷）

反汇编 `/usr/libexec/gsd-power`（`0x5fb8`–`0x625c` 及 `.rodata` 浮点常量 `0xfd88`–`0xfdc8`）还原出的核心逻辑：

```c
// 当启动首次读取，或收到 org.gnome.Shell.Brightness::BrightnessChanged 信号时：
// ("User brightness change detected, re-normalizing" -> manager->ambient_norm_required = TRUE)
if (manager->ambient_norm_required) {
    g_debug("Normalizing light level");
    manager->ambient_norm_value = light_level * 1.5;      // 0xfdb0 = 1.5
    if (manager->ambient_accumulator <= 0.0)
        manager->ambient_accumulator = 66.666664;         // 0xfdb8 = 100.0 / 1.5
    manager->ambient_norm_required = FALSE;
}

// 随后每次读到 light_level (lux)：
double pc = CLAMP((light_level * 100.0) / manager->ambient_norm_value, 0.0, 100.0);
// 一阶低通滤波（时间常数 0xfdc0 = 1591549.4 us ≈ 1.59s）
manager->ambient_accumulator = (1.0 - alpha) * manager->ambient_accumulator + alpha * pc;
SetAutoBrightnessTarget(manager->ambient_accumulator / 100.0);
```

- **致命缺陷**：GNOME 49/50 将背光控制移交给 `gnome-shell` 后，`gsd-power` 删掉了 `GetBrightness` 调用，**完全不知道当前屏幕实际亮度是多少**，只会无脑把 `当前环境光 lux × 1.5` 设为 `100%` 满亮度的归一化分母。在暗光下开机或手动拉滑块后，只需增加几 lux 就会算出 `pc = 100%`。

#### 2. `gnome-shell` (`brightnessManager.js`) 源码实证（滑块拉满与 `+0.5` 偏移）

从 `/usr/lib64/gnome-shell/libshell-18.so` 提取 `/org/gnome/shell/misc/brightnessManager.js`（第 172–247 行）：

```js
// Update the actual backlight according to the new monitor brightnesses
for (const scale of this._monitorScales.values()) {
    const target = this._abTarget >= 0.0
        ? Math.clamp(this._abTarget + scale.value - 0.5, 0.0, 1.0)
        : scale.value;
    const max = this._dimmingEnabled ? this._dimmingTarget : 1.0;
    const brightness = Math.min(max, target);
    scale.setBacklight(brightness);
}
```

以及 `MonitorBrightnessScale`（第 325–333 行）：

```js
_getRelativeBrightness(backlight) {
    const {brightness, brightnessMin: min, brightnessMax: max} = backlight;
    return (brightness - min) / (max - min);
}
_setRelativeBrightness(backlight, brightness) {
    const {brightnessMin: min, brightnessMax: max} = backlight;
    backlight.brightness = min + ((max - min) * brightness);
}
```

- **两个直接后果**：
  1. `SetAutoBrightnessTarget` 只改 `this._abTarget` 并调 `scale.setBacklight()`，**从不更新 `scale.value` 和右上角 UI 滑块 `_globalScale.value`**。本机 `org.gnome.Mutter.DisplayConfig` 的 `Backlight` 初始值停在 `94640`（`scale.value = 0.986`），所以右上角滑块看起来永远是拉满的，并且 `scale.value - 0.5 = +0.486` 把所有自动亮度目标硬生生往上抬高了近 `50%`。
  2. `_setRelativeBrightness` 是纯线性的，没有任何 Gamma 校正。在 `9~10 lux` 昏暗室内，`gsd-power` + `gnome-shell` 算出的 `~0.40` 直接写成硬件 `38485~40269 / 96000`，在人眼看来相当于近 `70%` 的刺眼亮度。

#### 3. 对照 ChromiumOS 官方 `powerd` 源码（为什么 ChromeOS 体感线性舒适）

核对 ChromiumOS `platform2/power_manager/powerd/policy/internal_backlight_controller.cc`：
- ChromeOS 定义 `kDefaultLevelToPercentExponent = 0.5`，当 sysfs `scale` 为 `unknown` 且 `max_level >= 100` 时自动启用非线性幂律映射：
  `hw_level = min + (max - min) × percent^γ`（`γ = 2.0 ~ 2.2`）
- 在 `γ = 2.2` 下，`43%` 的人眼感知亮度对应硬件 PWM 为 `15970 / 96000`（`16.6%` 物理占空比），而非线性映射下的 `41600 / 96000`，低亮度区细腻度提升近 3 倍。

### C. 排除过的假说与验证记录

| 假说 | 验证方法与结论 |
| :--- | :--- |
| BIOS / EC 固件损坏需重刷 | 直通 `/dev/cros_ec` 读 `MOTIONSENSE_CMD_INFO/DATA/RANGE`，OPT3001 传感器工作正常，无需动固件 |
| 写 `in_illuminance_calibscale` 放大 EC 读数 | 反汇编 `cros_ec_light_prox.ko` 确认写 `calibscale` 对应 `MOTIONSENSE_CMD_SENSOR_RANGE (0x04)`，但 Redrix EC 的 `opt3001` 驱动在读取 `in_illuminance_input` 时直接返回 lux 整数，不受 `SENSOR_RANGE` 倍率影响；必须在用户态做连续对数曲线映射 + EMA 浮点滤波 |
| 外部程序直接写 sysfs 会触发 GNOME 滑块同步 | 反汇编 `libmutter-18.so` (`meta_backlight_sysfs_new`) 确认 Mutter 仅监听 `udev` 事件，而内核写 `intel_backlight/brightness` 不发 uevent；必须通过 GNOME Shell 扩展在进程内同步 `_globalScale` 或调用 `DisplayConfig.SetBacklight` |

### D. 最终修复架构与部署明细

整套修复保存在 `./brightness/`，由以下 4 部分组成：

| 部署位置 | 源文件（`brightness/`） | 作用 |
| :--- | :--- | :--- |
| `/etc/udev/rules.d/99-redrix-als.rules` | `99-redrix-als.rules` | 激活 `cros-ec-light` `sampling_frequency=1.000000` 与 `buffer/hwfifo_timeout=1.000000`（设置 `EC_RATE=1000ms`），并开放 `intel_backlight/brightness` `0666` 高频平滑写入权限 |
| `dconf` (`ambient-enabled=false`) | `install.sh` 自动设置 | 彻底关闭 `gsd-power` 有缺陷的相对归一化算法 |
| `~/.local/share/gnome-shell/extensions/redrix-auto-brightness@local/` | `redrix-auto-brightness@local/{metadata.json,extension.js}` | **GNOME Shell 原生扩展**：重写 `MonitorBrightnessScale` 为 `γ = 2.2` 感知线性曲线（手动拉滑块/快捷键同样生效），拦截 `SetAutoBrightnessTarget`，内置对数照度自动亮度 + 80ms 步进渐变，并实时同步右上角亮度滑块位置 |
| `~/.config/systemd/user/redrix-auto-brightness.service` + `~/.local/bin/redrix-auto-brightness` | `redrix-auto-brightness.service` + `redrix-auto-brightness` | **当前会话即时生效守护服务**：在首次安装尚未注销重登 GNOME Shell 时立即接管自动调光（50ms 丝滑步进 + 对数曲线 + `γ = 2.2` + 手动偏移记忆）；当检测到上述 GNOME Shell 扩展已处于 `ACTIVE` 状态时自动静默退出让位，绝不双开冲突 |

#### 对数照度 → 感知亮度 → 硬件 PWM 映射对照表（`γ = 2.2`）

- **对数曲线公式**：`p_auto(L) = clamp(0.15 + 0.28 × log10(L + 1.2), 0.12, 1.0)`
- **硬件 PWM 公式**：`hw = 960 + 95040 × p^2.2`

| 环境场景 | 传感器照度 (`lux`) | 感知亮度百分比（GNOME 滑块位置） | 硬件 PWM (`intel_backlight`) | 物理占空比 |
| :--- | :-: | :-: | :-: | :-: |
| 全黑关灯 | `0 lux` | **17.2%** | `~2,940 / 96000` | 3.1% |
| 极暗夜灯 | `3 lux` | **32.5%** | `~8,960 / 96000` | 9.3% |
| 昏暗室内 | `9 lux` | **43.2%** | `~15,970 / 96000` | 16.6% |
| 普通室内灯光 | `30 lux` | **56.8%** | `~28,480 / 96000` | 29.7% |
| 明亮室内办公 | `100 lux` | **71.1%** | `~45,550 / 96000` | 47.4% |
| 靠窗 / 强室内光 | `300 lux` | **84.4%** | `~66,300 / 96000` | 69.1% |
| 户外 / 阳光直射 | `1000+ lux` | **100.0%** | `96,000 / 96000` | 100.0% |

> **手动微调机制**：任何时候手动拖动 GNOME 亮度滑块或按键盘亮度加减键，系统会立即停止当前渐变并计算 `userBias = 用户设定感知亮度 - 当前照度基准感知亮度`（范围 `±50%`），后续环境光变化时自动在个人偏好偏移基础上平滑调节。

### E. 验证与自定义调优

```bash
# 1. 确认 udev 规则生效（sampling_frequency 和 hwfifo_timeout 均为 1.000000）
grep -H . /sys/bus/iio/devices/iio:device0/{sampling_frequency,buffer/hwfifo_timeout}

# 2. 确认 gsd-power 的错误归一化已关闭
gsettings get org.gnome.settings-daemon.plugins.power ambient-enabled   # 应为 false

# 3. 确认服务或扩展正在运行
systemctl --user status redrix-auto-brightness.service --no-pager
gnome-extensions list --enabled | grep redrix-auto-brightness@local

# 4. 用手遮住摄像头旁传感器 2 秒再松开，观察 brightness 是否平顺变化
watch -n 0.2 'cat /sys/bus/iio/devices/iio:device0/in_illuminance_input /sys/class/backlight/intel_backlight/brightness'
```

如需调整整体亮度曲线偏亮/偏暗，修改 `brightness/redrix-auto-brightness` 与 `brightness/redrix-auto-brightness@local/extension.js` 中的 `0.15 + 0.28 * log10(lux + 1.2)` 常数项（如把 `0.15` 改为 `0.20` 即可全局提亮 `5%` 感知亮度），然后重新运行 `./brightness/install.sh`。

---

<a id="问题五雷电-3-扩展坞无法识别"></a>

## 问题五：雷电 3 扩展坞无法识别（Type-C 备用模式策略）

### TL;DR
- **现象**：雷电 3 扩展坞（实测：ACASIS 雷电 3 NVMe 扩展坞，Intel JHL7440 Titan Ridge DD，PD ID `042b:185e`）插上后只以 20V/3A 给电脑充电。`boltctl list` 为空，`/sys/bus/thunderbolt/devices/` 里只有本机的两个主机控制器，扩展坞上的 NVMe 和 DP 都不出现。换左右口、换扩展坞上的接口都没有用。
- **根因**（三层）：
  1. `redrix` 的 EC 带有 `EC_FEATURE_TYPEC_REQUIRE_AP_MODE_ENTRY`（`inventory` 第 42 位）：EC 不会自己进入任何备用模式，必须由主机下令。ChromeOS 上由 `typecd` 守护进程负责（先 TBT/USB4，再 DP）。
  2. `cros_ec_typec` 注册 TBT 端口模式（`8087`）时故意设成 `desc.inactive = true`（对应 ChromeOS 的"外设数据访问"开关），DP 端口模式（`ff01`）却是开着的。所以每次插入，`typec_displayport` 驱动都会立刻让 EC 进入 **DP** 模式。
  3. 只支持雷电 3 的扩展坞接受了 DP 进入，却拒绝 DP 配置（`NAK for cmd 17`、`DP alt mode protocol failed!`），然后卡在这个状态。之后的 TBT 进入请求被拒，EC 重试时发的 TBT 退出也被拒。EC 会无限循环 `TBT attempt to enter mode → exit mode SOP failed → alt mode protocol failed!`。内核日志里只能看到 `cros-ec-typec: No valid DP mode provided` / `Configure muxes failed, err = -22`。
- **修复**：`./thunderbolt/install.sh` 安装一套 udev 策略，做 ChromeOS 上 `typecd` 做的事。它在端口层面关掉 DP 自动进入，打开 TBT 端口模式。有设备插入时，如果设备报了 SVID `8087`，就启用 TBT；否则重新打开 DP 并启用（USB-C 显示器照常可用）。设备拔出后，再把端口的 DP 关回去。

### 部署的文件（`./thunderbolt/`）

| 系统路径 | 仓库来源 | 作用 |
| :--- | :--- | :--- |
| `/etc/udev/rules.d/90-typec-mode-policy.rules` | `thunderbolt/90-typec-mode-policy.rules` | 端口模式注册时，把 `ff01` 设为 `active=no`、`8087` 设为 `active=yes`；设备的备用模式出现时，通过 `systemd-run` 调用策略脚本；设备拔出时执行复位。 |
| `/usr/local/libexec/typec-mode-policy` | `thunderbolt/typec-mode-policy` | 等待 1.5 秒让 PD 发现流程完成，然后往设备 TBT 模式的 `active` 写 `yes`（`typec_thunderbolt` → `cros_typec_altmode_enter` → `EC_CMD_TYPEC_CONTROL` ENTER_MODE TBT）；设备没有 TBT 时改走 DP。日志用 `journalctl -t typec-mode-policy` 查看。 |

### 验证结果
```text
$ sudo ectool usbpdmuxinfo
Port 0: USB=0 DP=0 POLARITY=NORMAL HPD_IRQ=0 HPD_LVL=0 SAFE=0 TBT=1 USB4=0
$ boltctl list
 * Intel Tamales module 2   generation: Thunderbolt 3   status: authorized
   rx/tx speed: 40 Gb/s = 2 lanes * 20 Gb/s            policy: iommu
$ lspci -tv   →  JHL7440 Thunderbolt 3 USB Controller [Titan Ridge DD 2018] + MAXIO MAP1602 NVMe (4 TB)
```
重启和拔插后依然有效。实测环境：内核 `7.2.15-300.fc45`，EC RW `redrix_16238.2+tbt5`（MrChromebox）。

### 诊断方法（用 `ectool` 读 EC 控制台）
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

## 问题六：触控板掉帧、光标卡顿与起手粘滞（`i915` PSR2 + `i2c_designware` 休眠）

### TL;DR
- **现象**：在 GNOME Wayland 下使用内置触控板（`ELAN2703:00 04F3:323B`）移动光标或小幅滚动页面时，长期感觉指针不跟手、像掉到 20–30fps 一样一卡一卡；手指停顿超过 1 秒再次滑动时起手发粘，且滑动中途偶发停顿漏帧。
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

### 排除过的干扰项（避免踩过时教程的坑）

| 假说 | 实证与排除依据 |
| :--- | :--- |
| 缺少旧版 `libinput` 压感阈值（`AttrPressureRange`）导致断触 | 检查 `/usr/share/libinput/50-system-google.quirks` 并反汇编 `libinput.so.10` (`1.32.0`) 确认：`Redrix` 规则已内置，且内核 `hid-haptic` 已为 `event5` 标记 `INPUT_PROP_PRESSUREPAD`（`properties=0x85`），`libinput` 检测到 ForcePad/Haptic 属性后直接调用 `libevdev_disable_event_code` 禁用 `ABS_MT_PRESSURE` 门限判定，无需手动覆盖压感配置 |
| 静态 DRRS 将屏幕锁死在 40Hz 低刷档 | 解码 `card1-eDP-1` EDID 确认面板含 `60.001Hz` 与 `40.002Hz` 两个 DTD；通过 `libdrm` (`drmWaitVBlank`) 实测静止 0.5s / 1.5s / 3.0s 后的硬件帧间隔均稳定在 `16.667ms` (`60.00Hz`)，卡顿完全来自 PSR2 唤醒丢帧而非静态降频 |

### 部署的文件（`./touchpad/`）

| 系统路径 | 仓库来源 | 作用 |
| :--- | :--- | :--- |
| `/etc/udev/rules.d/99-touchpad-i2c-no-pm.rules` | `touchpad/99-touchpad-i2c-no-pm.rules` | 同时将 LPSS PCI 父桥（`0000:00:19.1`、`0000:00:15.3`）及其下属 `platform` 子设备 `i2c_designware.*` 设为 `ATTR{power/control}="on"`，彻底阻止 1 秒自动休眠。 |
| `/etc/modprobe.d/i915-psr.conf` + BLS `cmdline` | `touchpad/i915-psr.conf` + `grubby` | 写入 `options i915 enable_psr=0` 并通过 `grubby --update-kernel=ALL --args="i915.enable_psr=0"` 同步更新 `/etc/kernel/cmdline`、`/etc/default/grub` 与 BLS 启动项。 |

### 验证方法
```bash
# 1. 确认 I2C 控制器常驻 active（闲置 >2 秒后仍为 control=on status=active）
for p in /sys/devices/pci0000:00/0000:00:19.1/i2c_designware.* /sys/devices/pci0000:00/0000:00:15.3/i2c_designware.*; do
  echo "$p: control=$(cat "$p/power/control") status=$(cat "$p/power/runtime_status")"
done

# 2. 重启后确认 PSR 已禁用且无 Selective fetch / Page flip 报错
cat /proc/cmdline
journalctl -b 0 | grep -E "Selective fetch|Page flip failed|Touch jump"
```
