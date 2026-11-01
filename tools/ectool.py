#!/usr/bin/env python3
"""
Minimal ChromeOS EC diagnostic tool via /dev/cros_ec.
Requires root (device node is 0600). Read-only by default (unless --clear-current-limit or --set-current-limit is used).
Usage:
  sudo python3 ./tools/ectool.py                        # full dump
  sudo python3 ./tools/ectool.py --csv                  # single-line CSV metrics
  sudo python3 ./tools/ectool.py --watch                # live one-liners every 2s
  sudo python3 ./tools/ectool.py --clear-current-limit  # clear EC charge current limit
"""
import fcntl
import os
import struct
import sys
import time

IOCXCMD = 0xC014EC00  # _IOWR(0xEC, 0, struct cros_ec_command)

EC_CMD_CONSOLE_SNAPSHOT    = 0x0097
EC_CMD_CONSOLE_READ        = 0x0098
EC_CMD_CHARGE_STATE        = 0x00A0
EC_CMD_CHARGE_CURRENT_LIMIT = 0x00A1
EC_CMD_USB_PD_POWER_INFO   = 0x0103
EC_CMD_BATTERY_GET_STATIC  = 0x0600
EC_CMD_BATTERY_GET_DYNAMIC = 0x0601

CHARGE_STATE_CMD_GET_STATE = 0
CHARGE_STATE_CMD_GET_PARAM = 1

CS_PARAM = {
    "CS_PARAM_CHG_VOLTAGE": 0,
    "CS_PARAM_CHG_CURRENT": 1,
    "CS_PARAM_CHG_INPUT_CURRENT": 2,
    "CS_PARAM_CHG_STATUS": 3,
    "CS_PARAM_CHG_OPTION": 4,
    "CS_PARAM_LIMIT_POWER": 5,
}

EC_RES = {
    0: "SUCCESS", 1: "INVALID_COMMAND", 2: "INVALID_PARAM", 3: "ACCESS_DENIED",
    4: "INVALID_RESPONSE", 5: "INVALID_VERSION", 6: "INVALID_CHECKSUM",
    8: "UNAVAILABLE", 9: "TIMEOUT", 10: "OVERFLOW", 15: "BUSY",
}


class ECError(Exception):
    pass


class EC:
    def __init__(self, path="/dev/cros_ec"):
        self.fd = os.open(path, os.O_RDWR)

    def cmd(self, command, version=0, outdata=b"", insize=0):
        total = 20 + max(len(outdata), insize)
        buf = bytearray(total)
        struct.pack_into("<5I", buf, 0, version, command, len(outdata), insize, 0)
        buf[20 : 20 + len(outdata)] = outdata
        fcntl.ioctl(self.fd, IOCXCMD, buf, True)
        _, _, _, got, result = struct.unpack_from("<5I", buf, 0)
        if result != 0:
            raise ECError(
                "EC result %d (%s) for cmd 0x%04x v%d"
                % (result, EC_RES.get(result, "?"), command, version)
            )
        return bytes(buf[20 : 20 + got])


def charge_state(ec):
    p = bytearray(9)
    p[0] = CHARGE_STATE_CMD_GET_STATE
    r = ec.cmd(EC_CMD_CHARGE_STATE, 0, bytes(p), 20)
    ac, chg_v, chg_i, chg_in, soc = struct.unpack("<5i", r[:20])
    return {
        "ac_attached": ac,
        "chg_voltage_mV": chg_v,
        "chg_current_mA": chg_i,
        "chg_input_current_mA": chg_in,
        "batt_state_of_charge_pct": soc,
    }


def charge_param(ec, param):
    p = bytearray(5)
    p[0] = CHARGE_STATE_CMD_GET_PARAM
    struct.pack_into("<I", p, 1, param)
    r = ec.cmd(EC_CMD_CHARGE_STATE, 0, bytes(p), 4)
    return struct.unpack("<I", r[:4])[0]


def battery_dynamic(ec, index=0):
    r = ec.cmd(EC_CMD_BATTERY_GET_DYNAMIC, 0, bytes([index]), 14)
    v, i, rem, full, flags, dv, di = struct.unpack("<7h", r[:14])
    return {
        "voltage_mV": v,
        "current_mA": i,  # negative = discharging
        "remaining_mAh": rem,
        "full_mAh": full,
        "flags": flags,
        "desired_voltage_mV": dv,
        "desired_current_mA": di,
    }


def battery_static(ec, index=0):
    # uint16 dcap, uint16 dvlt, char[8] x4, uint32 cycle_count  (EC_COMM_TEXT_MAX=8)
    r = ec.cmd(EC_CMD_BATTERY_GET_STATIC, 0, bytes([index]), 40)
    design_cap, design_v = struct.unpack_from("<2H", r, 0)
    off = 4
    strings = []
    for _ in range(4):
        strings.append(r[off : off + 8].split(b"\x00")[0].decode(errors="replace"))
        off += 8
    cycle_count = struct.unpack_from("<I", r, 36)[0]
    return {
        "design_capacity_mAh": design_cap,
        "design_voltage_mV": design_v,
        "manufacturer": strings[0],
        "model": strings[1],
        "serial": strings[2],
        "chemistry": strings[3],
        "cycle_count": cycle_count,
    }


IOCRDMEM = 0xC107EC01  # _IOWR(0xEC, 1, struct cros_ec_readmem{offset,bytes,buffer[255]})

EC_CMD_I2C_PASSTHRU = 0x009E
EC_I2C_FLAG_READ = 0x8000
SB_ADDR = 0x0B  # smart battery 7-bit address


def i2c_sb_read(ec, port, reg, length=2):
    """Read a smart battery register via EC_CMD_I2C_PASSTHRU."""
    hdr = struct.pack("<BB", port, 2)
    m0 = struct.pack("<HH", SB_ADDR, 1)  # write: register index
    m1 = struct.pack("<HH", SB_ADDR | EC_I2C_FLAG_READ, length)
    out = hdr + m0 + m1 + bytes([reg])
    r = ec.cmd(EC_CMD_I2C_PASSTHRU, 0, out, 2 + length)
    if r[0] != 0:
        raise ECError(f"i2c status {r[0]:#x}")
    return r[2 : 2 + length]


def battery_smart_regs(ec, port):
    regs = {
        0x08: "temperature",
        0x09: "voltage",
        0x0A: "current",
        0x0C: "max_error",
        0x0D: "relative_soc",
        0x0F: "remaining_cap",
        0x10: "full_charge_cap",
        0x14: "charging_current",
        0x15: "charging_voltage",
        0x16: "battery_status",
        0x17: "cycle_count",
    }
    out = {}
    for reg, name in regs.items():
        raw = i2c_sb_read(ec, port, reg)
        val = struct.unpack("<h" if reg in (0x0A,) else "<H", raw)[0]
        out[name] = val
    out["temperature_C"] = round(out.pop("temperature") / 10.0 - 273.15, 1)
    return out


def memmap(ec, offset, nbytes):
    buf = bytearray(struct.pack("<II", offset, nbytes) + b"\x00" * 255)
    fcntl.ioctl(ec.fd, IOCRDMEM, buf, True)
    return bytes(buf[8 : 8 + nbytes])


def ec_sensors(ec):
    out = {}
    raw = memmap(ec, 0x00, 0x18)
    temps = []
    for i in range(16):
        v = raw[i]
        if v in (0xFD, 0xFE, 0xFF):
            temps.append(None)
        else:
            temps.append(round(v + 200 - 273.15, 1))  # raw + 200 = Kelvin
    out["ec_temp_sensors_C"] = temps
    out["fan_rpm"] = list(struct.unpack_from("<4H", raw, 0x10))
    batt = memmap(ec, 0x40, 0x40)
    volt, rate, cap = struct.unpack_from("<3I", batt, 0x00)
    flag, count = batt[0x0C], batt[0x0D]
    dcap, dvlt, lfcc, ccnt = struct.unpack_from("<4I", batt, 0x10)
    out["memmap_battery"] = {
        "voltage_mV": volt,
        "rate_mA": rate,
        "remaining_mAh": cap,
        "flags": hex(flag),
        "index": count,
        "design_cap_mAh": dcap,
        "design_volt_mV": dvlt,
        "last_full_mAh": lfcc,
        "cycle_count": ccnt,
        "manufacturer": batt[0x20:0x28].split(b"\x00")[0].decode(errors="replace"),
        "model": batt[0x28:0x30].split(b"\x00")[0].decode(errors="replace"),
    }
    return out


def pd_power(ec, port):
    r = ec.cmd(EC_CMD_USB_PD_POWER_INFO, 0, bytes([port]), 16)
    role, typ, dualrole, _ = struct.unpack_from("<4B", r, 0)
    vmax, vnow, imax, ilim = struct.unpack_from("<4H", r, 4)
    max_power = struct.unpack_from("<I", r, 12)[0]
    return {
        "role": role,  # 0=disconnected 1=source 2=sink 3=sink-not-charging
        "type": typ,
        "voltage_max_mV": vmax,
        "voltage_now_mV": vnow,
        "current_max_mA": imax,
        "current_lim_mA": ilim,
        "max_power_mW": max_power,
    }


def console_tail(ec):
    ec.cmd(EC_CMD_CONSOLE_SNAPSHOT, 0, b"", 0)
    out = b""
    attempts = ((1, bytes([0]), 96), (0, b"", 96), (0, b"", 64), (0, b"", 48))
    for version, outdata, insize in attempts:
        try:
            while True:
                chunk = ec.cmd(EC_CMD_CONSOLE_READ, version, outdata, insize)
                s = chunk.split(b"\x00")[0]
                if not s:
                    break
                out += s
                if len(out) > 300000:
                    break
            if out:
                return out.decode(errors="replace")
        except (ECError, OSError):
            continue
    return out.decode(errors="replace")


def main():
    ec = EC()
    if "--csv" in sys.argv:
        # one line: chg_current_mA,chg_input_mA,bms_temp_C,bms_charging_current_mA,bms_charging_voltage_mV
        try:
            cs = charge_state(ec)
            sb = battery_smart_regs(ec, 5)
            print(f"{cs['chg_current_mA']},{cs['chg_input_current_mA']},{sb['temperature_C']},{sb['charging_current']},{sb['charging_voltage']}")
        except Exception as e:
            print(f"ERR,{e}")
        return
    if "--clear-current-limit" in sys.argv:
        # EC_CMD_CHARGE_CURRENT_LIMIT with 0xFFFFFFFF = no limit (user_current_limit = -1U)
        ec.cmd(EC_CMD_CHARGE_CURRENT_LIMIT, 0, struct.pack("<I", 0xFFFFFFFF), 0)
        print("charge current limit cleared (user_current_limit = unlimited)")
        return
    if "--set-current-limit" in sys.argv:
        ma = int(sys.argv[sys.argv.index("--set-current-limit") + 1])
        ec.cmd(EC_CMD_CHARGE_CURRENT_LIMIT, 0, struct.pack("<I", ma), 0)
        print(f"charge current limit set to {ma} mA")
        return
    if "--watch" in sys.argv:
        print("time       chg_mA  in_mA  batt_V  batt_mA  des_mA  soc  flags")
        while True:
            try:
                cs = charge_state(ec)
                bd = battery_dynamic(ec)
                print(
                    time.strftime("%H:%M:%S"),
                    "%7d %6d %7d %8d %7d %4d %6d"
                    % (
                        cs["chg_current_mA"],
                        cs["chg_input_current_mA"],
                        bd["voltage_mV"],
                        bd["current_mA"],
                        bd["desired_current_mA"],
                        cs["batt_state_of_charge_pct"],
                        bd["flags"],
                    ),
                    flush=True,
                )
            except ECError as e:
                print("error:", e, flush=True)
            time.sleep(2)
        return

    print("=== CHARGE STATE (GET_STATE) ===")
    for k, v in charge_state(ec).items():
        print(f"  {k:32s} {v}")
    print("=== CHARGE PARAMS ===")
    for name, num in CS_PARAM.items():
        try:
            print(f"  {name:32s} {charge_param(ec, num)} (0x{charge_param(ec, num):x})")
        except ECError as e:
            print(f"  {name:32s} ERROR {e}")
    print("=== BATTERY DYNAMIC ===")
    for k, v in battery_dynamic(ec).items():
        print(f"  {k:32s} {v}")
    print("=== BATTERY STATIC ===")
    for k, v in battery_static(ec).items():
        print(f"  {k:32s} {v}")
    print("=== EC SENSORS / MEMMAP ===")
    try:
        for k, v in ec_sensors(ec).items():
            print(f"  {k:32s} {v}")
    except OSError as e:
        print(f"  (memmap read unsupported: {e})")
    for port in (0, 1):
        try:
            print(f"=== USB PD POWER INFO port {port} ===")
            for k, v in pd_power(ec, port).items():
                print(f"  {k:32s} {v}")
        except ECError as e:
            print(f"  ERROR {e}")
    print("=== EC CONSOLE (tail, last 40 lines) ===")
    text = console_tail(ec)
    lines = [l for l in text.splitlines() if l.strip()]
    for l in lines[-40:]:
        print("  " + l)


if __name__ == "__main__":
    main()
