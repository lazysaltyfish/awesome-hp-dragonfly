# IPU6 硬件 ISP(PSYS)路线可行性勘测报告

日期: 2026-10-27 · redrix(ADL-P, IPU6 PCI 8086:465d = **IPU6-v3 hw v5**)· Fedora 44, kernel 7.2.11
目的: 评估绕过软 ISP 灰度世界 AWB(背光场景跑偏)的硬件 ISP 路线。**纯勘测,未实施。**

## 结论先行

**可行,中风险,预计 2–4 小时上手(+ChromeOS 镜像重下提取配置)。**
整条链路每一环都有实证,最大不确定性是 HAL 对 ChromeOS 版 graph_settings 的兼容性——只能实测。

## 链路逐环核查(全部有据)

| # | 环节 | 状态 | 证据 |
|---|---|---|---|
| 1 | 内核 PSYS 驱动 | ✅ 可行 | 主线 Makefile 只有 isys;Intel `ipu6-drivers` DKMS 在 kernel ≥6.10 时**只编 `intel-ipu6-psys.ko`**(dkms.conf: `BUILT_MODULE_NAME[7]`,装 `/updates`),in-tree isys 保留,零冲突。psys 源码在 `drivers/media/pci/intel/ipu6/psys/`。社区在 7.x 内核上构建成功(Arch BBS 2026-07) |
| 2 | PSYS 辅助设备 | ✅ 已在 | 本机 `/sys/bus/auxiliary/devices/intel_ipu6.psys.40` 已枚举,dmesg `Failed to get runtime PM` = 就差驱动绑定 |
| 3 | 固件 | ✅ 有货 | `ipu6-camera-bins` 仓库 `lib/firmware/intel/ipu/` 含 `ipu6ep_fw.bin`(ADL)+ `ipu6epadln_fw.bin` + `unsigned/` 兜底(CSE 认证失败时用)。本机 dmesg 显示 CSE BOOT_LOAD/AUTHENTICATE_RUN 已通(secure mode 消息无害) |
| 4 | 闭源 3A/ISP 库 | ✅ 有货 | 同仓库整套 `-ipu6ep` 后缀库: `libia_aiq`(3A 核心)、**`libia_aiqb_parser`**(吃我们手里的 .aiqb)、`libia_cca`、`libgcss`(graph XML 解析)、`libbroxton_ia_pal` 等,部署即 `/usr/lib/` |
| 5 | HAL | ✅ 可编 | `ipu6-camera-hal` **开源**,cmake 构建 `-DIPU_VERSIONS="ipu6ep..."` 明确支持 ADL。本机依赖: cmake✓ gst-devel✓ libdrm-devel✓,缺 `libexpat-devel`(dnf 一条命令) |
| 6 | GStreamer 接入 | ✅ 可编 | `icamerasrc` 分支 `icamerasrc_slim_api`,gst 1.28 devel 已在 |
| 7 | ov5675 调优数据 | ⚠️ 半有 | `.aiqb` 已在 `~/chromebook-fixes/camera/`;`graph_settings_ov5675.xml` + 传感器描述 xml **需从 ChromeOS 恢复镜像重提**(2.65GB,~15min;或按 HAL 内 hi556 模板手写——同为 2592×1944 SGRBG10,极接近) |
| 8 | 应用接入(Chrome) | ⚠️ 需搭 | Chrome 不吃 GStreamer → 需 `v4l2loopback` 中转: `gst-launch icamerasrc ! v4l2sink` 常驻服务,PipeWire v4l2 monitor 自动把 loopback 暴露给 Chrome 设备列表。**RPM Fusion free 仓库当前未启用**(只有 nonfree),需启用或源码编 loopback |

## HAL 传感器接入机制(勘测中读懂的)

HAL 是**配置文件驱动**的,全部在 `/etc/camera/`:
- `<sensor>.aiqb` — 3A 调优(我们已有)
- `gcss/graph_settings_<sensor>.xml` — PSYS 管线图(PG 节点拓扑)
- `sensors/<sensor>.xml` — media graph 描述(format/link)+ 静态元数据 + 指向上两者
本机无 IVSC 依赖(摄像头直连 IPU6,mei_csi 不需要),无 NHLT 问题。

## 实施清单(如果要干)

```bash
# 0) ChromeOS 镜像重下,提 /etc/camera/ 全部 ov5675 相关文件
# 1) PSYS 内核模块
sudo dnf install dkms kernel-devel
sudo dkms add ./ipu6-drivers && sudo dkms install ipu6-drivers/0.0.0
ls /dev/ipu-psys0   # 应出现
# 2) 固件 + 闭源库(ipu6-camera-bins, 按 README 部署到 /usr/lib + /lib/firmware/intel/ipu)
# 3) HAL
sudo dnf install libexpat-devel automake libtool
cmake -DIPU_VERSIONS="ipu6ep" -DBUILD_CAMHAL_ADAPTOR=ON -DBUILD_CAMHAL_PLUGIN=ON ..
# 4) icamerasrc(分支 icamerasrc_slim_api)
# 5) 配置: /etc/camera/{ov5675.aiqb, graph_settings_ov5675.xml, sensors/ov5675.xml}
# 6) 验证: gst-launch-1.0 icamerasrc ! video/x-raw,NV12,1280x720 ! videoconvert ! ximagesink
# 7) 接入: v4l2loopback + systemd relay → Chrome 里选 loopback 设备
```

## 风险表(按概率排序)

| 风险 | 概率 | 缓解 |
|---|---|---|
| HAL 不认 ChromeOS 版 graph_settings(graph 类型/pg 版本差异) | 中 | hi556 模板手写 dispersed graph;或 HAL 源里参考 ov01a10 改 |
| 内核更新后 DKMS 编译失败(7.3+ API 变动) | 中 | DKMS 自动重建;失败时锁内核或手补 |
| CSE 固件认证失败 | 低 | `unsigned/` 固件兜底 |
| 睡眠唤醒后 PSYS 卡死 | 中 | relay 服务 Restart=on-failure + resume 后重启服务 |
| 中转服务 CPU 占用 | 低 | 720p30 ~2-5%(NV12 直通,无转换) |

## 与软 ISP 路线的关系

- 硬件路线**不替代**现有软 ISP 栈(libcamera/PipeWire 原样保留),两路并存:
  Chrome 默认仍走 ov5675(软 ISP + 原厂 CCM),需要最佳画质/背光场景时切 loopback 设备
- 软 ISP 侧的改进选项依然独立存在: 背光诊断实验(区分 AWB 增益带偏 vs CCM 钳 6441K)、
  中央加权 stats 补丁——本报告不排斥,只是用户选择了先勘测硬件路线

## 勘测依据来源

- 本机: `lspci`(465d)、`/sys/bus/auxiliary/devices/`、dmesg(CSE auth 通过、psys aux 存在)、
  bins 仓库完整文件树(GitHub API)、HAL 仓库文件树 + `config/linux/ipu6ep/sensors/hi556-uf.xml` 全文、
  ipu6-drivers 浅克隆(dkms.conf + Makefile + psys/ 源码在)
- 社区: Arch BBS 2026-07(DKMS 7.x 构建成功 + icamerasrc 工作流)、Ubuntu 26.04 指南(v4l2loopback relay 模式)、
  libcamera FAQ(IPU6 simple 管线支持现状)
