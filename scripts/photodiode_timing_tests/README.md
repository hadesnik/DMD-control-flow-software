# DMD / PLM Switching-Timing Characterization Toolset

This toolset measures the optical switching speed and maximum reliable refresh rate of spatial-light modulators (DMD or PLM) in the TF-Photostim rig. It drives the device to ping-pong between two spatial patterns — a spot aligned to a pinhole over a Thorlabs avalanche photodiode (APD) and an off-axis spot — while an NI PCIe-6323 DAQ simultaneously samples the APD on an analog-input channel and the pattern-advance trigger on a digital-input line, both clocked from the same sample clock. Swept across a range of commanded rates, the toolset extracts trigger-to-light latency, optical 10–90% rise and fall (settle) times, achieved vs. commanded switch rate, per-transition jitter, dropped-frame fraction, and the maximum reliable switching rate. A synthetic-signal mock path runs the full pipeline with no hardware attached.

---

## Measurement Principle

1. **Two patterns, one pinhole.** Pattern A is a spot centred on the APD pinhole → high APD photocurrent. Pattern B is a spot displaced laterally (or all-off for DMD) → dark APD signal. The device alternates between A and B at a commanded rate.

2. **DAQ-generated triggers (external mode).** The DAQ writes a hardware-clocked square wave on analog-output channel `cfg.channels.trigAO`. This signal is the pattern-advance trigger: it goes to the device's external-trigger input. The same line is tee'd into digital-input `cfg.channels.trigDI` for loopback recording on the exact same sample clock.

3. **Simultaneous capture.** The APD voltage is sampled on `cfg.channels.apdAI`; the trigger loopback is captured on `cfg.channels.trigDI`. All channels share one sample clock.

4. **Metrics extraction.** `analyzeTimingTrace` detects trigger rising edges and optical transitions (threshold crossings on the APD trace), then computes:
   - **Latency**: trigger edge → 50% optical crossing (per transition, then mean/median/std).
   - **Rise/fall times**: 10–90% optical swing, per transition.
   - **Achieved rate**: from inter-optical-edge intervals.
   - **Jitter**: std of per-transition latency.
   - **Dropped-frame fraction**: (commanded advances − optical transitions) / commanded.
   - **Max reliable rate**: highest commanded rate with `trackingOK = true` and `droppedFraction < 0.05`.

5. **Rate sweep.** `runDMDTimingSweep` loops `cfg.sweep.ratesHz`, calling `acquireTimingRun` + `analyzeTimingTrace` at each rate, aggregates results, saves `timing_result.mat`, and prints a console summary table.

---

## Quick Start — Mock Run (no hardware; works on a dev Mac)

```matlab
>> cd <repo root>
>> addpath('scripts/photodiode_timing_tests')
>> addpath('src')
>> result = runDMDTimingSweep(struct('hardwareKind','mock'), 'dmd_timing_mockdemo');
```

This:
- Constructs `tfp.hardware.MockDMD` + `tfp.hardware.MockDAQ` (no hardware needed).
- Overlays a synthetic APD + trigger trace via `synthTimingTrace` at each rate, so the analysis pipeline runs on realistic simulated signals even with no optics.
- Sweeps `cfg.sweep.ratesHz` (default: `[50 100 200 500 1000 2000 5000 8000 10000 12500]` Hz).
- Writes `data/dmd_timing_mockdemo/timing_result.mat` (v7.3) and `timing_summary.png`.
- Prints a per-rate summary table and the max reliable switching rate to the console.

To run with all defaults (auto-generated session name):

```matlab
>> result = runDMDTimingSweep();
```

---

## Real-Hardware Run (scope PC, MATLAB R2019a+, NI-DAQmx)

Set `hardwareKind = 'real'`, fill the DMD backend fields, and confirm channel assignments:

```matlab
ov = struct();
ov.hardwareKind       = 'real';
ov.sampleRateHz       = 250000;
ov.dmd.backend.alpVersion = '4.3';
ov.dmd.backend.dmdType    = 'DLP650LNIR';
ov.dmd.backend.dllPath    = 'C:\ALP\alp4395.dll';
ov.dmd.backend.protoFile  = 'C:\ALP\alpV43x64proto.m';
ov.channels.apdAI         = 0;          % ai0
ov.channels.trigAO         = 0;          % ao0
ov.channels.trigDI         = 'port0/line0';
ov.sweep.ratesHz           = [500 1000 2000 5000 8000 10000 12500];
ov.paths.dataDir           = 'D:\sessions';

result = runDMDTimingSweep(ov, 'dmd_timing_2026-06-15');
```

The real path constructs `tfp.hardware.DLP650LNIR_DMD` + `tfp.hardware.NI6323_DAQ` and performs live hardware-clocked acquisition. Run on the scope PC after `git pull`.

---

## Wiring / Channel Map

| Signal | DAQ terminal | Default config field | Notes |
|---|---|---|---|
| APD analog output | `ai0` (AI channel 0) | `cfg.channels.apdAI = 0` | Thorlabs APD direct to AI; no buffer needed |
| DAQ trigger output | `ao0` (AO channel 0) | `cfg.channels.trigAO = 0` | Generates the pattern-advance square wave |
| Trigger loopback | `port0/line0` (DI) | `cfg.channels.trigDI = 'port0/line0'` | Physically tee from ao0; records trigger timestamps on the same clock |
| DMD/controller trigger in | Device external-trigger terminal | — | Connected to ao0 output via BNC tee |

**Grounds**: connect AGND and DGND at the NI chassis. Keep the APD cable shield grounded at the DAQ end only (single-point ground). If the APD output impedance is low (Thorlabs avalanche modules: 50 Ω), terminate with a 50 Ω inline terminator at the AI input to avoid reflections at high switch rates.

The physical **pinhole is over the APD aperture**, not in software. Pattern A must physically illuminate the APD; adjust `cfg.pattern.onCoords` until the APD signal is maximised.

---

## Patterns

- **Pattern A** (`cfg.pattern.onCoords = [col row]`): a circular spot (radius `cfg.pattern.radiusPx` pixels) at the given DMD coordinate, aligned to the pinhole over the APD. Before running a sweep, iteratively adjust `onCoords` until the APD voltage is maximised.

- **Pattern B** (`cfg.pattern.offCoords = [col row]`, or `cfg.pattern.offMode = 'alloff'`):
  - `offMode = 'spot'` (default): a spot at `offCoords`, displaced laterally so it misses the pinhole. Produces a dark APD reading.
  - `offMode = 'alloff'`: all DMD mirrors flipped to the "dark" state. Simpler, but exercises only mirror-park mechanics rather than an active switch to a second pattern.

Patterns are built once by `makeTimingPatterns` and cached in `cfg.pattern.stack` (a `logical(nRows, nCols, 2)` array) for reuse across all rates in the sweep.

---

## Trigger Modes

| Mode | Who generates the trigger | DAQ role | Use case |
|---|---|---|---|
| `'external'` (default) | NI DAQ (AO square wave) | Timing master; device is slave | Precise, DAQ-clock-referenced timing; default for characterisation |
| `'internal'` | Device internal pacer (free-runs) | Records APD + device frame-sync output on DI | Measures device's native unloaded frame rate and jitter |

Set via `cfg.trigger.mode`. In `'external'` mode the trigger voltage levels (`cfg.trigger.highV`, `cfg.trigger.lowV`) and duty cycle (`cfg.trigger.pulseWidthFrac`) control the AO waveform. In `'internal'` mode the DAQ AO is silent; the device's frame-sync output is captured on `cfg.channels.trigDI`.

---

## Resolution Caveat

The NI PCIe-6323 AI aggregate bandwidth is ~250 kS/s. Running one AI channel at `cfg.sampleRateHz = 250000` gives a sample period of **4 µs**. Latency and settle times are therefore quantised to ±4 µs.

For DMD mirror-flip timing below 10 µs this quantisation is limiting. Options if finer resolution is needed (not currently implemented):

- Use a **counter-input timestamp** path (NI 6323 supports 32-bit counters at 100 MHz = 10 ns resolution) triggered by the APD signal crossing a threshold — not yet built in this toolset.
- Use a faster digitiser (e.g. NI PXIe-5171, 250 MS/s) as a drop-in replacement.

State your quoted latency/settle values with the ±4 µs digitiser floor when reporting.

---

## Safety

This toolset drives pattern projection through the high-power laser path.

- **Ensure no sample or animal is in the beam** before running any rate sweep.
- Use the **lowest laser power that gives adequate APD contrast** (a few milliwatts at the sample is sufficient for a Thorlabs APD; the NKT FS-50 should be attenuated accordingly).
- Follow the interlocks in `src/+tfp/+util/safetyChecks.m`. Any experiment script that calls the photostimulation laser must call `tfp.util.safetyChecks.assertBeamSafe(cfg)` before arming the DAQ.
- Never leave pattern projection running with the beam uncovered when the scope is unattended.

---

## Outputs

After a sweep, the session directory (`cfg.paths.dataDir/<sessionName>/`) contains:

### `timing_result.mat` (v7.3)

Holds a single variable `result` with fields:

| Field | Type | Description |
|---|---|---|
| `result.sessionDir` | char | Absolute path to the session output directory |
| `result.cfg` | struct | The resolved (merged) timing config used for this run |
| `result.ratesHz` | 1×R double | Commanded rates that were swept (Hz) |
| `result.metrics` | 1×R struct array | Per-rate metrics (see below) |
| `result.maxReliableRateHz` | scalar | Max rate with `trackingOK` and `droppedFraction < 0.05`; `NaN` if none |
| `result.raw` | 1×R cell | Raw `rawCapture` structs from `acquireTimingRun` (or `[]` for failed rates) |
| `result.timestamp` | datetime | When the sweep completed |

Each `result.metrics(i)` struct has fields: `commandedRateHz`, `nTriggerEdges`, `nOpticalTransitions`, `highLevelV`, `lowLevelV`, `contrastV`, `latency_s`, `latencyMean_s`, `latencyMedian_s`, `latencyStd_s`, `riseTime_s`, `fallTime_s`, `riseMean_s`, `fallMean_s`, `achievedRateHz`, `intervalStd_s`, `jitter_s`, `dutyCycle`, `trackingOK`, `droppedFraction`, `edges`, `notes`.

### `timing_summary.png`

A 2×2 figure panel produced by `plotTimingResults`:

1. **Latency vs. rate** — mean ± std trigger-to-light latency (µs).
2. **Rise/fall time vs. rate** — mean 10–90% settle time (µs).
3. **Achieved vs. commanded rate** — scatter plot; dashed unity line.
4. **Dropped-frame fraction vs. rate** — dashed 5% reliability threshold; max reliable rate annotated.

---

## Config Reference

Key fields in the config struct (all accessible via `defaultTimingConfig`):

| Field | Default | Description |
|---|---|---|
| `hardwareKind` | `'mock'` | `'mock'` or `'real'` |
| `device` | `'DMD'` | Device label printed in console summary |
| `useSynthSignal` | `true` | Overlay synthetic APD+trigger trace in mock path |
| `sampleRateHz` | `250000` | DAQ acquisition sample rate (Hz) |
| `aiRangeV` | `[-10 10]` | Analog-input voltage range |
| `makePlots` | `true` | Generate and save `timing_summary.png` |
| `channels.apdAI` | `0` | APD analog-input channel number |
| `channels.trigDI` | `'port0/line0'` | Digital-input line for trigger loopback |
| `channels.trigAO` | `0` | Analog-output channel generating trigger |
| `trigger.mode` | `'external'` | `'external'` (DAQ master) or `'internal'` (device pacer) |
| `trigger.highV` | `5` | Trigger high level (V) |
| `trigger.lowV` | `0` | Trigger low level (V) |
| `trigger.pulseWidthFrac` | `0.5` | Trigger high fraction per half-period |
| `sweep.ratesHz` | `[50 100 200 500 1000 2000 5000 8000 10000 12500]` | Commanded rates to sweep |
| `sweep.transitionsPerRate` | `200` | Optical transitions captured per rate |
| `pattern.onCoords` | `[640 400]` | `[col row]` spot A: aligned to APD pinhole |
| `pattern.offCoords` | `[160 400]` | `[col row]` spot B: off-axis |
| `pattern.offMode` | `'spot'` | `'spot'` or `'alloff'` |
| `pattern.radiusPx` | `14` | Spot radius in DMD pixels |
| `dmd.nRows` | `800` | DMD rows |
| `dmd.nCols` | `1280` | DMD columns |
| `dmd.maxPatternRate` | `12500` | Hard ceiling from DLPC410 spec (Hz) |
| `dmd.darkTimeUs` | `0` | Dark interval between patterns (µs) |
| `dmd.backend` | *(struct)* | ALP SDK: `alpVersion`, `dmdType`, `dllPath`, `protoFile` |
| `paths.dataDir` | `<repo>/data` | Root output directory |
| `synth.latency_s` | `20e-6` | Synthetic model: trigger→50% optical crossing (s) |
| `synth.riseTime_s` | `12e-6` | Synthetic model: 10–90% rise time (s) |
| `synth.fallTime_s` | `12e-6` | Synthetic model: 10–90% fall time (s) |
| `synth.jitterStd_s` | `1e-6` | Synthetic model: per-transition jitter std (s) |
| `synth.highV` | `2.0` | Synthetic APD high level (V) |
| `synth.lowV` | `0.05` | Synthetic APD low level (V) |
| `synth.noiseStd_v` | `0.01` | Synthetic Gaussian noise std (V) |
| `synth.maxTrackRateHz` | `9000` | Above this rate the synthetic device drops transitions |

Override any field by passing a partial struct to `defaultTimingConfig(override)` or directly to `runDMDTimingSweep(cfgOverride, sessionName)`.

---

## PLM (Deferred)

`runPLMTimingSweep_stub.m` is a placeholder for the equivalent PLM switching-timing sweep. It always errors with `tfp:timing:runPLMTimingSweep:notImplemented`.

**Why deferred**: `tfp.hardware.DLPC900_PLM.connect()` only supports a mock transport (`options.mockTransport = true`). The real USB-HID path needed to upload patterns on-the-fly is not yet implemented (hidapi mex / py.hid bridge pending). Without the ability to upload patterns to the hardware, the PLM timing sweep cannot acquire a real optical signal.

**Intended path**: generate two blazed-grating tilt patterns (not flat phase — zero-order is blocked; both patterns must be non-zero tilts steering the focus to different lateral positions), export them as PNGs via `tfp.hardware.PLM.exportPatternImages`, flash them to the DLPC900 in Pre-stored Pattern Mode via the TI LightCrafter GUI, then drive `TRIG_IN_2` (≥20 µs pulse width; level-shifter required from DAQ 3.3 V to ~1.8 V DLPC900 logic) from the DAQ and reuse `acquireTimingRun` / `analyzeTimingTrace` / `plotTimingResults` exactly as the DMD path does. See the help block of `runPLMTimingSweep_stub.m` for the full step-by-step design.

---

## Files

| File | Description |
|---|---|
| [`defaultTimingConfig.m`](defaultTimingConfig.m) | Canonical config struct with all defaults; deep-mergeable override support |
| [`makeTimingPatterns.m`](makeTimingPatterns.m) | Builds the logical(nRows, nCols, 2) A/B pattern stack from config |
| [`synthTimingTrace.m`](synthTimingTrace.m) | Generates a synthetic APD + trigger rawCapture for the no-hardware / test path |
| [`acquireTimingRun.m`](acquireTimingRun.m) | One capture at one commanded rate; hardware-integration shim (mock or real) |
| [`analyzeTimingTrace.m`](analyzeTimingTrace.m) | Core metrics extraction from a rawCapture struct |
| [`runDMDTimingSweep.m`](runDMDTimingSweep.m) | Top-level driver: sweeps rates, aggregates metrics, saves result, prints summary |
| [`plotTimingResults.m`](plotTimingResults.m) | 2×2 summary figure (latency, rise/fall, achieved rate, dropped frames) |
| [`runPLMTimingSweep_stub.m`](runPLMTimingSweep_stub.m) | Deferred stub for PLM timing sweep; always errors; see file for design notes |
