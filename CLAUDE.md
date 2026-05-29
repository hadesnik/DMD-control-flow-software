# TF-Photostim: Temporal Focusing Patterned Photostimulation Control Software

## ⚠️ Hard rule: stay inside this repo

**NEVER create, edit, move, or delete any file outside this repository's folder.**
This machine also holds the lab's shared MATLAB code (e.g. `C:\Users\scanimage\Documents\MATLAB\CodeBase\`, ScanImage, Masato's/others' scripts) and network shares (`P:\`, etc.). Those are **read-only references**: you may open them to understand the real protocol/conventions, but all writes must land under this repo. If a task seems to require changing an external file, stop and ask the user — propose the change for them to apply by hand rather than editing it yourself.

This repository implements MATLAB-based control software for a 2-photon temporal-focusing patterned photostimulation system being built to support a BRAIN Initiative R01 (RFA-NS-25-018). The grant proposes an NIR DMD + NIR PLM + temporal focusing photostimulation engine targeting single-cell resolution across a 3×3 mm FOV with simultaneous mesoscale 2p calcium imaging. Aim 1 of the grant is the photostimulation subsystem this software controls.

## Status

Phase 1 complete as of 2026-05-17. 32/33 tests passing (`test_calibration_mock` deferred to Phase 2/3). Mock-only end-to-end pipeline working on macOS. Hardware integration deferred to Phase 2/3.

## Immediate goal (2-week sprint, by ~June 18)

Produce preliminary data for the R01 submission. The hero figure is **all-optical patterned photostimulation of identified ChRmine+GCaMP cells in windowed mice**, demonstrating:

1. Targeted single-cell activation with rapid pattern switching across multiple cells (the DMD's unique advantage over SLMs).
2. Lateral PPSF — fraction of cells responding as a function of distance from the DMD target.
3. Power-response curve at a representative target cell.
4. (If PLM remote focusing is online in time) axial PPSF. Otherwise pseudo-axial via objective translation, clearly labeled as such.

The NIR DMD (TI DLP650LNIR) is not in hand yet; arrival expected second week of June. **All code must be developed and tested against mock hardware first**, then switched to real hardware via a single backend swap. Mock-first is not a workaround — it's the architecture.

## Hardware architecture (target system)

** current optical path**
- NKT FS-50 with internal fast power modulation, controllable via an analog output from the daq
- DMD (may be TI or may be from Vialux, visible, coming from Laura Waller's lab, no specs yet)
- temporal focusing grating 
- fills back pupil of a Sutter MOM with Olympus 20x 1.0Na water immserion objective
- this beam path is merged with a PBS after the scan lens
- scan path is a Spectra Physics MaiTai operated via ScanImage resonant scan galvos


** Future Optical path - don't have this hardware yet** (see `docs/tf_photostim_bom.html` for full BOM):
- Light Conversion CARBIDE CB3 femtosecond laser, 1030 nm, ~300 fs, 50 W, ~100 kHz rep rate
- AdlOptica π-Shaper → 6 mm flat-top onto DMD
- TI DLP650LNIR NIR DMD, 1280×800, 10.8 µm pitch, ±12° tilt, controlled via DLPC410 + DisplayPort at 1.4–12.5 kHz
- Reflective ruled grating for temporal focusing (1200 g/mm gold-coated, Newport 33010FL01-530R or Wasatch VPH 1700 g/mm — TBD)
- TI NIR PLM (904×800, 10.8 µm pixel pitch, ~50 µs switching) for remote focusing — **may not be functional for prelim data**
- Pacific Optica Avocado objective (10×, 0.6 NA, f_obj = 16.8 mm, BFP = 20 mm) — for full build
- For prelim experiments, an Olympus 20× 1.0 NA (XLUMPLFLN20XW) on the existing windowed-mouse rig

**Control hardware (two PCs)**:
- **Ephys/control PC** ("the DAQ PC"): NI PCIe-6323, runs MATLAB, drives the DMD, generates all triggers and analog control, acquires ephys + any auxiliary signals. **DMD lives here.**
- **Imaging PC**: runs ScanImage (MATLAB) for 2p GCaMP imaging. Triggered by TTL from the DAQ PC.
- **Substage widefield camera**: Basler acA2500-14um (USB3 Vision, 2592×1944, 2.2 µm pixel pitch, serial 22016738). Connected to the DAQ PC. Used only for spatial calibration (DMD→camera affine and ScanImage scan-field→camera affine); not used during experiments. Driver: `tfp.hardware.BaslerSubstageCamera` via MATLAB Image Acquisition Toolbox `gentl` adaptor (requires Basler pylon 6+ with pylon GenTL Producer).
- **No third PC.** The lab's existing LCoS SLM rig uses a separate PC; this project deliberately does not, to avoid socket-communication bugs.

**Trigger topology**:
- DAQ PC is the timing master.
- DAQ generates: (a) TTL to start ScanImage acquisition on imaging PC, (b) DMD pattern-advance triggers, (c) PLM phase-state triggers (when functional), (d) analog power control of NKT FS-50 via ao3, (e) sync line(s) recorded back into the ephys channels.
- ScanImage frame clock is fed back to the DAQ PC as a digital input for post-hoc frame-stim alignment.

**Confirmed NI PCIe-6323 wiring (as of 2026-05-29, DLi4130 rig)**:

| Line | Direction | Connected to | Notes |
|------|-----------|--------------|-------|
| ai0 | in | — | floating |
| ai1 | in | — | floating |
| ai2 | in | Multiclamp 700B output | primary ephys recording channel |
| ai3 | in | — | floating |
| ao0 | out | Multiclamp 700B command | current/voltage clamp command |
| ao1 | out | PsychToolbox digitizer (other PC) | unused by this software |
| ao2 | out | unknown | TBD |
| ao3 | out | NKT FS-50 power modulator | **photostim laser power control** — 0–5 V |
| port0/line0 | out | TBD | intended ScanImage acquisition trigger — confirm with Masato |
| port0/line1 | out | — | spare |
| port0/line10 | out | — | spare |
| port0/line2 | in | ScanImage frame clock | rising edge = frame acquired (Phase 2+) |

## Software architecture

### Top-level structure

```
tf_photostim/
├── CLAUDE.md                      ← this file
├── docs/
│   ├── ARCHITECTURE.md            ← detailed design (read this next)
│   ├── tf_photostim_bom.html      ← full BOM, optical layout, design calcs
│   ├── BRAIN_R01_aims.pdf         ← grant text for context on what this serves
│   ├── DLP650LNIR_datasheet.pdf
│   └── DLPC410_programmers_guide.pdf
├── +tfp/                          ← MATLAB package, all code lives under here
│   ├── +hardware/                 ← hardware abstraction layer
│   │   ├── DMD.m                  (abstract base)
│   │   ├── MockDMD.m
│   │   ├── DLP650LNIR_DMD.m
│   │   ├── DAQ.m                  (abstract base)
│   │   ├── MockDAQ.m
│   │   ├── NI6323_DAQ.m
│   │   └── ScanImageBridge.m      ← talks to ScanImage on imaging PC
│   ├── +patterns/                 ← pattern generation
│   │   ├── singleSpot.m
│   │   ├── multiSpot.m
│   │   ├── ppsfPattern.m
│   │   ├── calibratedAffine.m     ← DMD→sample coordinate transform
│   │   └── powerLUT.m
│   ├── +trial/                    ← trial sequencing
│   │   ├── Trial.m                ← one stim event + metadata
│   │   ├── TrialSequence.m
│   │   └── Sequencer.m            ← state machine that runs a session
│   ├── +analysis/                 ← online analysis
│   │   ├── onlineDFF.m
│   │   ├── responseClassifier.m
│   │   └── liveFigures.m
│   ├── +calibration/              ← rig calibration routines
│   │   ├── alignDMDtoCamera.m
│   │   ├── crossRegisterScanImage.m  ← scan-field → substage-camera affine
│   │   ├── measurePSF.m
│   │   └── powerMeterSweep.m
│   ├── +experiments/              ← runnable experiment scripts
│   │   ├── exp_ppsf_lateral.m
│   │   ├── exp_rapid_sequential.m
│   │   ├── exp_power_curve.m
│   │   └── exp_pseudo_axial.m
│   ├── +io/                       ← data logging, config loading
│   │   ├── saveTrial.m
│   │   ├── loadConfig.m
│   │   └── sessionLog.m
│   └── +util/                     ← shared utilities
├── configs/
│   ├── default.yaml
│   ├── mock.yaml
│   └── windowed_mouse_v1.yaml
├── tests/                         ← unit tests using mocks
└── scripts/                       ← one-off scripts, alignment helpers
```

### Hardware abstraction (the critical design)

Every hardware device has an **abstract base class** defining the interface, a **Mock implementation** that simulates plausible behavior, and a **real implementation** for the actual device. Experiment code talks only to the abstract interface.

`tfp.hardware.DMD` minimum interface:
```matlab
methods (Abstract)
    initialize(obj)
    loadPatternSequence(obj, patterns)   % patterns: 3D logical array (H × W × N)
    armSequence(obj, triggerMode)        % 'external' | 'internal'
    softTrigger(obj)
    advanceToPattern(obj, idx)
    getStatus(obj)
    cleanup(obj)
end
```

`tfp.hardware.MockDMD` implements the same interface but logs calls and (optionally) renders the active pattern to a debug figure so visual sanity-checking is possible without hardware.

Same pattern for DAQ. `MockDAQ` generates synthetic GCaMP-like traces with a probabilistic response when the active stim pattern overlaps a fake "cell" — this lets the trial sequencer and analysis pipeline be exercised end-to-end without the rig.

**Rule: no code outside `+hardware/` ever touches hardware-specific APIs directly.** If you're tempted to call `daqmx_StartTask` or `ALP_SeqAlloc` from a trial script, stop and add it to the abstraction layer instead.

### Trial as a unit of work

A `Trial` is a single stimulation event with:
- Target spec (cell ID(s), DMD coordinates, or pattern reference)
- Power level
- Timing (onset, duration, pulse train if any)
- Metadata (trial index, session ID, randomization seed)
- Acquired data (ephys snippet, imaging frames during trial, sync trace)

A `TrialSequence` is an ordered list of `Trial` objects. The `Sequencer` runs the sequence — for each trial: load DMD pattern, arm DAQ, trigger ScanImage, wait for completion, save data, advance.

### Configuration

YAML configs (parsed via MATLAB's `yamlread` in R2024b+, or `yaml.loadFile` via `yamlmatlab` for earlier versions). Configs specify hardware backends (Mock vs. real), calibration paths, trial parameters. The config selects which `DMD` subclass to instantiate — no code changes needed to swap mock ↔ real.

## Development workflow

### Phase 1 — Mock-only (pre-hardware)
1. Build the abstraction layer with `MockDMD` and `MockDAQ`.
2. Write `Trial`, `TrialSequence`, `Sequencer` against the mocks.
3. Build pattern-generation utilities (`singleSpot`, `multiSpot`, `ppsfPattern`).
4. Build the experiment scripts. They should run end-to-end against mocks, producing fake data and fake figures.
5. Write tests. Every experiment script must run in `tests/` without hardware.

### Phase 2 — DAQ-real, DMD-mock
6. When the lab's NI 6323 is available, swap to `NI6323_DAQ`. DMD stays mocked.
7. Verify timing: scope all trigger lines, confirm sub-ms alignment.

### Phase 3 — DMD-real
8. Swap to `DLP650LNIR_DMD` on NIR DMD arrival.
9. Run the two-step spatial calibration on a thin fluorescent film (see procedure below).
10. Run `+calibration/measurePSF.m` on a fluorescent slab.
11. Run experiments on windowed mice.

#### Two-step spatial calibration procedure (Phase 3)

The full DMD → ScanImage scan-field mapping is built by composing two affines, both measured using the substage widefield camera against the same fluorescent film:

**Step A — DMD → substage camera** (`alignDMDtoCamera`):
Project a 5×5 grid of DMD spots. Camera sees each spot; fit affine from DMD pixel coords to camera pixel coords. Already implemented.

**Step B — ScanImage scan field → substage camera** (`crossRegisterScanImage`):
The 2p imaging beam rastered by ScanImage excites fluorescence on the film; the substage camera sees the scanned region as a bright rectangle. The scan field's fast (resonant) and slow (galvo) axes are identified by using a **non-square pixel count** (e.g. 256 lines × 512 pixels per line): the rectangle's long axis on the camera is the fast axis (more pixels → wider resonant sweep at the sample). Fit an affine from scan-field coordinates to camera pixel coords.

**Axis sign disambiguation**: the rectangle alone does not reveal which end of each axis is positive in ScanImage's scan-field convention (the resonant scanner sweeps symmetrically so fast-axis sign cannot be observed from a passive camera image; slow-axis sign similarly isn't resolved by a single centered scan). Both signs are stored as config entries (`scan_fast_axis_sign: 1` and `scan_slow_axis_sign: 1`, each ±1) and determined empirically by the **verify step** below.

**Verify step** (mandatory after first calibration, or after any optics change):
1. Project a single DMD spot at a known DMD coordinate.
2. Compute the predicted ScanImage scan-field coordinate using the composed affine.
3. Command ScanImage to scan a small mROI at that predicted coordinate.
4. Operator confirms visually whether the spot is centered in the ScanImage live image.
5. If not, flip `scan_fast_axis_sign` and/or `scan_slow_axis_sign` (4 combinations; typically resolved in ≤2 attempts) and re-verify.
6. Write confirmed signs into the rig config YAML.

**Composition**:
```
dmdToScan_affine = inv(scanToCam_affine) * dmdToCam_affine
```
Both new fields (`scanToCam_affine`, `dmdToScan_affine`) are appended to the calibration struct; the original `dmdToSample_affine` (DMD→camera) is preserved unchanged.

### Phase 4 — PLM integration (post-grant if needed)

## Lab conventions

- **Language**: MATLAB (lab standard, ScanImage native). Target R2023b or later. Use the MATLAB package system (`+tfp/`) for namespacing.
- **Style**: camelCase functions, PascalCase classes, snake_case for config keys. Docstrings on every public function. Each class file starts with a 1-paragraph summary.
- **Data**: trial-level data saved as `.mat` (v7.3) with a consistent schema. Session metadata as YAML alongside.
- **Time**: all timestamps in seconds, double precision, referenced to DAQ master clock. Convert at the boundary, not in the middle.
- **Coordinates**: DMD pixels are integer (col, row) with origin top-left. Sample coordinates are µm (x, y, z) with z=0 at the focal plane during calibration. All transforms live in `+calibration/`.
- **Active DMD region**: Only the **central 6×6 mm** of the DMD chip is optically active (flat-top beam footprint). Pattern generation should constrain spot placement to this region. For the DLP7000 (13.68 µm pitch): `roiHalfWidthPx = 219` (439 px). For the DLP650LNIR (10.8 µm pitch): `roiHalfWidthPx = 278` (556 px). Both stored in config under `dmd.roiHalfWidthPx`.
- **Pixel scale**: ~40× optical demagnification gives ~0.342 µm/px (DLP7000) and ~0.270 µm/px (DLP650LNIR) at the sample plane. A 10 µm cell body (5 µm radius) → 15 px radius on DLP7000, 19 px on DLP650LNIR. Stored in config as `dmd.umPerPixel`. **Verify both values on the rig before using for calibrated coordinates.**

## Conventions established in implementation

Phase 1 implementation pinned the following conventions; treat them as load-bearing when adding new code.

- **Private properties use trailing-underscore naming** (`patterns_`, `state_`, `log_`). Distinguishes internal state from public/protected properties at a glance.
- **Each mock hardware class has a public `getLog()`** returning a struct array of `{timestamp, eventType, payload}` entries. Tests verify call sequences via this log.
- **Error identifiers follow `tfp:<module>:<class-or-func>:<reason>`**, e.g. `tfp:hardware:MockDMD:badPatternShape`, `tfp:trial:Trial:badTransition`, `tfp:io:loadConfig:badYaml`.
- **Trial state mutations go through `markRunning` / `markComplete(data)` / `markFailed(errOrMsg)`** methods on `tfp.trial.Trial`. `SetAccess = private` on `data` and `status` is enforced; the markers also validate state transitions and throw `tfp:trial:Trial:badTransition` on invalid moves.
- **`configField(struct, name, default)` is the standard local helper** for reading config fields with a fallback (used as a local function in `MockDMD.m` and `MockDAQ.m`; promote to `+tfp/+util/` if a third caller appears).
- **`tfp.io.sessionLog` returns the written line without a trailing newline.** The file gets the newline appended.
- **`tfp.io.saveTrial` uses 4-digit zero-padded trial indices** (`trial_0001.mat`) and writes both `complete` and `failed` trials. Analysis pipelines filter by `trial.status`.

## Hardware API
- Target: ViALUX **ALP-4.3** high-speed API on the scope PC (Windows). DLP650LNIR is driven via the DLPC410 controller; ALP-4.3 supports this combo per the [parot-alptool](vendor/alp/reference/parot-alptool/) wrapper. Phase 3 of [Development workflow](#development-workflow) uses this SDK unless the EVM arrives with incompatible firmware. See [docs/alp-api-audit.md](docs/alp-api-audit.md) for the cross-reference audit confirming API coverage.
- Official Vialux SDK header is now in-repo at [vendor/alp/official/alp.h](vendor/alp/official/alp.h) (Version 28, © 2004-2024). Diff against parot-alptool/alp.h completed 2026-05-18 — see [docs/alp-api-audit.md](docs/alp-api-audit.md) for full findings. All 9 audited function signatures verified identical. Key delta: `ALP_DMDTYPE_WXGA_S450 12L` (the DLP650LNIR type constant) is only in the official header; do not use `ALP_PROJ_SYNC/ALP_SYNCHRONOUS/ALP_ASYNCHRONOUS` (2303–2305L) — removed.
- ALP-4.1 header now in-repo at [vendor/alp/official-4.1/alp.h](vendor/alp/official-4.1/alp.h) (Version 25, DLi4130 DLP7000 visible DMD kit, borrowed from Laura Waller lab). Audit confirmed all 9 core function signatures identical to ALP-4.3. Board: DLP7000, 1024×768 XGA, `alp41.dll`. Use this board for software validation until the NIR DLP650LNIR arrives.
- Authoritative API surface:
  - **Primary C API reference:** [vendor/alp/official/alp.h](vendor/alp/official/alp.h) — official Vialux header, Version 28. Use this for all new code.
  - **Older reference (Version 14, for cross-check only):** [vendor/alp/reference/parot-alptool/alp.h](vendor/alp/reference/parot-alptool/alp.h) — extracted from an earlier ALP-4.3 installer by the parot-alptool author.
  - **MATLAB calllib prototypes (4.3 x64):** [vendor/alp/reference/parot-alptool/alpV43x64proto.m](vendor/alp/reference/parot-alptool/alpV43x64proto.m) — the prototype file we'll use on a 4.3 x64 system; pairs with `alp4395.dll` and `alp4395_thunk_pcwin64.dll` in the same directory.
  - [vendor/alp/reference/ALP4lib/src/ALP4.py](vendor/alp/reference/ALP4lib/src/ALP4.py) — Python wrapper, cleanest single-file API summary
  - [vendor/alp/reference/parot-alptool/](vendor/alp/reference/parot-alptool/) — MATLAB `@alpapi/` wrappers and other prototype variants (V1, V42x32, V42x64) — cross-reference for ALP-4.3-specific calls
  - [vendor/alp/reference/nakul-alp41/](vendor/alp/reference/nakul-alp41/) — wraps the **ALP Basic** API (separate DLL `alp41basic.dll`, `Alpb*` prefix, no sequence/projection model). NOT the high-speed API — useful only as a reference for device alloc/free/inquire mechanics; cannot express sequence-based stimulation
- Never invent ALP function names. If a function isn't in one of the references above, stop and ask.
- Flag any uncertain calls for verification once official headers arrive.

## Development environment
- Code is written on macOS (this machine)
- **MATLAB is installed locally on this MacBook** — Claude can and should run unit tests here (e.g. `matlab -batch "runtests('tests')"`) before pushing. Mock-backed tests cover most of the codebase, so local pre-flight catches the majority of regressions.
- Hardware-touching code (real DMD, NI DAQ, ALP DLL) still RUNS on the Windows scope PC; the ALP DLL cannot be loaded on macOS and hardware verification happens on the scope PC after git push/pull.

## What Claude should know when working on this codebase

- This is a research instrument, not production software. Optimize for clarity and ease of modification, not absolute robustness. But: anything that touches the high-power laser path needs explicit safety interlocks (see `+util/safetyChecks.m`).
- The user runs this from MATLAB command line interactively, not as a compiled app. Don't build a GUI unless asked.
- ScanImage integration is via TCP/IP or named pipe — never modify ScanImage internals.
- The DLPC410 supports binary pattern rates up to 12,500 Hz. Don't assume that's achievable for our patterns; the limit depends on pattern size and trigger mode. Empirical benchmarking required when the DMD arrives.
- Temporal focusing means the **axial confinement** of the 2p excitation comes from spectral dispersion + BFP fill, not from numerical aperture alone. Lateral pattern definition comes from the DMD; the grating doesn't affect lateral resolution. Pattern-generation code only cares about lateral; everything else is optics.

## Known gotchas

- **ScanImage is a PMT-based point scanner, not a camera. It cannot image DMD illumination spots directly.**
  The 2p imaging path uses galvo-scanned focused excitation and a PMT point detector. There is no widefield camera on the imaging PC. Consequently, projecting a DMD spot onto a fluorescent slab and "imaging it in ScanImage" does not work: ScanImage can only see fluorescence that its own scan beam excites.

  Two viable routes for DMD↔sample spatial calibration exist:
  - **Substage camera (preferred, implemented):** A widefield camera viewing the sample from below images fluorescence on a thin film. Two affines are fitted against the same camera frame: (A) DMD spots → camera (`alignDMDtoCamera`), and (B) ScanImage scan field → camera (`crossRegisterScanImage`). Composing them gives DMD → ScanImage scan-field coords with no data transfer between PCs. No ScanImage TIFF is needed — ScanImage just runs in Focus mode with a non-square pixel count (e.g. 256×512) so the camera sees an asymmetric rectangle that unambiguously identifies the fast (resonant) vs slow (galvo) scan axis. Axis signs are resolved by a verify step; see the Phase 3 calibration procedure above.
  - **Photobleach holes (backup):** Project DMD spots onto a fluorescent film at sufficient power density to bleach dark holes. Image the holes with ScanImage (they appear as dark spots against the fluorescent background). This gives a direct DMD → ScanImage pixel mapping with no substage camera required. Feasibility depends on achieving enough intensity at the sample with the NKT FS-50; may not be practical at low duty-cycle.

- **MATLAB R2025b (and 2024+) require macOS 13.3+**; R2023a works on Monterey 12.x and is the current dev pin. Don't upgrade the dev machine's MATLAB until macOS is upgraded.
- **When cloning vendor repos into `vendor/`, strip `.git/` before `git add`** to avoid embedded-repo gitlinks (which break clone-and-go for collaborators).
- **`data/` is gitignored** — session outputs don't belong in the repo.
- **`vendor/alp/reference/parot-alptool/` ships Windows `.dll`/`.obj`/`.lib` binaries.** Harmless privately, but consider stripping before any public release.

## Open questions to resolve

- [ ] Which NIR DMD EVM/SDK exactly — **leaning ViALUX ALP-4.3 wrapper** for the DLP650LNIR via DLPC410, based on [docs/alp-api-audit.md](docs/alp-api-audit.md). Phase 3 will use this unless the EVM arrives with incompatible firmware. Fallbacks (TI directly, ViALUX V-9501c) only revisited if 4.3 doesn't fit.
- [ ] Final grating choice (530R aluminum reflective vs Wasatch 1700 g/mm VPH transmission). Affects post-grating layout but not code.
- [ ] ScanImage version and bridge mechanism (vDAQ-mediated triggering vs. direct TCP).
- [ ] Whether to put the DAQ-side recording in MATLAB session-based interface or Data Acquisition Toolbox `dataacquisition` (newer).

## Reading order for someone new (or for Claude on a fresh session)

1. This file.
2. `docs/ARCHITECTURE.md` — concrete design, classes, data flow.
3. `docs/tf_photostim_bom.html` — what the hardware actually is.
4. `+tfp/+hardware/DMD.m` and `MockDMD.m` — the interface pattern.
5. `+tfp/+experiments/exp_ppsf_lateral.m` — what a complete experiment script looks like.
