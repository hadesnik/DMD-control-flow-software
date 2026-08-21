# Calibration GUI — operator guide

`tfp.gui.CalibrationApp` walks **the whole of
[BRINGUP_GUIDE.md](BRINGUP_GUIDE.md) §1–§7**, one step at a time, on the DAQ PC.
At each step it tells you what to do physically, asks you to proceed, drives the
instruments across all three PCs, plots what it measured, judges it against
declared criteria, says in English what the numbers mean, writes it all into a
dated folder, and decides whether you may move on or must change something at
the bench and retake.

Launch with `scripts/run_calibrationGUI.m`:

```matlab
app = run_calibrationGUI                          % the rig (configs/real.yaml)
app = run_calibrationGUI('configs/mock.yaml')     % demo, no hardware needed
```

> **Everything here also works from the command line**, with the same
> interlocks, the same verdicts and the same record. The app is a view over
> `tfp.gui.CalibrationSession`, which is headless by construction — see
> [Running without the GUI](#running-without-the-gui).

---

## The guided bringup

The first tab is the default way to use the app. The remaining six tabs are the
same instruments with the guardrails off, for someone who already knows which
measurement they came for.

**Left: the procedure**, §1 to §7 top to bottom, each row showing its state —
`ready`, `blocked`, or the verdict it earned. A blocked step says *why* in
words ("the laser state has not been entered, and the pulse-energy interlock is
fail-closed on rep rate"), not by greying out a button.

**Right, before you press anything:**

- **What this step is for** — one sentence on what it measures and why.
- **DO THIS AT THE BENCH** — the physical actions, in order. Put the film on,
  focus the camera, put ScanImage in Focus with a non-square pixel count, swap
  the film for the slab.
- **SAFETY** — the hazard sentence for this step, when it has one.
- **WHEN YOU PRESS PROCEED, THE SOFTWARE WILL** — what is about to happen, so
  consent is informed rather than reflexive.
- **Settings** — the knobs this step accepts, each with its default and a note
  on what it buys.

**Right, after it runs:**

- A **verdict banner**: `PASS`, `WARN`, `ADJUST` or `FAIL`.
- A **checks table** — every criterion, what was measured, what was wanted, and
  the result.
- The **plot** for that step, exported to the report folder as PNG and PDF.
- **Reading** — what each number means, failures explained first, and, when it
  did not pass, **what to change** at the bench.

### The four verdicts

They are deliberately not a pass/fail pair, because the four situations call for
four different actions:

| Verdict | Meaning | Next step |
|---|---|---|
| `pass` | every criterion met | enabled |
| `warn` | outside a **design** band, but the measurement is the truth — the repo's standing doctrine is that the handoff is design intent and the bench is fact | enabled |
| `adjust` | something **physical** is wrong; the remedy says what | blocked — change it, then Retake |
| `fail` | the **measurement** did not work (bad fit, too few points, a device that did not answer) | blocked — Retake with different settings |

A criterion whose field is missing is reported as **not evaluated** and never
silently passes: it contributes `warn`, except where its own severity is `fail`,
in which case not being able to verify is itself a stop. That rule is why
"power at 0 V is off" cannot be skipped by a result that happens to lack the
field.

### Where the words come from

Every instruction, threshold and remedy on that tab is data in
`src/+tfp/+gui/bringupSteps.m` — one declarative entry per guide section.
`stepMetrics.m` derives the quantities the criteria test, `stepVerdict.m`
applies them. None of the three touches graphics or hardware, so all of it runs
and is tested under `matlab -nodisplay` (`tests/test_bringup_steps.m`).
`CalibrationApp.m` decides only where things sit on the screen.

### Skipping

A step can be skipped — a 2D-only session has no SLM to link — but the app
requires a reason and writes it into the report. A report that is silent about
a step reads as if the step passed.

---

## Where the session is written

`calibration/<YYYY-MM-DD>_<session>/` in the repo, rebuilt **after every step**
rather than at the end, so the record survives a crashed MATLAB or an operator
who walks away mid-procedure.

| Path | What | Tracked |
|---|---|---|
| `report.html` | the whole session, self-contained, openable in a browser | ✅ |
| `report.json` | the same, machine-readable | ✅ |
| `steps/<id>.json` | one step's verdict, checks and derived metrics | ✅ |
| `steps/<id>.mat` | that step's full result struct with provenance | ❌ |
| `figures/<id>.png` / `.pdf` | the step's plot, also embedded in the report | ✅ |

The split is in `.gitignore` and the reasoning is in
[`calibration/README.md`](../calibration/README.md): what the scale was on the
day an experiment ran is not recoverable from anything else, so the readable
record belongs in version control; the `.mat` payloads carry camera stacks and
do not.

Override the location with `config.paths.calibrationDir`, or the session option
`calibrationRoot`.

---

## Try it without hardware

```matlab
cd <repo>
addpath('scripts');
app = run_calibrationGUI('configs/mock.yaml');
```

Runs on any machine — no DMD, no DAQ, no camera, no PM100D, no drivers. Work
left to right: apply the laser state, run preflight, then each calibration.
Every step produces a real result, and a red banner names every simulated
device throughout.

**It simulates a rig rather than pretending to measure one.** That distinction
is the whole point: a `MockSubstageCamera` built from YAML alone returns *pure
noise*, and `alignDMDtoCamera` will happily threshold that noise, find blobs,
fit an affine and report a plausible residual — a demo that appears to work
while measuring nothing. So `tfp.sim.wireMockRig` connects the mock camera to
the mock DMD through a known truth affine, makes the spot's blur follow the z
stage, and tilts the excitation plane along the dispersion diagonal. The power
sweep uses `tfp.sim.SyntheticPowerMeter`, which watches the mock DAQ's log and
reports the power the commanded voltage would produce.

The real sweep, the real controller and the real interlock all run — only the
instruments are simulated. You will see the actual confirmation dialogs, and
declining one really does prevent output.

Compare any result against the injected ground truth:

```matlab
truth = app.session.mockTruth();     % .truthAffine .truthGradientUmPerUm ...
```

Typical demo numbers: DMD→camera residual ≈ 0.04 px, and a field-tilt gradient
recovering the handoff's 0.02929 µm/µm.

What the demo cannot show: the `uiconfirm` dialogs are the real thing but the
numbers behind them are simulated; ScanImage cross-registration needs a bright
rectangle on the camera, which the mock only renders if you set `scanRect`; and
nothing here exercises the ALP, NI-DAQmx, pylon or TLPM drivers, all of which
are Windows-only.

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
| Cross-registration, ETL planes, mark stacks | imaging PC, same MATLAB | `si_calib_helper` |
| SLM defocus (later) | Holo/SLM PC | `slm_server` |

`si_calib_helper` (port 3048, see [PORTS.md](PORTS.md)) is what makes §4b, §4c,
§6b and §7 hands-off: it sets ScanImage's pixel counts, enters Focus, commands
an mROI, reports per-plane brightness and returns a volume, all over msocket
from the DAQ PC. Without it those steps still run — the app tells you what to
set and waits — but you walk to the other PC for each one.

> Its `hSI` property names are `%VERIFY` on first use, exactly as
> `si_motor_helper`'s `motorPosition` was. They are isolated in patch-point
> functions at the bottom of the file so a ScanImage version difference is a
> one-line edit.

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

The guided path is six methods, and they are the same six the wizard calls:

```matlab
addpath('src');
config = tfp.io.loadConfig('configs/real.yaml');
s = tfp.gui.CalibrationSession(config, struct('configPath', 'configs/real.yaml'));

plan = s.stepPlan();                       % the procedure + live status
disp(struct2table(rmfield(plan, {'setup','willDo','checks','knobs', ...
                                 'criteria','remedy','records','status'})));

brief = s.beginStep('power_curve');        % read the setup out loud
disp(char(brief.setup));

out = s.runStep('power_curve');            % measure, judge, record
disp(out.verdict.headline);
disp(char(out.verdict.reading));

s.skipStep('slm_link', 'no modulator on the arm this week');
s.noteStep('field_tilt', 'film looked bleached top left');
disp(s.report().htmlPath());

s.shutdown();     % laser first, DAQ last
```

The individual measurements are still directly callable when you want one
without the procedure around it:

```matlab
curve = s.runPowerSweep();                                        % volts -> mW
calA  = s.runDmdToCamera();                                       % step A
calB  = s.runScanCrossRegister(struct('scanPixels', [512 256]));  % step B
calC  = s.runVerifySigns();                                       % step C
comp  = s.composeLateral();
tilt  = s.runFieldTilt();
slmC  = s.runSlmDefocus();                                        % §6a
etlC  = s.runEtlPlanes();                                         % §6b
zcal  = s.composeZ();                                             % §6c
```

Prompts fall back to `input()` at the command line via
`tfp.util.consoleConfirmPower` and `tfp.util.consoleAsk`, using the same
wording the dialogs show.

---

## Where things are

| Path | What |
|---|---|
| `src/+tfp/+gui/bringupSteps.m` | the procedure as data: instructions, criteria, remedies |
| `src/+tfp/+gui/stepMetrics.m` | the arithmetic the criteria test |
| `src/+tfp/+gui/stepVerdict.m` | pass / warn / adjust / fail, and why |
| `src/+tfp/+gui/CalibrationReport.m` | the dated folder and its HTML report |
| `src/+tfp/+gui/CalibrationSession.m` | all state and every decision; headless, fully tested |
| `src/+tfp/+gui/CalibrationApp.m` | the `uifigure` view; no logic |
| `src/+tfp/+gui/FrameProcessor.m` | display image math; pure and static |
| `src/+tfp/+hardware/ScanImageCalibBridge.m` | the DAQ-PC client for `si_calib_helper` |
| `scripts/imaging_pc_setup/si_calib_helper.m` | the imaging-PC server (port 3048) |
| `src/+tfp/+hardware/LaserPowerController.m` | the only thing that drives the modulator |
| `src/+tfp/+util/assertPulseEnergySafe.m` | the relay-pupil interlock |
| `src/+tfp/+calibration/measureFieldTilt.m` | the depth-plane measurement |
| `src/+tfp/+sim/wireMockRig.m` | connects the mock devices into one optical model |
| `data/calibration_sessions/<stamp>_<name>/log.txt` | the session audit trail |

`tests/test_gui_headless_guard.m` fails the build if graphics leak out of
`CalibrationApp.m`, if a hardware API appears under `+gui/`, or if a new call
site starts driving the modulator directly.
