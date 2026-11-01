# Redrix Chromebook（HP Elite Dragonfly）刷 Linux 修复手册
# 问题一：充电只有 ~8W（根因：thermald → TCHG → EC 1024mA 充电限流，见 §1–§10）
# 问题二：audio fix 后 GNOME 看不到麦克风 / 默认麦克风录不到音
# 问题三：Flatpak Chrome 摄像头不可用 + 画面偏绿（IPU6 + ov5675 缺原厂调校）
# 问题四：自动屏幕亮度怪异（变化不线性 + 暗光下依然很亮、GNOME 亮度滑块拉满）

> 适用于：任何 ChromeOS 设备（刷 MrChromebox 固件或其他方式安装原生 Linux 后出现同类问题）
> 实测机型：HP Elite Dragonfly Chromebook（board: redrix，Alder Lake i5-1245U）
> 系统：Fedora 44 Workstation（kernel 7.2.11 / 7.2.13）+ MrChromebox 2609.2 UEFI Full ROM
> 诊断日期：2026-10-27（问题一/二/三）、2026-11-01（问题四），全程在本机上实证完成
> 问题二环境：PipeWire 1.6.10 + WirePlumber 0.5.18 + alsa-ucm 1.2.16 + GNOME 50.6
> 问题三环境：libcamera 0.7.2-2.fc44 + pipewire-plugin-libcamera + Chrome 156 Flatpak
> 问题四环境：gnome-shell 50.6 + gnome-settings-daemon 50.1 + iio-sensor-proxy 3.8 + cros-ec-light (TI OPT3001)

## 总览（四个问题，各自独立）

| # | 症状 | 根因 | 修复（一行版） |
|---|---|---|---|
| 一 | PD 20V/3A 但充电恒 ~8W | thermald 经 TCHG 把 EC 充电限流钳在 1024mA | `sudo systemctl disable --now thermald` + 清一次 TCHG 残留 |
| 二 | GNOME 看不到麦克风/默认麦是哑的 | 显示层缓存 + 默认选中 DC 死通道 Mic2 | `./audio/install.sh`（配置 SOF DMIC + 切换默认输入到 `Mic1`） |
| 三 | Chrome 摄像头不可用；打通后偏绿 | flag 未开 + portal 弹窗 bug + 无原厂色彩调校 | `./camera/install.sh` + 开启 Chrome PipeWire camera flag |
| 四 | 自动亮度变化不线性、暗光下过亮且滑块拉满 | `gsd-power` 相对归一化缺陷 + GNOME 50 滑块固定偏移 + 线性 PWM 未做 Gamma 2.2 校正 + EC_RATE=0 | `./brightness/install.sh`（udev + 对数曲线 + Gamma 2.2 扩展/服务） |

> **给 AI Agent 的提示**：如果你是负责在新系统上恢复配置或排查问题的 Agent，请优先阅读同目录下的 **`AGENTS.md`** 获取结构化的幂等执行与验证工作流。

---

# 问题一：充电只有 ~8W

## TL;DR

**症状**：PD 已协商 20V/3A=60W，但电池充电电流被钳死在恒定 ~1024mA（≈8W），重启、重插充电器、换口、加负载都无效。

**根因**：发行版自带的 **thermald**（Intel 温控守护进程）被 DPTF 皮肤温度阈值（45/51°C，正常使用即达到）触发，每秒向 `TCHG` cooling device 写 `state=2`；`int3403_thermal` 驱动把它翻译成 ACPI `SPPC(2)` → `CHGS(16 步)` → EC 写入 `user_current_limit = 16 × 64mA = 1024mA`。该值保存在 EC RAM，跨主机重启、跨充电器拔插。ACPI 读回接口 `PPPC` 有缺陷（AC 在线恒返回 0），thermald 以为没写生效，每秒重写。

**修复**（一行）：

```bash
sudo systemctl disable --now thermald
# 清除 EC 内可能残留的限流（对 type=TCHG 的 cdev 写一次 0）：
for d in /sys/class/thermal/cooling_device*; do
  [ "$(cat $d/type)" = "TCHG" ] && echo 0 | sudo tee $d/cur_state
done
```

Chromebook 上禁用 thermald 是安全的：风扇曲线、PROCHOT、充电保护、过热关机全部由 EC 独立管理，thermald 在这类机器上是多余的一层。

---

## 1. 症状全貌

- 机器总输入 ~20W（= 整机功耗），电池只有 ~8W：`current_now` 恒定 1,037,000~1,039,000 µA
- **重启无效**（限流值在 EC RAM，主机重启 EC 不复位）
- **充电器重插/换口无效**（thermald 仍在跑，每秒重写）
- **8 线程满载时充电电流纹丝不动**（排除"输入功率不足"）
- upower 功率历史：数小时恒定 8.0W 平线
- 关机状态下充电正常（此时 thermald 没在运行——issue 里其他用户的线索）
- 刷 ChromeOS 时代一切正常（ChromeOS 不跑 thermald，热管理由 EC+powerd 负责）
- 秋凉后开始出现（机身更容易贴近温度阈值/风扇曲线保守）

## 2. 根因链条（每一环都有实证）

```
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
  │  ← 注意：PPSS 第[4]列（24/16/8）其实是 CHGL 的"64mA 步数"，不是百分比；
  │     第[5]列(1500/1000/500mA)只是给人看的标注
  ▼
EC 固件 charge_state.c：user_current_limit = 16 × 64mA = 1024mA
  │  ← requested_current = min(电池期望电流, user_current_limit)
  ▼
充电电流被钳在 1024mA（电表偏移后显示 ~1038mA）
```

**关键佐证数据**：

| TCHG state | CHGL 步数 | 理论限流 | 手动实测充电电流 |
|---|---|---|---|
| 0 | 255 (0xFF) | 解除（16320mA） | 2.4~4.6A ✓ |
| 1 | 24 | 1536mA | 1538mA ✓ |
| 2 | 16 | **1024mA** | 987~1039mA ✓（=故障时的恒定值） |
| 3 | 8 | 512mA | 530mA ✓ |

**为什么"卡住"永远不好**：
1. EC 的 `user_current_limit` 没有任何 EC 内部清除路径，只在收到新的 host 写入时变化
2. ACPI 的 `PPPC`（get state）逻辑：`AC在线 → return 0；不在线 → return 3`，**从不反映真实状态** → thermald/内核视角永远是 0，与 EC 实际状态失同步
3. thermald 见温度仍在阈值上就持续写 2；写 0（解除）要等它的判定条件回落，而且由于 2 的存在写 0 后 EC 里可能仍是 2 的残留（直到下一次成功写入）

## 3. 排除过的其他假说（节省后来者时间）

| 假说 | 排除依据 |
|---|---|
| PD 协商/充电器/线材问题 | partner source-caps 完整（5/9/12/15/20V），合同 20V/3A；EC `chg_input_current=2800~3250mA` 正常 |
| 电池 BMS 低温降额 | 直读电池（EC I2C 直通，SBS 0x14）：凉电池(28°C)时 BMS 仍请求 4634mA，而 EC 只给 1024 —— 是 EC 侧钳制 |
| EC 内部热限流 / 电池温度 | EC 温度传感器 44-51°C 与限流无相关性；限流值恒定不随温度波动 |
| TCHG 被内核热管理触发 | 所有 /sys/class/thermal/thermal_zone* 均无 cdev 绑定，step_wise 管不到它 |
| MrChromebox ECRW 固件 bug | EC 的 charge control 状态全程正常（mode=NORMAL, sustain=-1/-1）；限流写入有明确 host 侧来源 |
| tuned / power-profiles-daemon | tuned 无 thermal 插件；ppd 未安装（Fedora 44 用 tuned-ppd） |

## 4. 诊断方法学（可直接复用）

按顺序做，前 3 步 10 分钟内能把问题定性：

1. **确认 PD 正常**：
   ```bash
   cat /sys/class/power_supply/CROS_USBPD_CHARGER0/{online,voltage_now,current_max}
   ```
2. **确认是恒定限流而非热/输入问题**：跑满载看 `current_now` 是否纹丝不动
3. **找 TCHG**：
   ```bash
   grep -l TCHG /sys/class/thermal/cooling_device*/type
   # 手动写 1/2/3 看电流阶梯（64mA步：1536/1024/512）：
   echo 2 | sudo tee $(grep -l TCHG /sys/class/thermal/cooling_device*/type | xargs dirname)/cur_state
   ```
4. **抓写入者**（关键一步，一行命令抓现行）：
   ```bash
   echo 'p:tchg int3403_set_cur_state state=%si:u64' | sudo tee /sys/kernel/debug/tracing/kprobe_events
   echo 1 | sudo tee /sys/kernel/debug/tracing/events/kprobes/tchg/enable
   # ...等待/复现（挂起恢复、插拔充电器、加负载）...
   sudo cat /sys/kernel/debug/tracing/trace | grep tchg:
   # 输出里 TASK-PID 一列就是写入者进程名（本例：thermald）
   ```
5. **深挖 EC 状态**（可选）：见附录 B 的 ectool.py，直读 EC 的
   `chg_current / chg_input_current / LIMIT_POWER`、电池期望电流、电池温度（I2C 直通），
   可区分"电池只要这么多" vs "EC 被钳"。

## 5. 修复与验证

```bash
sudo systemctl disable --now thermald     # 停止并禁止开机自启
```

验证（电量 20~80% 区间最准，>90% 有正常 CV 降流）：
```bash
cat /sys/class/power_supply/BAT0/current_now      # 应 >2,000,000 (2A)
upower -i /org/freedesktop/UPower/devices/battery_BAT0 | grep energy-rate
```

**修复后实测**：EC 充电电流 4608mA、实际 2.1~4.6A（随电量正常锥降）、BMS 请求 4634mA 全额满足。

**如需恢复 thermald**：`sudo systemctl enable --now thermald`

## 6. 禁用 thermald 安全吗？/ 性能模式还生效吗？

- **安全**。ChromeOS 设备的 EC 是热管理最终权威：风扇曲线、PROCHOT、充电保护、过热关机全部 EC 自管；AP 侧的 thermald 是给"Windows 笔记本装 Linux"补位的，在 Chromebook 上只会拿 DPTF 的保守阈值乱动。禁用后最坏情况是风扇策略少一层 AP 侧干预（EC 会自动兜底）。
- **GNOME 的电源模式（性能/平衡/省电）照常生效**，链路是 GNOME → tuned-ppd → tuned → cpufreq，与 thermald 无关：
  - performance → tuned `throughput-performance`：governor=performance、EPP=performance
  - balanced → `balanced`（插电）/ `balanced-battery`（电池）：EPP=balance_performance/balance_power
  - 实测切换即时生效；短时单线程基准差距 ~1%（EPP 主要影响持续多核负载、响应性和功耗）
  - 注意：本机无 platform_profile（不支持），性能模式不改变 EC 风扇曲线

## 7. 附：本例中的另一个问题——USB-C 显示器无视频

**现象**：USB-C 全功能线接显示器只充电、无信号。
**诊断**：热插拔后整条链路实际是通的（DP alt mode 协商成功、mux 切到 DP、HPD 拉高、DRM connector connected、4K@240Hz 可点亮）。故障发生在一个"老化"的系统会话里（typec/mux 状态卡死）。
**解决**：重启后正常。若复发（尤其挂起恢复后），执行模块顺序修复（Fedora 已知问题，RH bugzilla 2192574）：
```bash
# 临时：按正确顺序重载
sudo modprobe -r cros_ec_typec intel_pmc_mux
sudo modprobe intel_pmc_mux && sudo modprobe cros_ec_typec
# 永久：
echo 'softdep cros_ec_typec pre: intel_pmc_mux' | sudo tee /etc/modprobe.d/cros-typec.conf
sudo dracut -f
```

## 8. 附录 A：本机环境快照（对照用）

- 主板：Google Redrix（HP Elite Dragonfly Chromebook，Brya 家族）
- 固件：MrChromebox-2609.2；EC RW：`redrix_v2.0.27867 redrix_16238.2+tbt5 2026-09-12`（Nuvoton NPCX993F）
- 充电芯片：TI BQ25720（电池检流电阻 10mΩ）
- 电池：DK04050XL（DynaPack 333-2C-14-A，设计 6620mAh/7.7V，6 循环）
- DPTF：TSR0 触发点 45.05°C、TSR1 51.05°C；TCHG PPSS 阶梯 1536/1024/512mA

## 9. 附录 B：工具（~/chromebook-fixes/tools/）

- **ectool.py** —— 只读 EC 诊断工具（ioctl 直通 /dev/cros_ec），用法：
  ```bash
  sudo python3 ectool.py              # 全量 dump（充电状态/电池/EC温度/PD）
  sudo python3 ectool.py --csv        # 单行：充电电流,输入限流,电池温度,BMS请求电流,BMS请求电压
  sudo python3 ectool.py --watch      # 每 2s 刷新
  sudo python3 ectool.py --clear-current-limit   # 清 EC 充电限流（0xFFFFFFFF）
  ```
  电池 I2C 直通端口在本机为 5（`I2C_PORT_BATTERY`），换机型需查板文件。
- **batt_logger.sh** —— 每分钟记录到 CSV（根后台运行：`sudo nohup ./batt_logger.sh &`）
- **drain_battery.sh** —— 强制放电到目标电量（配合 charge_behaviour）

**关键 EC host 命令号**：0x0096 CHARGE_CONTROL、0x0097/98 CONSOLE、0x009E I2C_PASSTHRU、0x00A0 CHARGE_STATE、0x00A1 CHARGE_CURRENT_LIMIT、0x0121 GET_UPTIME_INFO
**ioctl**：`CROS_EC_DEV_IOCXCMD = _IOWR(0xEC, 0, struct cros_ec_command)` = 0xC014EC00
**SBS 电池寄存器**：0x08 温度(0.1K)、0x0A 电流、0x14 期望充电电流、0x15 期望充电电压

## 10. 附录 C：给第二台机器的 Agent 操作清单（充电部分）

> 把本节直接粘贴给 agent 即可复现整套诊断。

1. 读 `/sys/class/power_supply/BAT0/current_now` 和 `capacity`，确认慢充且电量在 20-80%。
2. `grep -l TCHG /sys/class/thermal/cooling_device*/type` —— 找到 TCHG cdev（若没有，本报告不适用）。
3. `echo 2 | sudo tee <该cdev>/cur_state`，5 秒后读 current_now —— 若降到 ~1A，即同一 bug。
4. `echo 0 | sudo tee <该cdev>/cur_state` —— 电流应恢复（EC 限流被清除）。
5. kprobe 抓写入者确认（见第 4 节第 4 步），预期抓到 `thermald`。
6. 修复：`sudo systemctl disable --now thermald`；再写一次 cdev 0 清残留。
7. 验证：电量 20-80% 时 current_now > 2A；观察 30 分钟无回落。
8. （可选）`sudo python3 ~/chromebook-fixes/tools/ectool.py --csv` 复核 EC 视角：chg_current 应≈BMS 请求电流。
9. 若 TCHG 手动写入不改变电流 → 另查：PD 合同、电池 BMS 请求（SBS 0x14 + 温度 0x08）、EC CHARGE_STATE。

---

*问题一诊断全程记录：upower 功率历史、EC host 命令直读、ACPI 反编译（SSDT 的 PPSS/SPPC/PPPC/CHGS）、ftrace kprobe 抓现行、对照实验（TCHG 阶梯映射/电池加温/强放复位）。快照数据：~/chromebook-fixes/tools/charge_log_snapshot_20261027.csv*

---

# 问题二：audio fix 装完扬声器正常，但 GNOME 设置里看不到麦克风（默认麦克风还是哑的）

> 音频栈：SOF firmware 2.2.0（intel/sof/community/sof-adl.ri）+ 拓扑 sof-adl-max98390-rt5682.tplg
> 用户态：PipeWire 1.6.10 / WirePlumber 0.5.18 / alsa-ucm 1.2.16（全部 Fedora 官方包）
> 诊断日期：2026-10-27

## TL;DR

**症状**：网上 audio fix 装完，扬声器/耳机能出声；GNOME 设置 → 声音里看不到输入设备，或能看到"内置麦克风 2"但电平条不动、录音是哑的。

**根因**（两个独立问题叠加，都要处理）：
1. **GNOME 显示层缓存**：设置面板/gnome-shell 用 GVC（libpulse）维护设备列表，补丁生效前打开的会话里是旧状态。重开设置或注销重登即可看到——不是 PipeWire 的问题（PipeWire/WirePlumber 层实测完全正常）。
2. **默认选中的是死通道**：redrix 的 DMIC PCM（hw:0,99）是 4 声道，PipeWire 1.6 的 `api.alsa.split` 特性把它拆成"内置麦克风 1"（AUX0/1）和"内置麦克风 2"（AUX2/3）两个 source。**实测只有 Mic1 接了真麦克风，Mic2 是恒定 ~½ 满幅的 DC 死电平**；WirePlumber 两条 route 优先级相同（100），默认挑了 Mic2。

**修复**（一行，已在本机执行，WirePlumber 自动持久化到 `~/.local/state/wireplumber/default-nodes`）：

```bash
pactl set-default-source alsa_input.pci-0000_00_1f.3-platform-adl_rt5682_def.HiFi__Mic1__source
```

## A. 本机音频链路快照（对照用）

- 声卡：`sof-rt5682`（hw:0），驱动 `snd_soc_sof_rt5682`，machine driver `adl_rt5682_def`
- 固件/拓扑均为 Fedora 官方包（`alsa-sof-firmware` 2025.12.2），**无需手动装任何固件**
- PCM 布局：0=Speakers，1=Headset(录+放)，2–5=HDMI，6=EchoRef，7=Bluetooth，**99=DMIC(4ch)**，100=DMIC16kHz
- UCM：官方 `sof-rt5682/HiFi.conf` 定义 Mic1/Mic2 两个 SectionDevice，都映射到 PCM99（这是 4 声道拆两路的来源）
- dmesg 关键行：`DMICs detected in NHLT tables: 0`（MrChromebox 固件无 NHLT 表 → 这就是补丁要强制 dmic_num=4 的原因）

## B. 网上"audio fix"实际改了什么（拆解，已备份至 `audio/` 目录）

补丁不装固件，只留下 3 个不属于任何 RPM 包的配置（已全部收入本仓库 `audio/` 目录，可通过 `./audio/install.sh` 一键部署）：

| 部署位置 | 仓库备份文件（`audio/`） | 内容与作用 |
|---|---|---|
| `/etc/modprobe.d/adl-sof.conf` | `adl-sof.conf` | `options snd_sof_intel_hda_generic dmic_num=4`：无 NHLT 时 SOF 不知道 DMIC 数量；强制暴露 4 通道 DMIC PCM（hw:0,99）。**没有它连麦克风 PCM 都不出现** |
| `/etc/wireplumber/wireplumber.conf.d/51-disable-pro-audio.conf` | `51-disable-pro-audio.conf` | sof/avs/acp 卡 `api.acp.disable-pro-audio=true`：防止 UCM 声卡被自动切到 Pro Audio profile（设备名/路由会全乱） |
| `/etc/wireplumber/wireplumber.conf.d/51-increase-headroom.conf` | `51-increase-headroom.conf` | alsa_output 节点 `api.alsa.headroom=2048`：加大 ALSA 缓冲防爆音 |
| `/etc/wireplumber/wireplumber.conf.d/52-disable-mic2.conf`（可选） | `52-disable-mic2.conf` | 将恒定 DC 死电平的 `HiFi__Mic2__source` 设为 `node.disabled = true`（传 `--hide-mic2` 安装） |

注意：SOF 固件、拓扑、UCM 全部用 Fedora 官方包即可；不要再拿 chrultrabook 之类脚本往 `/lib/firmware` 里覆盖东西。

## C. 根因细节（每一环都有实证）

1. **PipeWire 层健康**：`pw-dump` 可见设备 9 条 EnumRoute（含 `[In] Mic1`/`[In] Mic2`，available）；`pactl list sources` 可见 3 个非 monitor source（Mic1/Mic2/Headset Microphone），描述、Active Port 齐全 → GNOME 看不到纯属显示层缓存。
2. **Mic2 死通道实测**：`arecord -D hw:0,99 -c 4` 逐通道统计——ch0/1 `max≫avg`（真实信号），ch2/3 `avg≈max≈1.03e9`（S32 满幅 2.1e9 的一半，恒定 DC）→ 硬件未接麦克风。
3. wpctl 里 Mic1/Mic2 显示为 `loopback-*` filter 节点：这是 PipeWire 1.6 `api.alsa.split` 的新行为（多声道 UCM PCM 拆成立体声节点），**正常现象，别当成故障去修**。

## D. 诊断方法学（可直接复用）

1. 内核层：`cat /proc/asound/cards; arecord -l`（应有 `device 99: DMIC`）；`journalctl -k | grep -iE 'sof|dmic'`（firmware/topology 加载无 error）
2. **硬件层逐通道判活**（关键一步）：
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
   判读：`max ≫ avg`（>10 倍）= 活通道；`avg ≈ max` 且数值巨大 = DC 死通道。
3. 用户态：`pactl list short sources | grep -v monitor`；`pactl get-default-source`（默认是谁？）
4. 策略层：`wpctl status` / `pw-dump`（看 EnumRoute）。route、source 都在而 GNOME 不显示 → 显示层缓存，重开设置/注销重登。

## E. 修复与验证

必需（一行）：

```bash
pactl set-default-source alsa_input.pci-0000_00_1f.3-platform-adl_rt5682_def.HiFi__Mic1__source
```

可选（隐藏死掉的"内置麦克风 2"，纯体验优化，需 sudo）：

```bash
sudo tee /etc/wireplumber/wireplumber.conf.d/52-disable-mic2.conf <<'EOF'
monitor.alsa.rules = [
  { matches = [ { node.name = "alsa_input.pci-0000_00_1f.3-platform-adl_rt5682_def.HiFi__Mic2__source" } ]
    actions = { update-props = { node.disabled = true } } }
]
EOF
systemctl --user restart wireplumber pipewire pipewire-pulse
```

验证：

```bash
timeout 6 parecord --file-format=wav /tmp/mic.wav    # 录的时候对着机器说话
# 用 D-2 的 python 片段分析：max 应有几千以上、avg 远小于 max（说话时应大一个数量级）
```
GNOME 设置 → 声音 → 输入：选"内置麦克风 1"，说话电平条应跳动。
若重启后设置里又看不到 mic：注销重登即可（GNOME 面板缓存行为，PipeWire 侧状态不受影响）。

## F. 附录 D：给第二台机器的 Agent 操作清单（音频部分）

> 把本节直接粘贴给 agent 即可复现整套诊断。

1. `cat /proc/asound/cards; arecord -l` —— 没有 `device 99 DMIC`？先确认 `/etc/modprobe.d/adl-sof.conf`（`dmic_num=4`）存在，没有就创建并重启。
2. `journalctl -k | grep -iE 'sof|dmic'` —— firmware/topology 应正常加载（sof-adl-max98390-rt5682.tplg）。
3. 按 §D-2 录 4 通道并逐通道判活，找出"活"的声道对（本机为 AUX0/1 → Mic1）。
4. `pactl list short sources | grep -v monitor` —— 记下活通道对应的 source 名（`HiFi__Mic1__source` / `HiFi__Mic2__source`）。
5. `pactl set-default-source <活的那个>`；`timeout 6 parecord` + 逐通道统计复核有声音。
6. GNOME 不显示输入设备 → 重开设置/注销重登（与 PipeWire 无关，不要动音频栈）。
7. （可选）按 §E 的 `52-disable-mic2.conf` 模板隐藏死通道 source（把 node.name 换成死的那路）。

---

*问题二诊断全程：SOF dmesg / UCM conf 对照、hw:0,99 四通道逐通道统计（发现 AUX2/3 为 DC 死电平）、pw-dump EnumRoute 审计、pactl/pa 层核对、GVC（libgnome-volume-control）源码核对设备列表构建逻辑、parecord 端到端验证。默认 source 已持久化：~/.local/state/wireplumber/default-nodes*

---

# 问题三：Flatpak Chrome 摄像头不可用 + 画面偏绿（IPU6 + OV5675）

> 摄像头栈：ov5675（MIPI CSI）→ Intel IPU6 → libcamera simple 管线（软 ISP）→ PipeWire → Chrome Flatpak
> 诊断日期：2026-10-27。硬件/内核/PipeWire 全部正常（`cam -c1 --capture=8` 实测 30fps、2592×1944 出图正常），问题全在应用接入层和色彩调校。

## TL;DR

**症状**：
1. Chrome（Flatpak 版）里摄像头完全不可用/黑屏，授权弹窗也弹不出来
2. 打通后画面明显偏绿/偏紫、颜色像水洗过

**根因**（三层独立问题叠加，都要处理）：

1. **Flatpak Chrome 默认不走 PipeWire 摄像头**：IPU6 的 32 个 `/dev/video*` 节点都是原始 Bayer 输出，应用只能经 PipeWire/libcamera 使用；Chrome 的 PipeWire camera 支持（Chromium M127+）默认关闭。
2. **xdg-desktop-portal-gnome 焦点检查 bug 弹不出授权框**：journal 里 `Only the focused app is allowed to show a system access dialog`（flatpak/xdg-desktop-portal#1338），弹窗失败还可能被记成"已拒绝"。
3. **libcamera 没有 ov5675 的调校文件**：回落到 `uncalibrated.yaml`——黑电平靠场景猜（猜错全砸到红通道增益上 → 偏绿）、无色彩校正矩阵（颜色寡淡）。

**修复**（三步）：

```bash
# 1. Chrome: 地址栏 chrome://flags/#enable-webrtc-pipewire-camera → Enabled → 重启
# 2. 免弹窗预授权（绕开 portal 焦点 bug）：
flatpak permission-set devices camera com.google.Chrome yes
# 3. 装原厂色彩调校（从本机对应 ChromeOS 镜像提取，见下节）：
sudo install -m 644 ~/chromebook-fixes/camera/ov5675-clean.yaml \
    /usr/share/libcamera/ipa/simple/ov5675.yaml
systemctl --user restart wireplumber pipewire
```

## A. 最终生效的配置

| 位置 | 内容 | 说明 |
|---|---|---|
| `/usr/share/libcamera/ipa/simple/ov5675.yaml` | 黑电平 4122 + 原厂 CCM（7 组色温 2300–6441K） | 不属于任何 rpm，系统升级不会覆盖；若删除则回落 uncalibrated.yaml 重新偏绿 |
| `flatpak permission-set devices camera com.google.Chrome yes` | Chrome 免弹窗授权 | 绕开 portal 焦点 bug |
| Chrome flag `#enable-webrtc-pipewire-camera` | Enabled | IPU6 摄像头必须走 PipeWire |

测试页：`https://mozilla.github.io/webrtc-landing/gum_test.html`，设备选 ov5675。
GNOME Snapshot 走同一 PipeWire 链路，可用来交叉验证。

## B. 原厂调校数据从哪来（本机专属，非借用）

ChromeOS 恢复镜像 `chromeos_16836.19.0_brya_recovery_stable-channel_BryaMPKeys-v23.bin`
（recovery.json 里 hwidmatch `^REDRIX-CLQY` = 本机）rootfs 的 `/etc/camera/ov5675.aiqb`，
用 `camera/parse_aiqb.py`（libcamera patchwork #26761 的 AIQB 解析器）提取 record id=25 的
7 组色温 CCM。黑电平 4122 = 盖镜头抓 RAW 实测 64.0（10-bit）× 64。

提取路径备忘（需要时重做，镜像 ~2.65GB 下载后即删）：
```bash
# 挂载 rootfs（分区表 fdisk -l 看 ROOT-A 起始扇区 ×512）
sudo mount -o ro,loop,offset=<ROOT-A起始字节>,noload -t ext4 <镜像.bin> /mnt
cp /mnt/etc/camera/ov5675.aiqb .
python3 parse_aiqb.py ov5675.aiqb --sensor-name ov5675
```

## C. 验证标准（白纸法）

```bash
# 白纸正对摄像头 20-30cm 填满画面，连抓 60 帧取尾帧（AGC/AWB 收敛需 ~2 秒）
timeout 40 cam -c1 --capture=60 --file=w_#.ppm
magick w_cam0-stream0-000059.ppm -set colorspace sRGB -colorspace RGB \
  -format "G/R=%[fx:mean.g/mean.r] G/B=%[fx:mean.g/mean.b]\n" info:
# G/R、G/B 越接近 1.000 越中性。修复前 ~1.10（明显偏绿），修复后 ~1.04-1.07（纸的色差范围内）
```

带增益日志：`LIBCAMERA_LOG_LEVELS='IPASoftAwb:0'`，健康增益 R≈1.6-1.7 / B≈1.25-1.30
（与 RAW 直算及原厂 AIQB 数据吻合；R 或 B 顶到 4.0 说明统计环节出问题）。

## D. 经验与坑（重要！）

1. **libcamera 0.7.2 原版的 soft-AWB 统计已经是正确的**（`swstats_cpu.cpp` 的
   `finishFrame()` 里 `sum_ >>= sumShift_`，解包 10-bit 路径 sumShift_=2，已做 8-bit 缩放）。
   Latitude 7320 项目针对 0.7.0 的 `0002-soft-stats-scale-sums-to-8-bit.patch` 在 0.7.2 上会
   **双重除法**导致白平衡增益爆炸（R 通道顶死 4.0、画面通红）——已实测踩坑并回滚，勿再套用。
2. 传感器确认 `sensor_type="BAYER" bayer_order="GRBG"`（graph_settings_ov5675.xml），
   无 RGB-IR 特殊阵列；`IPU6 in secure mode` 内核日志无害；IR 人脸摄像头无驱动（只有主摄可用）。
3. 抓帧测试必须：① 白纸确认在位 ② 连抓 ≥60 帧取尾帧。8 帧/12 帧短连发会被 AGC/AWB
   过渡期污染，得出鬼数据。
4. /tmp 是 tmpfs（7.8G），每帧 PPM 15MB，60 帧连发注意清理。
5. V4L2 原生程序（RPM 版 Zoom 等）可用 `LD_PRELOAD=/usr/libexec/libcamera/v4l2-compat.so` 启动兼容。

## E. 已知残留限制：背光白平衡跑偏

**阴天背光（坐在落地窗前）白平衡会跑偏**：软 ISP 的灰度世界 AWB 对整帧求均值，
大面积冷色窗户主导统计 → 色温估计偏向窗光 → 前景人像偏色。这是 simple 管线 AWB
算法的固有限制（无 Bayesian/gamut AWB），调校和升级 libcamera 都无法根治。
缓解：视频通话时开室内前向补光，别让窗户占画面主导。

**源码级定性与出路**（0.7.2 实读）：`awb.cpp` 是纯灰度世界（全帧统计、无空间加权），
`ccm.cpp` 色温超表后钳制在 6441K 档——背光发绿有两个候选机理（增益被窗户带偏 vs CCM 选档错），
可用"RAW 地面真值 + 增益日志"诊断分辨。软 ISP 侧修复选项：中央加权 stats 补丁 / 高色温 CCM 档。
终极选项为**硬件 ISP（PSYS）路线**，可行性勘测见 `camera/hw-isp-recon.md`
（结论：可行、中风险、DKMS 只补 intel-ipu6-psys.ko 一个模块，ov5675 的 aiqb 已在手，
graph_settings 需从 ChromeOS 镜像重提；与软 ISP 栈并存不冲突）。

## F. 附录 E：给第二台机器的 Agent 操作清单（摄像头部分）

> 把本节直接粘贴给 agent 即可复现整套诊断。

1. `cam -l` 确认 libcamera 能列出摄像头；`cam -c1 --capture=8` 抓帧确认硬件链路通。
2. `flatpak list | grep -i chrome` 确认是 Flatpak 版 → 沙箱读不了 IPU6 原始节点，必须走 PipeWire。
3. 检查 Chrome flag：`Local State` 的 `browser.enabled_labs_experiments` 是否含
   `enable-webrtc-pipewire-camera@1`（或让用户手动开）。
4. `journalctl --user -u xdg-desktop-portal | grep -i denied` —— 见
   "Only the focused app is allowed to show a system access dialog" 即焦点 bug，
   用 `flatpak permission-set devices camera com.google.Chrome yes` 预授权绕开。
5. `journalctl -b | grep -i 'falling back.*uncalibrated'` 或抓帧日志见
   "Configuration file '<sensor>.yaml' not found" → 缺调校，按 §B 从对应 ChromeOS
   镜像提取 AIQB（hwid 用 DMI product_name 在 recovery.json 里反查）。
6. 白纸法验证（§C）：偏色即调校问题；增益顶 4.0 即统计问题（对照 §D-1 检查是否误打了旧 patch）。
7. 重启桌面栈生效：`systemctl --user restart wireplumber pipewire`。

---

*问题三诊断全程：cam 抓帧 30fps 验证硬件、portal DBus 内省、Chrome 二进制 flag 字符串核对、
ChromeOS 恢复镜像 rootfs 提取 AIQB（/dev/video16 偏移挂载）、parse_aiqb.py 解析 7 组色温 CCM、
盖镜头 RAW 暗帧实测黑电平 64.0、白纸线性域通道统计迭代验证、AWB 增益日志与 RAW 地面真值对质、
swstats 源码级定位双重除法假修复并回滚。资产：~/chromebook-fixes/camera/（ov5675.aiqb / ov5675-clean.yaml / parse_aiqb.py）*

---

# 问题四：自动屏幕亮度怪异（变化不线性 + 暗光下依然很亮、GNOME 亮度滑块拉满）

> 背光与传感器栈：BOE 2678 eDP 面板 → `intel_backlight`（raw PWM 0–96000）+ TI OPT3001 环境光传感器 → `cros-ec-light` (`iio:device0`) → `iio-sensor-proxy` → `gsd-power` → `gnome-shell` (`BrightnessManager`) → `libmutter` (`MetaBacklightSysfs`)
> 诊断日期：2026-11-01。BIOS / EC 固件与传感器硬件本身完全正常，无需重刷固件；故障由 GNOME 50 自动亮度架构缺陷、线性 PWM 映射以及 EC 采样率配置共同导致。

## TL;DR

**症状**：
1. 开启"自动屏幕亮度"后，体感屏幕亮度变化非常不线性（低亮度区一跳一大截、高亮度区几乎没感觉，且调整时一顿一顿不丝滑）。
2. 在暗光环境下（如夜间 8–10 lux 昏暗室内）屏幕依然很亮（硬件背光高达 `~40000/96000` 甚至直接顶到 `94640/96000`），且点开 GNOME 右上角菜单看到**屏幕亮度滑块是拉满的（接近 100%）**。

**根因**（四层问题叠加，每一层均有反汇编/源码实证）：
1. **GNOME 50 (`brightnessManager.js`) 把亮度滑块改成了"固定偏移量（Bias）"且不再随自动亮度同步位置**：
   开启自动亮度（`_abTarget >= 0`）后，`gnome-shell` 只写硬件背光而不更新 UI 滑块 `scale.value`，计算公式为 `target = clamp(_abTarget + scale.value - 0.5, 0.0, 1.0)`。本机开机初始背光缓存在 `94640/96000`（`98.6%`），导致右上角滑块永远停在近 `100%`（拉满），同时向自动亮度**恒定硬加 `+48.6%`（`0.986 - 0.5`）的偏置**——哪怕全黑下自动亮度目标算出来是 `0%`，屏幕最低也有近 `50%` 亮度；只要自动亮度目标达 `50%`，屏幕直接 `100%` 拉满。
2. **`gsd-power` 采用"动态相对归一化"而非绝对照度曲线，暗光下极易把微光定义为满亮度基准**：
   反汇编 `/usr/libexec/gsd-power` 证实：每当刚开机登录或用户手动动了一下亮度滑块（触发 `BrightnessChanged`），`gsd-power` 就会执行 `Normalizing light level`，将满亮度基准值设为 `ambient_norm_value = 当前 lux × 1.5`，并把初始目标设为 `66.7%` (`100 / 1.5`)。若在暗光（如 `2~3 lux`）下开机或嫌亮手动拉滑块，系统立刻把 `3~4.5 lux` 当成 `100%` 满亮度标准，稍微一点屏幕反光跳到 `4~5 lux` 就直接输出 `100%` 满亮度。
3. **`intel_backlight` 是纯线性 PWM（`scale: unknown`），GNOME 未做人眼幂律（Gamma 2.2）校正**：
   对照 ChromiumOS 官方 `powerd`（`internal_backlight_controller.cc`）源码：当 `scale` 为 `unknown` 且 `max_brightness >= 100`（本机为 `96000`）时，ChromeOS 强制使用 `kDefaultLevelToPercentExponent = 0.5`（即百分比转硬件 PWM 为 $p^{2.0\sim 2.2}$ 幂函数）。而 GNOME 50 使用 1:1 纯线性映射，导致 `20%` 硬件 PWM 在人眼看来已有 `~48%` 亮度、`40%` 硬件 PWM（`38485/96000`）在暗室下人眼感知高达 `~68%` 亮度，且低亮度区稍微变化就引起体感剧烈跳变。
4. **EC 传感器默认 `EC_RATE = 0`（`buffer/hwfifo_timeout = 0`）且无过渡动画**：
   通过 `/dev/cros_ec` 发起 `EC_CMD_MOTION_SENSE_CMD (0x002B)` 实测：虽然 `SENSOR_ODR` 为 `1000 mHz` (1Hz)，但 `EC_RATE` 为 `0`，且 GNOME 的 `setBacklight()` 是单步瞬时写入，没有平滑插值过渡，造成 1Hz 阶跃感。

**修复**（一键脚本，已在本机执行并持久化）：

```bash
~/chromebook-fixes/brightness/install.sh
```

---

## A. 本机背光与环境光传感器（ALS）链路快照

| 组件 | 路径 / 接口 | 本机实测值与特性 |
|---|---|---|
| 内置面板 | `/sys/class/drm/card1-eDP-1` | BOE 2678（2256×1504 @ 60Hz/40Hz，3:2） |
| 背光接口 | `/sys/class/backlight/intel_backlight` | `type: raw`，`max_brightness: 96000`，Mutter `min: 960`，`scale: unknown`（纯线性 PWM） |
| 环境光传感器 | `/sys/bus/iio/devices/iio:device0` | `name: cros-ec-light`，`id: 3`，`label: accel-camera`（位于屏幕上方摄像头旁） |
| ALS 硬件芯片 | EC `MOTIONSENSE_CMD_INFO` (sensor 3) | `chip: 20` = **TI OPT3001**，硬件支持频率 `0.149 Hz` / `1.000 Hz` |
| EC 采样参数 | `SENSOR_ODR` (subcmd 3) / `EC_RATE` (subcmd 2) | 默认 `SENSOR_ODR=1000` (1Hz)，但 `EC_RATE=0`（对应 `buffer/hwfifo_timeout=0.000000`） |

---

## B. 根因链条与反汇编 / 源码级实证

### 1. `gsd-power` 反汇编实证（相对归一化算法缺陷）

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

### 2. `gnome-shell` (`brightnessManager.js`) 源码实证（滑块拉满与 `+0.5` 偏移）

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

### 3. 对照 ChromiumOS 官方 `powerd` 源码（为什么 ChromeOS 体感线性舒适）

核对 ChromiumOS `platform2/power_manager/powerd/policy/internal_backlight_controller.cc`：
- ChromeOS 定义 `kDefaultLevelToPercentExponent = 0.5`，当 sysfs `scale` 为 `unknown` 且 `max_level >= 100` 时自动启用非线性幂律映射：
  $$\text{hw\_level} = \text{min} + (\text{max} - \text{min}) \times \text{percent}^{\gamma} \quad (\gamma = 2.0 \sim 2.2)$$
- 在 $\gamma = 2.2$ 下，`43%` 的人眼感知亮度对应硬件 PWM 为 `15970 / 96000`（`16.6%` 物理占空比），而非线性映射下的 `41600 / 96000`，低亮度区细腻度提升近 3 倍。

---

## C. 排除过的假说与验证记录

| 假说 | 验证方法与结论 |
|---|---|
| BIOS / EC 固件损坏需重刷 | 直通 `/dev/cros_ec` 读 `MOTIONSENSE_CMD_INFO/DATA/RANGE`，OPT3001 传感器工作正常，无需动固件 |
| 写 `in_illuminance_calibscale` 放大 EC 读数 | 反汇编 `cros_ec_light_prox.ko` 确认写 `calibscale` 对应 `MOTIONSENSE_CMD_SENSOR_RANGE (0x04)`（高 16 位整数、低 16 位 `1/10000` 小数），但 Redrix EC 的 `opt3001` 驱动在读取 `in_illuminance_input` 时直接返回 lux 整数，不受 `SENSOR_RANGE` 倍率影响；必须在用户态做连续对数曲线映射 + EMA 浮点滤波 |
| 外部程序直接写 sysfs 会触发 GNOME 滑块同步 | 反汇编 `libmutter-18.so` (`meta_backlight_sysfs_new`) 确认 Mutter 仅监听 `udev` 事件，而内核写 `intel_backlight/brightness` 不发 uevent；且 `brightnessManager.js` 的 `syncWithBacklight()` 在 `_inhibitUpdates=true` 下不置 `_scaleChanged`，不会更新 `_globalScale`。必须通过 GNOME Shell 扩展在进程内同步 `_globalScale` 或调用 `DisplayConfig.SetBacklight` |

---

## D. 最终修复架构与部署明细

整套修复保存在 `~/chromebook-fixes/brightness/`，由以下 4 部分组成：

| 部署位置 | 源文件（`~/chromebook-fixes/brightness/`） | 作用 |
|---|---|---|
| `/etc/udev/rules.d/99-redrix-als.rules` | `99-redrix-als.rules` | 激活 `cros-ec-light` `sampling_frequency=1.000000` 与 `buffer/hwfifo_timeout=1.000000`（设置 `EC_RATE=1000ms`），并开放 `intel_backlight/brightness` `0666` 高频平滑写入权限 |
| `dconf` (`ambient-enabled=false`) | `install.sh` 自动设置 | 彻底关闭 `gsd-power` 有缺陷的相对归一化算法 |
| `~/.local/share/gnome-shell/extensions/redrix-auto-brightness@local/` | `redrix-auto-brightness@local/{metadata.json,extension.js}` | **GNOME Shell 原生扩展**：重写 `MonitorBrightnessScale` 为 $\gamma=2.2$ 感知线性曲线（手动拉滑块/快捷键同样生效），拦截 `SetAutoBrightnessTarget`，内置对数照度自动亮度 + 80ms 步进渐变，并实时同步右上角亮度滑块位置 |
| `~/.config/systemd/user/redrix-auto-brightness.service` + `~/.local/bin/redrix-auto-brightness` | `redrix-auto-brightness.service` + `redrix-auto-brightness` | **当前会话即时生效守护服务**：在首次安装尚未注销重登 GNOME Shell 时立即接管自动调光（50ms 丝滑步进 + 对数曲线 + $\gamma=2.2$ + 手动偏移记忆）；当检测到上述 GNOME Shell 扩展已处于 `ACTIVE` 状态时自动静默退出让位，绝不双开冲突 |

### 对数照度 → 感知亮度 → 硬件 PWM 映射对照表（$\gamma = 2.2$）

公式：$p_{\text{auto}}(L) = \text{clamp}(0.15 + 0.28 \times \log_{10}(L + 1.2),\ 0.12,\ 1.0)$，$\text{hw} = 960 + 95040 \times p^{2.2}$

| 环境场景 | 传感器照度 (lux) | 感知亮度百分比（GNOME 滑块位置） | 硬件 PWM (`intel_backlight`) | 物理占空比 |
|---|---|---|---|---|
| 全黑关灯 | `0 lux` | **17.2%** | `~2,940 / 96000` | 3.1% |
| 极暗夜灯 | `3 lux` | **32.5%** | `~8,960 / 96000` | 9.3% |
| 昏暗室内 | `9 lux` | **43.2%** | `~15,970 / 96000` | 16.6% |
| 普通室内灯光 | `30 lux` | **56.8%** | `~28,480 / 96000` | 29.7% |
| 明亮室内办公 | `100 lux` | **71.1%** | `~45,550 / 96000` | 47.4% |
| 靠窗 / 强室内光 | `300 lux` | **84.4%** | `~66,300 / 96000` | 69.1% |
| 户外 / 阳光直射 | `1000+ lux` | **100.0%** | `96,000 / 96000` | 100.0% |

> **手动微调机制**：任何时候手动拖动 GNOME 亮度滑块或按键盘亮度加减键，系统会立即停止当前渐变并计算 `userBias = 用户设定感知亮度 - 当前照度基准感知亮度`（范围 `±50%`），后续环境光变化时自动在您的个人偏好偏移基础上平滑调节。

---

## E. 附录 F：给第二台机器的 Agent 操作清单（自动亮度部分）

> 把本节直接粘贴给 agent 即可复现整套诊断与修复。

1. **确认背光与传感器节点**：
   ```bash
   grep -H . /sys/class/backlight/intel_backlight/{type,brightness,max_brightness,scale}
   for d in /sys/bus/iio/devices/iio:device*; do
     [ "$(cat $d/name 2>/dev/null)" = "cros-ec-light" ] && grep -H . $d/{in_illuminance_input,sampling_frequency,buffer/hwfifo_timeout}
   done
   ```
   预期：`intel_backlight` 为 `raw` / `96000` / `scale: unknown`；`cros-ec-light` 存在且未打补丁前 `buffer/hwfifo_timeout` 为 `0.000000`。
2. **若已有 `~/chromebook-fixes/brightness/` 目录，直接一键部署**：
   ```bash
   ~/chromebook-fixes/brightness/install.sh
   ```
3. **验证修复是否生效**：
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
4. **如需调整整体亮度曲线偏亮/偏暗**：
   修改 `~/chromebook-fixes/brightness/redrix-auto-brightness` 与 `redrix-auto-brightness@local/extension.js` 中的 `0.15 + 0.28 * log10(lux + 1.2)` 常数项（如把 `0.15` 改为 `0.20` 即可全局提亮 `5%` 感知亮度），然后重新运行 `~/chromebook-fixes/brightness/install.sh`。

---

## 本目录结构

```
chromebook-fixes/
├── AGENTS.md                                  ← AI Agent 结构化工作流入口（装机恢复 + 诊断索引）
├── README.md                                  ← 深度根因调查与排障手册（问题一/二/三/四）
├── tools/                                     ← EC/电池诊断工具（问题一配套）
│   ├── ectool.py                              ← 只读 EC 诊断（/dev/cros_ec ioctl 直通）
│   ├── batt_logger.sh                         ← 电池日志（每分钟 CSV）
│   ├── drain_battery.sh                       ← 强制放电脚本
│   └── charge_log_snapshot_20261027.csv       ← 诊断日快照数据
├── audio/                                     ← 音频与内置麦克风修复资产（问题二配套）
│   ├── install.sh                             ← 一键部署脚本（modprobe + WirePlumber + 默认 Mic1）
│   ├── adl-sof.conf                           ← 强制暴露 4 通道 DMIC PCM (dmic_num=4)
│   ├── 51-disable-pro-audio.conf              ← 禁用自动 Pro Audio profile
│   ├── 51-increase-headroom.conf              ← 增大 ALSA headroom 防爆音
│   └── 52-disable-mic2.conf                   ← （可选）隐藏死通道 Mic2
├── camera/                                    ← 摄像头调校资产（问题三配套）
│   ├── install.sh                             ← 一键部署脚本（安装 ov5675.yaml + Flatpak 预授权）
│   ├── ov5675.aiqb                            ← ChromeOS 原厂校准二进制
│   ├── ov5675-clean.yaml                      ← 最终调校（已部署到 /usr/share/...）
│   ├── parse_aiqb.py                          ← AIQB → SoftISP YAML 解析器
│   └── hw-isp-recon.md                        ← IPU6 硬件 ISP(PSYS)路线可行性勘测报告
└── brightness/                                ← 自动亮度与感知曲线修复资产（问题四配套）
    ├── install.sh                             ← 一键部署脚本（udev + 服务 + GNOME 扩展）
    ├── 99-redrix-als.rules                    ← udev 规则（激活 EC_RATE 1Hz + 背光权限）
    ├── redrix-auto-brightness                 ← 用户态平滑对数调光守护程序
    ├── redrix-auto-brightness.service         ← systemd 用户服务单元
    └── redrix-auto-brightness@local/          ← GNOME Shell 50 原生扩展（Gamma 2.2 + 滑块同步）
        ├── metadata.json
        └── extension.js
```
