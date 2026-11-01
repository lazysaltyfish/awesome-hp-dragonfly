import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const POWER_SCHEMA = 'org.gnome.settings-daemon.plugins.power';
const AMBIENT_ENABLED_KEY = 'ambient-enabled';

// Perceptual exponent (Gamma 2.2 matches human brightness perception & ChromeOS powerd curve)
const GAMMA = 2.2;

// Polling & animation constants
const ALS_POLL_INTERVAL_MS = 1000;
const ANIMATION_STEP_MS = 80;
const ANIMATION_MAX_STEP = 0.008; // ~10% per second smooth ramp
const TARGET_DEADBAND = 0.015;    // 1.5% deadband to prevent flicker on 1-lux jitter

export default class RedrixAutoBrightnessExtension extends Extension {
    enable() {
        this._bm = Main.brightnessManager;
        this._bDBus = Main.brightnessDBus;
        this._powerSettings = new Gio.Settings({schema_id: POWER_SCHEMA});

        // Ensure gsd-power's buggy relative-normalization ALS is disabled
        if (this._powerSettings.get_boolean(AMBIENT_ENABLED_KEY)) {
            this._powerSettings.set_boolean(AMBIENT_ENABLED_KEY, false);
        }

        this._alsPath = this._findAlsInputPath();
        this._smoothedLux = null;
        this._userBias = 0.0;
        this._targetBrightness = null;
        this._currentBrightness = null;
        this._applyingAuto = false;

        this._pollTimerId = 0;
        this._animTimerId = 0;

        this._patchBrightnessManager();

        this._userUpdateId = this._bm.connect('user-update', () => {
            if (this._applyingAuto)
                return;
            this._onUserBrightnessUpdate();
        });

        this._monitorsChangedId = this._bm.connect('changed', () => {
            this._patchScalePrototypes();
        });

        this._startAutoBrightness();
    }

    disable() {
        this._stopTimers();

        if (this._userUpdateId) {
            this._bm.disconnect(this._userUpdateId);
            this._userUpdateId = 0;
        }
        if (this._monitorsChangedId) {
            this._bm.disconnect(this._monitorsChangedId);
            this._monitorsChangedId = 0;
        }

        this._unpatchBrightnessManager();
        this._powerSettings = null;
        this._bm = null;
        this._bDBus = null;
    }

    _findAlsInputPath() {
        const iioBase = '/sys/bus/iio/devices';
        try {
            const dir = Gio.File.new_for_path(iioBase);
            const enumerator = dir.enumerate_children(
                'standard::name',
                Gio.FileQueryInfoFlags.NONE,
                null
            );
            let info;
            while ((info = enumerator.next_file(null)) !== null) {
                const devName = info.get_name();
                if (!devName.startsWith('iio:device'))
                    continue;
                const namePath = `${iioBase}/${devName}/name`;
                const inputPath = `${iioBase}/${devName}/in_illuminance_input`;
                try {
                    const [ok, bytes] = GLib.file_get_contents(namePath);
                    if (ok) {
                        const sensorName = new TextDecoder().decode(bytes).trim();
                        if (sensorName === 'cros-ec-light' &&
                            GLib.file_test(inputPath, GLib.FileTest.EXISTS)) {
                            return inputPath;
                        }
                    }
                } catch (_e) {
                    // ignore device without name
                }
            }
        } catch (e) {
            console.warn(`[RedrixALS] Failed enumerating IIO devices: ${e.message}`);
        }
        const fallback = '/sys/bus/iio/devices/iio:device0/in_illuminance_input';
        return GLib.file_test(fallback, GLib.FileTest.EXISTS) ? fallback : null;
    }

    _patchBrightnessManager() {
        if (this._bDBus && !this._origSetAutoBrightnessTarget) {
            this._origSetAutoBrightnessTarget = this._bDBus.SetAutoBrightnessTarget;
            this._bDBus.SetAutoBrightnessTarget = (_target) => {};
        }
        if (this._bm) {
            this._bm._abTarget = -1.0;
        }
        this._patchScalePrototypes();
    }

    _patchScalePrototypes() {
        if (!this._bm)
            return;
        const scales = this._bm.scales;
        if (!scales || scales.length === 0)
            return;

        const proto = Object.getPrototypeOf(scales[0]);
        if (proto && !proto._redrixPatched) {
            this._scaleProto = proto;
            this._origGetRel = proto._getRelativeBrightness;
            this._origSetRel = proto._setRelativeBrightness;

            proto._getRelativeBrightness = function (backlight) {
                const {brightness, brightnessMin: min, brightnessMax: max} = backlight;
                if (max <= min)
                    return 1.0;
                const linear = Math.max(0.0, Math.min(1.0, (brightness - min) / (max - min)));
                return Math.pow(linear, 1.0 / GAMMA);
            };

            proto._setRelativeBrightness = function (backlight, brightness) {
                const {brightnessMin: min, brightnessMax: max} = backlight;
                const clamped = Math.max(0.0, Math.min(1.0, brightness));
                const linear = Math.pow(clamped, GAMMA);
                backlight.brightness = Math.round(min + (max - min) * linear);
            };

            proto._redrixPatched = true;

            for (const scale of scales) {
                const backlights = scale._getBacklights();
                if (backlights.length > 0) {
                    const rel = scale._getRelativeBrightness(backlights[0]);
                    this._currentBrightness = rel;
                    this._setSliderAndBacklight(rel);
                }
            }
        }
    }

    _unpatchBrightnessManager() {
        if (this._bDBus && this._origSetAutoBrightnessTarget) {
            this._bDBus.SetAutoBrightnessTarget = this._origSetAutoBrightnessTarget;
            this._origSetAutoBrightnessTarget = null;
        }
        if (this._scaleProto && this._scaleProto._redrixPatched) {
            this._scaleProto._getRelativeBrightness = this._origGetRel;
            this._scaleProto._setRelativeBrightness = this._origSetRel;
            delete this._scaleProto._redrixPatched;
            this._scaleProto = null;
        }
    }

    _startAutoBrightness() {
        if (!this._alsPath)
            return;
        this._smoothedLux = null;
        this._userBias = 0.0;
        this._pollAlsOnce(true);
        if (!this._pollTimerId) {
            this._pollTimerId = GLib.timeout_add(
                GLib.PRIORITY_DEFAULT,
                ALS_POLL_INTERVAL_MS,
                () => {
                    this._pollAlsOnce(false);
                    return GLib.SOURCE_CONTINUE;
                }
            );
        }
    }

    _stopTimers() {
        if (this._pollTimerId) {
            GLib.source_remove(this._pollTimerId);
            this._pollTimerId = 0;
        }
        if (this._animTimerId) {
            GLib.source_remove(this._animTimerId);
            this._animTimerId = 0;
        }
    }

    _readLuxSync() {
        if (!this._alsPath)
            return null;
        try {
            const [ok, bytes] = GLib.file_get_contents(this._alsPath);
            if (!ok)
                return null;
            const val = parseFloat(new TextDecoder().decode(bytes).trim());
            return Number.isFinite(val) && val >= 0 ? val : null;
        } catch (_e) {
            return null;
        }
    }

    _calcAutoTarget(lux) {
        // 0 lux -> ~17%, 9 lux -> ~43%, 30 lux -> ~57%, 100 lux -> ~71%, 300 lux -> ~84%, 1000+ lux -> 100%
        const base = 0.15 + 0.28 * Math.log10(Math.max(0.0, lux) + 1.2);
        return Math.max(0.12, Math.min(1.0, base));
    }

    _onUserBrightnessUpdate() {
        if (this._animTimerId) {
            GLib.source_remove(this._animTimerId);
            this._animTimerId = 0;
        }

        const userVal = this._bm?.globalScale?.value;
        if (typeof userVal !== 'number')
            return;

        this._currentBrightness = userVal;
        this._targetBrightness = userVal;

        if (this._smoothedLux !== null) {
            const baseAuto = this._calcAutoTarget(this._smoothedLux);
            this._userBias = Math.max(-0.5, Math.min(0.5, userVal - baseAuto));
        }
    }

    _pollAlsOnce(immediate = false) {
        const rawLux = this._readLuxSync();
        if (rawLux === null)
            return;

        if (this._smoothedLux === null || immediate) {
            this._smoothedLux = rawLux;
        } else {
            const diff = Math.abs(rawLux - this._smoothedLux);
            const relDiff = diff / Math.max(1.0, this._smoothedLux);
            const alpha = (diff >= 4.0 && relDiff >= 0.35) ? 0.45 : 0.20;
            this._smoothedLux = this._smoothedLux * (1.0 - alpha) + rawLux * alpha;
        }

        const baseTarget = this._calcAutoTarget(this._smoothedLux);
        const newTarget = Math.max(0.05, Math.min(1.0, baseTarget + this._userBias));

        if (this._currentBrightness === null) {
            this._currentBrightness = this._bm?.globalScale?.value ?? newTarget;
        }

        if (!immediate && this._targetBrightness !== null &&
            Math.abs(newTarget - this._targetBrightness) < TARGET_DEADBAND) {
            return;
        }

        this._targetBrightness = newTarget;
        this._startAnimation();
    }

    _startAnimation() {
        if (this._animTimerId)
            return;

        this._animTimerId = GLib.timeout_add(
            GLib.PRIORITY_DEFAULT,
            ANIMATION_STEP_MS,
            () => {
                if (this._targetBrightness === null || this._currentBrightness === null) {
                    this._animTimerId = 0;
                    return GLib.SOURCE_REMOVE;
                }

                const delta = this._targetBrightness - this._currentBrightness;
                if (Math.abs(delta) <= 0.002) {
                    this._currentBrightness = this._targetBrightness;
                    this._setSliderAndBacklight(this._currentBrightness);
                    this._animTimerId = 0;
                    return GLib.SOURCE_REMOVE;
                }

                const step = Math.sign(delta) * Math.min(
                    ANIMATION_MAX_STEP,
                    Math.max(0.0015, Math.abs(delta) * 0.18)
                );
                this._currentBrightness += step;
                this._setSliderAndBacklight(this._currentBrightness);
                return GLib.SOURCE_CONTINUE;
            }
        );
    }

    _setSliderAndBacklight(perceptualValue) {
        if (!this._bm)
            return;

        const val = Math.max(0.0, Math.min(1.0, perceptualValue));
        this._applyingAuto = true;
        this._bm._inhibitUpdates = true;
        try {
            if (this._bm._globalScale)
                this._bm._globalScale.value = val;

            for (const scale of this._bm._monitorScales.values()) {
                scale.value = val;
                const max = this._bm._dimmingEnabled ? this._bm._dimmingTarget : 1.0;
                scale.setBacklight(Math.min(max, val));
            }
        } finally {
            this._bm._inhibitUpdates = false;
            this._applyingAuto = false;
        }
    }
}
