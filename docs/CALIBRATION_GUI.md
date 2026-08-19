# Calibration GUI — operator guide

`tfp.gui.CalibrationApp` runs the first DMD-at-sample calibrations on the DAQ
PC: live camera tuning, CARBIDE volts→mW, the two-step spatial calibration with
axis-sign verification, and the field-tilt (depth-plane) measurement.

Launch with `scripts/run_calibrationGUI.m`.

> **Everything here also works from the command line**, with the same
> interlocks and the same provenance. The app is a view over
> `tfp.gui.CalibrationSession`, which is headless by construction — see
> [Running without the GUI](#running-without-the-gui).

---

## Before the first run

### 1. Wire the CARBIDE modulator

Fill in [docs/WIRING.md](WIRING.md) and set
`laser.carbide_modulator_ao_channel` in `configs/real.yaml`. Until then every
output throws `tfp:hardware:LaserPowerController:notWired` and the power tab
is disabled. **Verify the polarity on a meter first** — if 0 V is not "off",
every zero-on-error path in the software drives the laser the wrong way.

### 2. Apply the config diff (rig only)

`configs/real.yaml` is rewritten in place on the rig and must never be
overwritten from a dev machine, so these are proposed rather than applied:

```yaml
# --- append to configs/real.yaml ---

# Results the calibration session may write back.
calibration:
  scan_fast_axis_sign: 0     # 0 = unresolved; verifyScanFieldComposition writes +1/-1
  scan_slow_axis_sign: 0
  field_tilt_file: ''
  lateral_file: ''
```

```yaml
# --- inside the existing laser: block ---
  arm_transmission: 0.182    # %VERIFY — measure laser -> sample and replace
```

```yaml
# --- inside the existing camera: block ---
  backend: 'basler'          # read by tfp.hardware.makeCamera
  binning: 1                 # 2 or 4 for faint 2p signal
  roi: []                    # [x y w h], 1-indexed; [] = full sensor
```

Optional but recommended, for TODO C6: add a `paths:` section with
`dataDir: 'C:\data'`. Without it the session falls back to `session.dataDir`
and then to `./data`, so results land relative to the rig's working directory.

### 3. Start the helpers on the other PCs

| Needed for | Where | What |
|---|---|---|
| Field tilt (objective mount) | imaging PC, inside the ScanImage MATLAB | `addpath('<repo>/scripts/imaging_pc_setup'); si_motor_helper` |
| Cross-registration | imaging PC | ScanImage in **Focus**, **non-square** pixel count |
| SLM defocus (later) | Holo/SLM PC | `slm_server` |

---

## Tab by tab

### Laser state — do this first

Read the values off the CARBIDE control software on the Holo PC and type them
in. **Nothing that puts light on the sample is enabled until this is applied**,
because `tfp.util.assertPulseEnergySafe` is fail-closed on rep rate: believing
100 kHz while the pulse picker sits at /100 understates pulse energy a
hundredfold.

Enter the **front-panel average power** if you can. It is a laser-plane number,
so the interlock needs no arm-transmission assumption; without it the interlock
scales the sample-plane power up by the (unmeasured) 0.182 and warns.

Everything entered here is stamped into every calibration saved this session.

### Preflight

One row per device: DMD, DAQ, camera, z ruler, CARBIDE modulator, PM100D,
ScanImage link — with what failed and what to do about it. Only helpers that
already exist are exercised; no new socket code was written for this panel.

A red banner appears across every tab naming any **simulated** device. Nothing
measured against a simulated device is a calibration, and with the DMD
simulated the laser controller refuses to emit real light at all: the pattern
actually on the chip would be unknown, so the interlock's ON-blob fraction
would be a guess.

### Camera

For imaging 2p-excited fluorescence from a thin film the signal is
photon-starved, and the failure mode is turning the exposure up until the
centroid is a clipped plateau and the affine fit quietly degrades. The knobs
exist to make that visible:

| Knob | What it buys |
|---|---|
| Exposure | the biggest single lever; limits are queried from the camera, not guessed |
| Binning 2×2 / 4×4 | 4–16× signal per pixel; at 2.2 µm sensor pitch against ~1.56 µm/px it costs nothing for centroiding |
| Mono12 | four more bits of dynamic range against a non-zero background |
| Frame averages | √N read-noise reduction, free |
| Capture dark | subtracts the pedestal that otherwise biases centroids; feeds the existing `findSpotCentroid` background path |
| Mark saturation | red pixels are clipped — **the failure you cannot see by eye** |
| Histogram / line profile | photon- vs read-noise-limited, and a σ to minimise while focusing |

### Power

Sweeps the CARBIDE modulator against the PM100D and fits volts→mW.

Consent is taken **once, for the ramp's ceiling** — a dialog per step would
train you to click through them. The hard interlock still runs on every single
step; only the dialog is suppressed, and only up to the authorised voltage.

The panel reports where 5 mW (calibration working power) and 44 mW (the SLM
alignment cap) sit on the dial, which is what BRINGUP_GUIDE §3 asks you to
record.

### Spatial

Three gated sub-steps, matching BRINGUP_GUIDE §4:

- **A. DMD → camera** — spot grid, affine fit. Good result: residual < 1 px.
- **B. ScanImage → camera** — ScanImage in Focus with a non-square pixel count
  (e.g. 512 × 256), so the rectangle's long axis identifies the fast
  (resonant) axis.
- **C. Axis signs** — mandatory. Four combinations, each shown as a predicted
  mROI centre; command it in ScanImage and answer. Usually ≤ 2 attempts.

**Do not move the stage in XY between A and C.** Both affines are anchored to
the camera frame; `composeCalibration` warns beyond ~1 µm.

### Field tilt

New in this work — nothing in the repo measured the depth plane before.

Projects a spot at each of N field positions inside the Ø463 px patch, runs a
through-focus sweep at each, and fits `z = a·x_disp + b·y_groove + c`. Expect
`a ≈ 0.02929` µm/µm and `b ≈ 0`.

- A large `|b|` is **diagnostic, not just disappointing**: the tilt is not
  along the dispersion axis at all, which points at a wrong 45° handedness or
  a mis-clocked chip.
- Sanity bands against the handoff **warn, never fail** — the committed
  handoff is rev 4 and predates the ratified f7 = 300 build.
- If best focus lands at the edge of a sweep window the point is flagged and
  excluded, with a warning telling you to widen `Search ±`. A clamped point
  biases the gradient toward zero, which is the very quantity being measured.
- The reported `depthGradientSign` is a **proposal** for
  `threeD.depth_gradient_sign`, not authority: it is expressed in both the
  ruler's "+z is deeper" contract and `dmdToDispersionUm`'s +dispersion
  direction, and the handoff leaves both bench conventions unspecified.
  BRINGUP_GUIDE §7.4's burn row remains the independent check.

---

## Safety model

| Layer | What it does |
|---|---|
| `tfp.hardware.DMD.assertPatternsSafe` | refuses any frame over the 50% ON cap |
| `tfp.util.assertPulseEnergySafe` | refuses power over the 89 µJ relay-pupil ceiling, and over the ~5e13 W/cm² air-breakdown estimate |
| `tfp.util.assertSlmPowerSafe` | the §7b 44 mW LC alignment cap |
| Confirmation dialog | informed consent for every power increase |
| BEAM OFF | never gated by any dialog |

Ordering matters and is not arbitrary: **the interlock refuses before the
dialog asks.** An unsafe request is never offered for confirmation, because
asking someone to approve something already judged unsafe teaches them to click
through it.

The dialog fires on any power increase, on the first output of each step even
at unchanged power, on any pattern change at non-zero power, and on any
warning-level result. It never fires on a decrease or on zero — blocking the
safe direction is how a safety dialog becomes a hazard.

Every dialog, with the full numbers as shown, is written to the session log as
a `power_confirm` event. That is the audit trail for every beam-on decision.

---

## Running without the GUI

```matlab
addpath('src');
config = tfp.io.loadConfig('configs/real.yaml');
s = tfp.gui.CalibrationSession(config, struct('configPath', 'configs/real.yaml'));

s.setLaserState(struct('repRateKhz', 100, 'pulsePickerDivision', 1, ...
                       'frontPanelPowerW', 8.5));
disp(struct2table(s.preflight()));

curve = s.runPowerSweep();                                    % volts -> mW
calA  = s.runDmdToCamera();                                   % step A
calB  = s.runScanCrossRegister(struct('scanPixels', [512 256]));  % step B
calC  = s.runVerifySigns();                                   % step C
comp  = s.composeLateral();
tilt  = s.runFieldTilt();

s.shutdown();     % laser first, DAQ last
```

Prompts fall back to `input()` at the command line via
`tfp.util.consoleConfirmPower`, using the same wording the dialog shows.

---

## Where things are

| Path | What |
|---|---|
| `src/+tfp/+gui/CalibrationSession.m` | all state and every decision; headless, fully tested |
| `src/+tfp/+gui/CalibrationApp.m` | the `uifigure` view; no logic |
| `src/+tfp/+gui/FrameProcessor.m` | display image math; pure and static |
| `src/+tfp/+hardware/LaserPowerController.m` | the only thing that drives the modulator |
| `src/+tfp/+util/assertPulseEnergySafe.m` | the relay-pupil interlock |
| `src/+tfp/+calibration/measureFieldTilt.m` | the depth-plane measurement |
| `data/calibration_sessions/<stamp>_<name>/log.txt` | the session audit trail |

`tests/test_gui_headless_guard.m` fails the build if graphics leak out of
`CalibrationApp.m`, if a hardware API appears under `+gui/`, or if a new call
site starts driving the modulator directly.
