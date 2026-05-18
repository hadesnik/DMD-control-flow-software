# ARCHITECTURE.md — TF-Photostim Control Software

This document specifies the concrete design of the MATLAB control software for the temporal-focusing patterned photostimulation system. Read `CLAUDE.md` first for project context and hardware overview.

## Design principles

1. **Mock-first.** The system must run end-to-end against mock hardware. Real hardware is one config flag away. This isn't a testing convenience; it's how the entire pre-hardware phase of development happens.
2. **One module per concern.** Pattern generation does not know about DAQ. DAQ does not know about trial logic. Trial logic does not know about hardware specifics.
3. **Coordinate transforms are explicit objects.** DMD-pixel → camera-pixel → sample-µm. Each is an affine (or homography) that lives in a calibration struct. Never hard-code transforms.
4. **Time is sacred.** All timestamps in seconds, double precision, on the DAQ master clock. Imaging frames, DMD triggers, stim onsets, and analog signals are all alignable post-hoc to better than the DAQ sample period.
5. **Fail loudly, fail safely.** Any failure in DMD load, DAQ arm, or laser control aborts the trial and disables the Pockels cell. No silent retries on the laser path.

## Module specifications

### `+tfp.+hardware`

#### `DMD` (abstract)

```matlab
classdef DMD < handle
    properties (Abstract, SetAccess = protected)
        nRows           % e.g., 800 for DLP650LNIR
        nCols           % e.g., 1280
        maxPatternRate  % Hz, binary patterns
        isInitialized
    end
    methods (Abstract)
        initialize(obj, config)
        loadPatternSequence(obj, patterns, options)
            % patterns: logical(nRows, nCols, nPatterns)
            % options: struct with .exposureUs, .darkTimeUs, .triggerMode
        armSequence(obj)
        softTrigger(obj)
        advanceToPattern(obj, idx)
        status = getStatus(obj)
        cleanup(obj)
    end
    methods
        % Concrete shared utilities
        function pxCount = activePixelCount(obj, patternIdx)
            % Useful for power-per-target calculations
        end
    end
end
```

#### `MockDMD`

Simulates the device. On `loadPatternSequence`, stores patterns in memory and renders the first one to a debug figure (a `tfp.util.DebugFigure` singleton). On `softTrigger`, advances through the sequence at the configured rate, updating the debug figure. Logs every call with a timestamp to a session log so trial scripts can be validated.

Key behaviors to simulate:
- Pattern load latency (~10 ms per pattern at full size, configurable)
- Trigger-to-mirror-settle delay (~20 µs)
- Optional "stuck mirror" or "dropped trigger" failure modes for testing error handling

#### `DLP650LNIR_DMD`

Talks to the actual hardware. Implementation depends on which SDK we use:
- **Option A**: TI DLPC410 GUI is GUI-only; need third-party. ViALUX ALP-4.3 API has MATLAB wrappers (the lab already uses it for the LCoS SLM rig — check compatibility with DLPC410).
- **Option B**: Treat DMD as a DisplayPort secondary display; render patterns to a `figure` on that display with appropriate timing. Lower control fidelity but no SDK dependency.
- **Decision deferred** until EVM is ordered and we know the controller board.

Initially: write `DLP650LNIR_DMD` as a thin wrapper around whichever API turns out to be available. The interface to the rest of the code is fixed.

#### `DAQ` (abstract)

```matlab
classdef DAQ < handle
    properties (Abstract, SetAccess = protected)
        sampleRate
        analogInChannels
        analogOutChannels
        digitalInChannels
        digitalOutChannels
        isRunning
    end
    methods (Abstract)
        initialize(obj, config)
        configureAnalogInput(obj, channels, rangeV)
        configureAnalogOutput(obj, channels)
        configureDigitalOutput(obj, lines)
        queueAnalogOutput(obj, data)          % data: nSamples × nChannels
        queueDigitalPulses(obj, lineNames, times, durations)
        start(obj)
        stop(obj)
        data = readAnalogInput(obj, nSamples) % blocking until nSamples acquired
        sendDigitalPulse(obj, lineName, durationS)
        cleanup(obj)
    end
end
```

#### `MockDAQ`

Generates synthetic data:
- Analog inputs simulate ephys (Gaussian noise + occasional EPSP-like events) or GCaMP-photodiode (DC + slow drift).
- For closed-loop testing, can be configured with a list of "fake cells" each at a position in DMD coordinates with a response model `f(power, distance) → ΔF/F`. When the active DMD pattern overlaps a fake cell, generate a transient on the appropriate AI channel.
- Digital outputs return immediately; the mock logs their timing for verification.

#### `NI6323_DAQ`

Uses MATLAB's `daq` toolbox (newer `dataacquisition` interface, R2020a+). PCIe-6323 has 32 AI / 4 AO / 48 DIO. Channel assignments to be configured in YAML, not hard-coded.

#### `ScanImageBridge`

Sends commands to ScanImage on the imaging PC. Two options:
- ScanImage exposes a TCP server (`hSI.hScan2D` properties accessible via remote MATLAB session) — use it.
- Fall back to TTL-only triggering with a digital line, no software handshake.

Minimum interface:
```matlab
methods
    armForExternalTrigger(obj, nFrames)
    waitForCompletion(obj, timeoutS)
    [framesPath, frameTimestamps] = getLastAcquisition(obj)
end
```

### `+tfp.+patterns`

Pure functions that generate `logical(nRows, nCols)` arrays representing DMD masks.

```matlab
function mask = singleSpot(dmd, targetCoords, radiusPx, calibration)
function mask = multiSpot(dmd, targetList, radiusPx, calibration)
function patterns = ppsfPattern(dmd, centerTarget, offsetsUm, radiusPx, calibration)
    % Returns nPatterns masks, each with the spot at center+offset
function transformedCoords = calibratedAffine(coords, calibration)
    % DMD pixels ↔ sample µm
function dutyCycle = powerLUT(targetPowerMwPerUm2, calibration)
    % Returns the DMD "on" fraction or pattern-rate scaling needed
```

The calibration struct has at minimum:
```matlab
calibration.dmdToSample_affine    % 3×3 affine, [u v 1] -> [x y 1]
calibration.umPerPixel            % at sample
calibration.pixelsPerUm           % at DMD
calibration.powerCurve            % struct with .dmdActivePx -> .powerAtSample
calibration.timestamp
calibration.notes
```

### `+tfp.+trial`

#### `Trial`

```matlab
classdef Trial < handle
    properties
        trialIdx
        sessionId
        timestamp
        targetSpec       % struct: .cellIds, .dmdCoords, .patternRef
        powerMw          % at sample
        duration_s
        pulseTrain       % struct: .nPulses, .interPulse_s, .pulseWidth_s
        preStim_s        % baseline period
        postStim_s       % response window
        metadata         % free-form struct
    end
    properties (SetAccess = private)
        data             % populated after trial runs
        status           % 'pending' | 'running' | 'complete' | 'failed'
    end
end
```

#### `TrialSequence`

```matlab
classdef TrialSequence < handle
    properties
        trials           % array of Trial objects
        randSeed
        description
    end
    methods
        seq = generatePPSF(targets, distancesUm, nReps, powerMw)
        seq = generateRapidSequential(targets, isi_s, nReps)
        seq = generatePowerCurve(target, powersMw, nReps)
        seq = shuffle(obj, seed)
    end
end
```

#### `Sequencer`

The state machine that runs a session.

```matlab
classdef Sequencer < handle
    properties
        dmd
        daq
        siBridge
        sequence
        log
    end
    methods
        run(obj)
            % for each trial:
            %   1. Load DMD pattern
            %   2. Configure DAQ for this trial duration
            %   3. Trigger ScanImage to start frame acquisition
            %   4. Wait for ScanImage ready signal
            %   5. Fire stim trigger sequence on DMD via DAQ digital out
            %   6. Acquire ephys/sync during trial window
            %   7. Wait for ScanImage to finish
            %   8. Save trial data + metadata
            %   9. Advance to next trial
        abort(obj)        % emergency stop; disables Pockels
    end
end
```

Critical: the `run` loop must check a `safetyAbort` flag every iteration. The Pockels cell must be commanded closed at the start of every trial gap. Laser interlocks live in `+util/safetyChecks.m`.

### `+tfp.+analysis`

Online and offline. Online runs inside `Sequencer.run` between trials to update a live figure.

```matlab
function trace = onlineDFF(frames, roi, baselineFrames)
function isResponder = responseClassifier(trace, baselineWin, responseWin, threshold)
function liveFigures(seqState)  % updates the live experiment figure
```

### `+tfp.+calibration`

The hard part. Routines that establish the DMD↔sample coordinate map and power calibration.

```matlab
function calib = alignDMDtoCamera(dmd, camera, options)
    % Project a sequence of single spots, capture on camera, fit affine.
function calib = measurePSF(dmd, camera, sampleSlab, options)
    % On a thin fluorescent slab.
function curve = powerMeterSweep(dmd, powerMeter, options)
    % Sweep "on" pixel count, record power, build LUT.
```

These calibration routines also have mock versions for testing the pipeline without hardware.

### `+tfp.+experiments`

Top-level scripts that assemble a session. Each one is runnable from the MATLAB command line as a function.

```matlab
function result = exp_ppsf_lateral(config, sessionName)
    % Load config (mock or real hardware)
    % Initialize DMD, DAQ, ScanImage bridge, load calibration
    % Pick target cells from a GCaMP FOV (interactive)
    % Generate a PPSF trial sequence
    % Run the sequencer
    % Quick-look analysis: fit a falloff curve
    % Save full data + figure
end
```

Other experiments mirror this pattern: `exp_rapid_sequential`, `exp_power_curve`, `exp_pseudo_axial`.

### `+tfp.+io`

```matlab
function saveTrial(trial, dataDir)
function config = loadConfig(yamlPath)
function logEntry = sessionLog(sessionId, eventType, payload)
```

Data layout on disk:
```
data/
└── 2026-05-20_mouse42_session1/
    ├── session.yaml                 ← all metadata, config snapshot, git hash
    ├── calibration.mat
    ├── trials/
    │   ├── trial_0001.mat
    │   ├── trial_0002.mat
    │   └── ...
    ├── scanimage_frames/             ← either path-linked from imaging PC or copied
    └── log.txt
```

### `+tfp.+util`

`safetyChecks.m`, `DebugFigure.m`, `Timer.m`, `gitHash.m`, etc.

## Data flow for one trial (concrete)

1. `Sequencer.run` pulls next `Trial` from sequence.
2. Calls `dmd.loadPatternSequence(trial.patternMasks, ...)`. With mock, this updates the debug figure. With real, this pushes patterns to DLPC410.
3. Calls `daq.queueAnalogOutput(...)` for Pockels modulation envelope, `daq.queueDigitalPulses(...)` for DMD advance triggers and ScanImage start.
4. Calls `siBridge.armForExternalTrigger(nFrames)`. Returns when ScanImage is armed.
5. Calls `daq.start()`. DAQ now generates the trigger waveform — first edge starts ScanImage, subsequent edges advance DMD patterns at the configured rate, Pockels envelope opens the beam during stim window.
6. Acquired AI data (ephys + sync) streams back into MATLAB. Mock generates synthetic data based on the active DMD pattern overlapping any "fake cells".
7. After `trial.duration_s`, DAQ stops; Pockels driven to off; ScanImage finishes its frame count.
8. `siBridge.waitForCompletion`. Returns frame timestamps.
9. `analysis.onlineDFF` on the response window → updates live figure.
10. `io.saveTrial(trial)` writes `trial_NNNN.mat`.
11. Sequencer advances.

## Timing budget (rough)

- DMD pattern load: 10 ms for a small sequence, scales with size
- DAQ arm + ScanImage arm: ~50 ms combined
- Trial window: depends — typical PPSF trial is 1–2 s including baseline + response window
- Save: ~20 ms

→ ~2 s per trial is realistic. PPSF with 10 cells × 5 distances × 5 reps = 250 trials = ~8 minutes. Fine.

## Test plan

`tests/` directory:
- `test_MockDMD.m` — load patterns, advance, verify state
- `test_MockDAQ.m` — queue waveforms, simulate acquisition, verify
- `test_TrialSequence.m` — generate sequences, verify metadata
- `test_Sequencer_mock.m` — full session against mocks, verify saved files
- `test_patterns.m` — single/multi spot, PPSF generation
- `test_calibration_mock.m` — fake affine, verify round-trip
- `test_exp_ppsf_lateral_mock.m` — run the full experiment against mocks, check output structure

Every test runs in <30 s. The full suite is the gate before any real-hardware session.

## Phase 1 deliverables (mock-only, target completion in 5 days)

- [x] `+hardware/DMD.m`, `MockDMD.m`
- [x] `+hardware/DAQ.m`, `MockDAQ.m`
- [x] `+patterns/singleSpot.m`, `multiSpot.m`, `ppsfPattern.m`, `calibratedAffine.m`
- [ ] `+patterns/powerLUT.m` (stubbed; not exercised by Phase 1 experiments)
- [x] `+trial/Trial.m`, `TrialSequence.m`, `Sequencer.m`
- [x] `+analysis/onlineDFF.m`, `responseClassifier.m`
- [ ] `+analysis/liveFigures.m` (stubbed; live-figure rendering deferred)
- [x] `+experiments/exp_ppsf_lateral.m`, `exp_rapid_sequential.m`, `exp_power_curve.m`
- [x] `+io/saveTrial.m`, `loadConfig.m`, `sessionLog.m`
- [x] `configs/mock.yaml`
- [x] Tests for all of the above (`test_calibration_mock` deferred to Phase 2/3)

**Milestone achieved as of 2026-05-17.** Running `exp_ppsf_lateral('configs/mock.yaml', 'test_session')` runs end-to-end against mocks and produces a complete fake dataset (18 trials, `.mat` files on disk, well-shaped summary struct). Caveat: the response curve is currently flat noise — MockDAQ does not yet implement fake-cell response coupling, per the deliberate Phase 1 design call to keep cross-coupling logic in the Sequencer-or-experiment layer.

TODO: implement fake-cell response coupling in Sequencer-or-experiment layer (Phase 1.5).

## Phase 2 deliverables (DAQ-real, days 5–7)

- [ ] `+hardware/NI6323_DAQ.m`
- [ ] `+hardware/ScanImageBridge.m`
- [ ] Trigger-timing verification scripts
- [ ] Power calibration routine end-to-end with real power meter
- [ ] Run a complete mock-DMD session on the rig with real ScanImage triggering

## Phase 3 deliverables (DMD-real, NIR DMD arrival → travel)

- [ ] `+hardware/DLP650LNIR_DMD.m`
- [ ] `+calibration/alignDMDtoCamera.m` real-hardware version
- [ ] `+calibration/measurePSF.m` on fluorescent slab
- [ ] First in-vivo PPSF data
- [ ] Rapid sequential targeting data
- [ ] Power curve data
- [ ] Figures for the grant

## Things explicitly out of scope for this sprint

- PLM control (deferred; if it comes online, the abstraction supports adding `+hardware/PLM.m`)
- Closed-loop targeting based on online imaging (this requires reading ScanImage frames in real time; deferred to Aim 3)
- 3D pattern playback at 250 Hz (Aim 1.3, full system)
- Multi-area imaging path (Aim 2)
- GUI

## What success looks like by June 18

A `data/` directory with:
1. One in-vivo PPSF session (~10 cells × 5 distances × 5 reps), with a lateral PPSF curve figure.
2. One rapid-sequential-targeting session, with a raster figure showing each of N cells firing only on its targeted trials.
3. One power-curve session at a single representative cell.
4. (Aspirational) one pseudo-axial session via objective translation.

Plus the codebase committed, documented, and runnable by a collaborator who reads `CLAUDE.md` and `ARCHITECTURE.md`.
