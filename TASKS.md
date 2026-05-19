# TASKS.md — Parallel Work Board

Read AGENTS.md before picking a task.
Read CLAUDE.md and ARCHITECTURE.md for project context.

Each task is self-contained and touches non-overlapping files.
A Claude Code session should:
1. Read CLAUDE.md, ARCHITECTURE.md, and this file
2. Pick one AVAILABLE task whose dependencies are met
3. Mark it IN PROGRESS (edit this file first, commit the change)
4. Complete it, run runtests, confirm no regressions
5. Mark it DONE, commit with the task ID in the message

---

## TASK-P2-01: NI6323_DAQ — Legacy Session Interface [IN PROGRESS]

**CONFIRMED HARDWARE ENVIRONMENT:**
- Target MATLAB version: R2019a
- NI-DAQmx version: 19.5.0
- `daq.getVendors()` confirms `IsOperational: true`
- Use `daq.createSession('ni')` — legacy interface
- Do NOT use `dataacquisition()` or `daq()` — modern interface only
- Device name: 'Dev1' (confirm on scope PC with `daq.getDeviceInfo('Dev1')`)
- All daq calls marked with `%LEGACY_API` comment

**No dependencies.**
**Files (NEW):**
  src/+tfp/+hardware/NI6323_DAQ.m

**Context:**
The scope PC runs MATLAB R2024b with an older shared NI-DAQmx install
that is incompatible with the modern `dataacquisition` interface but
may work with the legacy `daq.createSession` interface. This class
implements the abstract DAQ interface using the legacy API.

**Spec:**
classdef NI6323_DAQ < tfp.hardware.DAQ

Properties (SetAccess = protected):
  sampleRate, analogInChannels, analogOutChannels,
  digitalOutChannels, isRunning

Private properties (trailing underscore):
  session_          % daq.createSession('ni') object
  aoData_           % queued AO waveform
  digitalPulses_    % queued digital pulse specs
  log_              % same struct-array log as MockDAQ

Constructor: NI6323_DAQ(config)
  - config.deviceName: string, e.g. 'Dev1'
  - config.sampleRate: double
  - Calls initialize(config)

Methods — implement against daq.createSession('ni'):
  initialize(obj, config):
    s = daq.createSession('ni');
    s.Rate = config.sampleRate;
    Store session in session_
    Set isRunning = false
    Log call

  configureAnalogInput(obj, channels, rangeV):
    For each channel: addAnalogInputChannel(session_, 
      config.deviceName, channel, 'Voltage')
    Set InputRange to rangeV if specified
    Log call

  configureAnalogOutput(obj, channels):
    For each channel: addAnalogOutputChannel(session_,
      config.deviceName, channel, 'Voltage')
    Log call

  configureDigitalOutput(obj, lines):
    For each line: addDigitalChannel(session_,
      config.deviceName, line, 'OutputOnly')
    Log call

  queueAnalogOutput(obj, data):
    Validate data is nSamples × nAoChans
    Store in aoData_ (queueOutputData called in start())
    Log call

  queueDigitalPulses(obj, lineNames, times, durations):
    Validate lineNames, times, durations are same length
    Store in digitalPulses_ for execution in start()
    Log call

  start(obj):
    if ~isempty(aoData_): session_.queueOutputData(aoData_)
    session_.startBackground()
    isRunning = true
    Log call

  stop(obj):
    session_.stop()
    isRunning = false
    Log call

  data = readAnalogInput(obj, nSamples):
    Use session_.startForeground() for synchronous read
    OR session_.inputSingleScan() for one sample
    Return nSamples × nChans double matrix
    Log call

  sendDigitalPulse(obj, lineName, durationS):
    outputSingleScan on the relevant line:
      high → pause(durationS) → low
    Log call

  cleanup(obj):
    if session_ is valid: session_.release()
    isRunning = false
    Log 'cleanup'

  entries = getLog(obj): return log_

Error identifier: tfp:hardware:NI6323_DAQ:<reason>

**Important notes:**
- NEVER call daq('ni') or dataacquisition() — legacy only
- If daq.createSession('ni') errors with vendor not found,
  throw tfp:hardware:NI6323_DAQ:driverNotFound with a clear
  message explaining the NI-DAQmx version requirement
- Document every daq.createSession call with
  %LEGACY_API comment so future migration to dataacquisition
  is easy to find
- All config fields use configField(config, name, default)
  pattern (see CLAUDE.md conventions)

**No test file** — this class requires real hardware to test.
Instead, add a script: scripts/verify_NI6323_DAQ.m that
instantiates the class, runs a self-test sequence, and prints
pass/fail for each method. This is a manual verification script,
not part of runtests.

**Verify:** runtests still shows 32 passed / 1 failed (no regressions).
The new class file parses without error:
  matlab -batch "addpath('src'); help tfp.hardware.NI6323_DAQ"

---

## TASK-P2-02: DLP650LNIR_DMD — ALP-4.3 Real Hardware [AVAILABLE]

**Note:** calllib/loadlibrary work in both R2019a and R2024b.
No version dependency. Safe to start immediately.

**No dependencies.**
**Files (NEW):**
  src/+tfp/+hardware/DLP650LNIR_DMD.m

**Context:**
Implements the abstract DMD interface against the Vialux ALP high-speed
API via MATLAB's calllib(). Supports two boards via config (see
Multi-board support below):
  - Initial target: DLi4130 kit (DLP7000, ALP-4.1, alp41.dll, 1024×768)
    — in hand now, use for all software development and validation.
  - Final target: DLP650LNIR (ALP-4.3, alp4395.dll, 1280×800)
    — arrives second week of June; switch via config, no code changes.
ALP-4.3 header: vendor/alp/official/alp.h.
ALP-4.1 header: vendor/alp/official-4.1/alp.h.
MATLAB prototype for 4.3 x64: vendor/alp/reference/parot-alptool/alpV43x64proto.m.

Key Phase 3 implementation notes from docs/alp-api-audit.md:
- Use ALP_PROJ_ABORT_ASYNC (2345L) in abort() for mid-trial halt
- Handle ALP_CONFIG_MISMATCH (1021L) and ALP_ERROR_UNKNOWN (1999L)
  as named error cases
- Set ALP_USB_DISCONNECT_BEHAVIOUR (2078L) during initialize()
- ALP_DMDTYPE_WXGA_S450 (12L) is the DLP650LNIR device type constant
- Do NOT use ALP_SYNCHRONOUS/ALP_ASYNCHRONOUS (removed in official)

**Spec:**
classdef DLP650LNIR_DMD < tfp.hardware.DMD

Properties (SetAccess = protected):
  nRows = 800           % DLP650LNIR spec
  nCols = 1280          % DLP650LNIR spec
  maxPatternRate = 12500 % Hz, binary patterns
  isInitialized = false

Private properties (trailing underscore):
  deviceId_       % ALP_ID returned by AlpDevAlloc
  sequenceId_     % ALP_ID returned by AlpSeqAlloc
  dllName_        % 'alp4395' (without extension)
  dllPath_        % path to alp4395.dll on scope PC
  protoFile_      % path to alpV43x64proto.m
  log_            % struct-array session log
  state_          % 'idle' | 'armed' | 'running'

Constructor: DLP650LNIR_DMD(config)
  - config.dllPath: full path to alp4395.dll
  - config.protoFile: full path to alpV43x64proto.m
  - Calls initialize(config)

Methods — implement against ALP-4.3 API via calllib():

initialize(obj, config):
  loadlibrary(dllName_, protoFile_)
  [ret, deviceId] = calllib('alp4395', 'AlpDevAlloc', 0, 0, 0)
  Check ret == ALP_OK (0); throw on failure
  Set ALP_USB_DISCONNECT_BEHAVIOUR via AlpDevControl
  Query nRows/nCols via AlpDevInquire to confirm device type
  Confirm ALP_DMDTYPE_WXGA_S450 (12L)
  isInitialized = true
  Log call

loadPatternSequence(obj, patterns, options):
  Validate patterns is logical(nRows, nCols, nPatterns)
  AlpSeqAlloc: nBitPlanes=1, nPictures=nPatterns
  AlpSeqPut: convert logical patterns to uint8, upload
  AlpSeqTiming: set exposureUs and darkTimeUs from options
  Store sequenceId_
  Log call

armSequence(obj):
  state_ = 'armed'
  currentPatternIdx_ = 0
  Log call

softTrigger(obj):
  AlpProjStart(deviceId_, sequenceId_)
  state_ = 'running'
  Log call

advanceToPattern(obj, idx):
  Use AlpSeqControl to set ALP_FIRSTFRAME/ALP_LASTFRAME
  Log call

status = getStatus(obj):
  Use AlpProjInquire to query projection state
  Return struct matching MockDMD.getStatus() output shape

cleanup(obj):
  AlpProjHalt(deviceId_)
  AlpSeqFree(deviceId_, sequenceId_)
  AlpDevHalt(deviceId_)
  AlpDevFree(deviceId_)
  unloadlibrary(dllName_)
  isInitialized = false
  Log 'cleanup'

abort(obj):
  AlpDevControl(deviceId_, ALP_PROJ_ABORT_ASYNC, 0)
  cleanup(obj)

entries = getLog(obj): return log_

Helper (private):
  checkAlpReturn(obj, ret, funcName):
    Switch on ret:
      0 (ALP_OK): return
      1008 (ALP_NOT_ONLINE): error tfp:hardware:DLP650LNIR_DMD:notOnline
      1021 (ALP_CONFIG_MISMATCH): error ...configMismatch
      1999 (ALP_ERROR_UNKNOWN): error ...unknownError
      otherwise: error ...alpError with ret value

Error identifier: tfp:hardware:DLP650LNIR_DMD:<reason>

**CRITICAL:** Never invent ALP function names. Only use functions
present in vendor/alp/official/alp.h. If unsure, stop and ask.

**Multi-board support (DLi4130 kit available before DLP650LNIR):**
Generalise DLP650LNIR_DMD.m to support both boards via two config
parameters read in initialize():

  config.alpVersion: '4.1' | '4.3'  (default '4.3')
  config.dmdType:    'DLP7000' | 'DLP650LNIR'  (default 'DLP650LNIR')

  alpVersion '4.1'  → dllName_ = 'alp41'
                      nRows = 768, nCols = 1024 (XGA)
                      maxPatternRate = 22727 Hz
                      protoFile from config.protoFile (ALP-4.1 variant)

  alpVersion '4.3'  → dllName_ = 'alp4395'
                      nRows = 800, nCols = 1280 (WXGA)
                      maxPatternRate = 12500 Hz

DLP7000 device type constant is ALP_DMDTYPE_XGA_07A (4L) — present
in both official/alp.h and parot-alptool/alp.h. Confirm in AlpDevInquire
just as for ALP_DMDTYPE_WXGA_S450. Do NOT hard-code nRows/nCols from
the constant value; read them from the config-driven lookup table above.

**No test file** — requires real hardware.
Add scripts/verify_DLP650LNIR_DMD.m as a manual verification script:
  Instantiate, load a checkerboard pattern, project for 2s, cleanup.

**Verify:** runtests still 32/1. File parses:
  matlab -batch "addpath('src'); help tfp.hardware.DLP650LNIR_DMD"
Initial hardware verification on DLi4130 (ALP-4.1, DLP7000) using
configs/dli4130.yaml. Switch to configs/real.yaml when DLP650LNIR arrives.

---

## TASK-P2-03: liveFigures — Live Experiment Display [AVAILABLE]

**No dependencies.**
**Files (MODIFY):**
  src/+tfp/+analysis/liveFigures.m

**Context:**
Currently a stub with error('not implemented'). Implements the live
figure that updates between trials during a session. Called by
Sequencer after each trial via the experiment script.

**Spec:**
function liveFigures(seqState)
  seqState is a struct with fields:
    .trialIdx       current trial number
    .nTrials        total trials in sequence
    .lastTrial      the most recently completed Trial object
    .allTrials      array of all Trial objects so far
    .sessionDir     path to session directory

  Creates or updates (using persistent figure handle) a figure with
  3 subplots:
    1. Progress bar: trialIdx / nTrials
    2. Per-cell response: if lastTrial.data.imaging is non-empty,
       plot the ΔF/F trace for each cell in the last trial,
       colored by whether they responded (peak > 3σ baseline)
    3. PPSF curve so far: if >1 trial completed, plot mean peak
       ΔF/F vs distance for trials completed so far

  Use drawnow() after updating to flush the figure.
  Handle the case where lastTrial.data.imaging is empty
  (Phase 1 compatibility — just show the progress bar).

  Store the figure handle in a persistent variable so successive
  calls update the same figure rather than creating new ones.

Error identifier: tfp:analysis:liveFigures:<reason>

**No new test** — figure output is hard to test automatically.
Verify manually: the existing test suite must still pass 32/1.

---

## TASK-P2-04: powerLUT — DMD Power Lookup Table [DONE]

**No dependencies.**
**Files (MODIFY):**
  src/+tfp/+patterns/powerLUT.m

**Context:**
Currently a stub. Maps from desired power (mW/µm²) at the sample
to the DMD "on" fraction or pattern-rate scaling needed, using a
calibration curve.

**Spec:**
function dutyCycle = powerLUT(targetPowerMwPerUm2, calibration)

  Inputs:
    targetPowerMwPerUm2: scalar or vector of desired power densities
    calibration: struct with fields:
      .powerCurve.dmdActivePx   — vector of active pixel counts
      .powerCurve.powerAtSample — corresponding power measurements (mW)
      .powerCurve.fovAreaUm2    — FOV area in µm² (for density conversion)

  Output:
    dutyCycle: same size as targetPowerMwPerUm2, values in [0,1]
      representing fraction of DMD pixels to turn on to achieve
      the target power density

  Implementation:
    Convert targetPowerMwPerUm2 to absolute power (mW):
      targetMw = targetPowerMwPerUm2 * calibration.powerCurve.fovAreaUm2
    Interpolate calibration.powerCurve.dmdActivePx vs
      calibration.powerCurve.powerAtSample using interp1 (linear)
      to find nActivePx that gives targetMw
    dutyCycle = nActivePx / (nRows * nCols)
      where nRows=800, nCols=1280 (DLP650LNIR)
    Clamp output to [0, 1]
    Warn if any targetPowerMwPerUm2 is outside the calibration range

  For mock/uncalibrated case:
    If calibration.powerCurve is empty or missing,
    return dutyCycle = targetPowerMwPerUm2 / max_power_density
    where max_power_density = 1 mW / (12µm spot area)
    Document this as %ASSUMED fallback

Error identifier: tfp:patterns:powerLUT:<reason>

**Test:** Add to existing tests/test_patterns.m — new Test method:
  powerLUT_interpolates:
    Build a synthetic calibration with known linear curve
    Verify interpolation is correct at midpoint
    Verify clamping at boundaries
    Verify empty calibration returns fallback without error

**Verify:** runtests — test_patterns should gain 1 new passing test.
Total: 33 passed / 1 failed (or more if Phase 1.5 added tests).

---

## TASK-P2-05: configs/real.yaml — Real Hardware Config [AVAILABLE]

**No dependencies.**
**Files (NEW):**
  configs/real.yaml
  configs/dli4130.yaml
  scripts/verify_NI6323_DAQ.m   (referenced by TASK-P2-01)
  scripts/verify_DLP650LNIR_DMD.m  (referenced by TASK-P2-02)

**Context:**
The mock config works for Phase 1 tests. The real hardware config
drives NI6323_DAQ and DLP650LNIR_DMD on the scope PC. Also creates
the verification scripts that TASK-P2-01 and TASK-P2-02 reference.

**Spec — configs/real.yaml:**
hardwareKind: real

dmd:
  dllPath: 'C:\Program Files\ALP-4.3\ALP-4.3 high-speed API\x64\alp4395.dll'
  protoFile: 'vendor\alp\reference\parot-alptool\alpV43x64proto.m'
  loadLatencyMsPerPattern: 10
  debugFigure: false

daq:
  deviceName: 'Dev1'
  sampleRate: 10000
  analogInChannels: [0, 1, 2, 3]
  analogOutChannels: [0, 1]
  digitalOutChannels:
    - 'port0/line0'   # DMD trigger
    - 'port0/line1'   # Pockels cell gate
    - 'port0/line10'  # ScanImage trigger (si trig)

imaging:
  frameRate: 30
  fovSizePx: 512
  fovSizeUm: 800
  simulateLatency: false

session:
  dataDir: 'C:\data'
  calibration_file: ''   # fill in after first calibration run

fakeCells: []   # empty for real hardware — real cells come from suite2p

**Spec — configs/dli4130.yaml:**
hardwareKind: real

dmd:
  alpVersion: '4.1'
  dmdType: 'DLP7000'
  dllPath: 'C:\Program Files\ALP-4.1\alp41.dll'
  protoFile: 'vendor\alp\reference\<alp41-proto>.m'  # fill in when proto confirmed
  loadLatencyMsPerPattern: 10
  debugFigure: false

daq:
  deviceName: 'Dev1'
  sampleRate: 10000
  analogInChannels: [0, 1, 2, 3]
  analogOutChannels: [0, 1]
  digitalOutChannels:
    - 'port0/line0'    # DMD trigger
    - 'port0/line1'    # Pockels cell gate
    - 'port0/line10'   # ScanImage trigger

imaging:
  frameRate: 30
  fovSizePx: 512
  fovSizeUm: 800
  simulateLatency: false

session:
  dataDir: 'C:\data'
  calibration_file: ''

fakeCells: []

Also add to scripts/verify_DLP650LNIR_DMD.m step 1b: when dmdType is
'DLP7000', confirm AlpDevInquire returns ALP_DMDTYPE_XGA_07A (4L).

**Spec — scripts/verify_NI6323_DAQ.m:**
Standalone script (not a test class). Run manually on scope PC.
Tests:
  1. Can instantiate NI6323_DAQ from real.yaml
  2. Can configure AI channels 0-3
  3. Can configure DO line port0/line0
  4. Can read 1000 samples from AI (just noise — card is connected)
  5. Can send a 1ms digital pulse on port0/line0
  6. Can cleanup without error
Prints PASS/FAIL for each step with timing.

**Spec — scripts/verify_DLP650LNIR_DMD.m:**
Standalone script. Run manually on scope PC when board arrives.
Tests:
  1. Can load the ALP DLL (loadlibrary)
  2. Can allocate a device (AlpDevAlloc)
  3. Can confirm device type is ALP_DMDTYPE_WXGA_S450
  4. Can load a checkerboard pattern (AlpSeqAlloc + AlpSeqPut)
  5. Can project for 2 seconds (AlpProjStart)
  6. Can halt and cleanup (AlpProjHalt + AlpDevFree)
Prints PASS/FAIL for each step.

**Verify:** runtests still 32/1 (yaml and scripts don't affect tests).
Files parse: check yaml is valid, scripts have no syntax errors via
  matlab -batch "addpath('src'); run('scripts/verify_NI6323_DAQ.m')"
  (will fail on missing hardware — expected; just confirm no syntax errors)

---

## PHASE 1.5 TASKS

## TASK-15-01: CellResponseModel [DONE]
## TASK-15-02: SyntheticImaging [DONE]
## TASK-15-03: MockScanImageBridge [DONE]
## TASK-15-04: Sequencer + config + loadConfig wiring [DONE]
## TASK-15-05: exp_ppsf_lateral wiring [DONE]

---

## COMPLETED TASKS

TASK-15-01 through TASK-15-05: Phase 1.5 all-optical simulator
  (37/38 tests green, committed 2026-05-19)