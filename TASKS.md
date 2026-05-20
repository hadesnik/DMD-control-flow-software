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

## TASK-P2-01: NI6323_DAQ — Legacy Session Interface [DONE]

**CONFIRMED HARDWARE ENVIRONMENT:**
- Target MATLAB version: R2019b (confirmed 2026-05-20; earlier entries saying R2024b were wrong)
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

## TASK-P2-02: DLP650LNIR_DMD — ALP-4.3 Real Hardware [DONE]

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

## TASK-P2-03: liveFigures — Live Experiment Display [DONE]

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

## TASK-P2-05: configs/real.yaml — Real Hardware Config [DONE]

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

## PHASE 3 TASKS

## TASK-P3-01: RealScanImageBridge [DONE]

**No dependencies.**
**Files (NEW):**
  src/+tfp/+hardware/RealScanImageBridge.m

**Context:**
Verified msocket protocol between scope PC (128.32.177.203)
and ScanImage PC (128.32.177.205). This PC is the SERVER —
it listens on port 3043, ScanImage PC connects to it.

Protocol (from verified SImsocketPrep.m):
  srvsock = mslisten(3043)
  SISocket = msaccept(srvsock, timeoutS)
  msclose(srvsock)
  mssend(SISocket, 'A')
  wait for 'B' from ScanImage PC
  → connection established
  → send trial structs via mssend(SISocket, sendThisSI)
  → sendThisSI.times = stim onset times
  → sendThisSI.power = laser power

msocket library: C:\Users\adesniklab\Documents\MATLAB\msocket\

**Spec:**
classdef RealScanImageBridge < handle
  Implements the same interface as MockScanImageBridge:
  - armForExternalTrigger(obj, nFrames)
  - setActivePattern(obj, patternMask, stimOnsetSec, stimDurationSec)
  - waitForCompletion(obj, timeoutS)
  - [framesPath, frameTimestamps] = getLastAcquisition(obj)
  - getLog(obj)

  armForExternalTrigger: establish msocket connection
    addpath msocket library
    srvsock = mslisten(3043)
    obj.siSocket_ = msaccept(srvsock, timeoutS)
    msclose(srvsock)
    mssend(obj.siSocket_, 'A')
    wait for 'B'

  waitForCompletion: send trial struct and wait for done signal
    sendThisSI.times = obj.stimOnsetSec_
    sendThisSI.power = obj.powerMw_
    mssend(obj.siSocket_, sendThisSI)
    wait for 'received' or 'done' from ScanImage PC

  getLastAcquisition: return frame timestamps
    framesPath = '' (ScanImage saves TIFFs independently)
    frameTimestamps = linspace(0, nFrames/frameRate, nFrames)'

Error identifier: tfp:hardware:RealScanImageBridge:<reason>

---

---

## TASK-P3-02: powerMeterSweep [DONE]

**Files:**
  src/+tfp/+calibration/powerMeterSweep.m
  src/+tfp/+hardware/NI6323_DAQ.m (outputSingleAnalog added)
  scripts/run_powerMeterSweep.m
  vendor/thorlabs/TLPM.m
  vendor/thorlabs/tlpm_mini.h

**Implementation notes:**
- Reads PM100D via TLPM_64.dll (calllib) — no NI-VISA required
- TLPM.m uses vendor/thorlabs/tlpm_mini.h (stripped header, no __fastcall__)
  because MATLAB R2019b loadlibrary cannot parse the full TLPM.h
- MinGW-w64 (MATLAB Add-On) required for one-time thunk compilation
- PM100D serial P0004058, resource auto-discovered by TLPM.findRsrc()
- Two-phase sweep: divided mode (0-5V) + full rep rate (0-1V), merged
  via zero-intercept scale factor over the overlap region

---

## TASK-P3-03: SubstageCamera real implementation [DONE]

**Camera confirmed:** Basler acA2500 GigE (2592×1944, 2.2 µm pitch).
**Files (NEW):**
  src/+tfp/+hardware/BaslerSubstageCamera.m
  configs/real.yaml (camera section added)

**Implementation notes:**
- Adaptor: 'gentl' (requires Basler pylon 6+ with pylon GenTL Producer)
- Format: 'Mono8' (default); 'Mono12' possible if more dynamic range needed
- ExposureTime in µs (GenICam); fallback to ExposureTimeAbs for older firmware
- Run imaqhwinfo('gentl') on scope PC to confirm deviceId (expect 1)
- Verify: snap() returns 1944×2592 double on scope PC with camera connected

---

## TASK-P3-04: measurePSF stub [AVAILABLE]

**No blocking dependency (stub only).**
**Files (NEW):**
  src/+tfp/+calibration/measurePSF.m

**Spec:**
Stub only — full implementation deferred until fluorescent slab is
available on the rig.

  function calib = measurePSF(dmd, camera, sampleSlab, options)
    % Stub: loads a single-spot pattern on DMD, captures a camera frame,
    % fits a 2D Gaussian to the spot, stores lateral FWHM.
    % Full axial sweep not implemented yet.
    error('tfp:calibration:measurePSF:notImplemented', ...
      'measurePSF requires a fluorescent slab — implement when available.');

Add a note at the top of the file describing the planned implementation:
lateral sweep (translate DMD spot across slab, fit Gaussian to each
camera frame), then axial sweep via objective z-drive.

---

## TASK-P3-05: Trial file size refactor [AVAILABLE]

**No dependencies.**
**Files (MODIFY):**
  src/+tfp/+io/saveTrial.m
  src/+tfp/+trial/Sequencer.m

**Context:**
Current trial .mat files are 400–700 KB each. At 250 trials/session
that is ~150 MB — unsustainable for routine archiving. Split into a
small metadata file (always written) and a large rawData file (written
by default, skippable for dry runs).

**Spec:**
saveTrial(trial, sessionDir, options):
  options.saveRawData  — logical, default true

  Always writes:  trial_NNNN_meta.mat
    Fields: trialIdx, status, targetSpec, powerMw, timingSpec,
            responseSummary (peak ΔF/F, cell IDs), fileRef (path to raw)

  When options.saveRawData:
    Also writes: trial_NNNN_raw.mat
      Fields: aiData, dmdLog, daqLog, imaging.F

Sequencer: pass options.saveRawData from session config
  (config.session.saveRawData, default true).

Backward compatibility: existing code that loads trial_NNNN.mat will
not find the new split files — document the schema change in a comment
at the top of saveTrial.m. No migration script needed (data is
ephemeral per-session).

---

## TASK-P3-06: Verify ScanImage msocket protocol [BLOCKED]

**Blocked on:** Masato returning from Japan.
**Files (MODIFY):**
  src/+tfp/+hardware/RealScanImageBridge.m

**Spec:**
Resolve the 5 %VERIFY items in RealScanImageBridge.m by running
verifyProtocol() with the real ScanImage PC connected:

  1. Confirm handshake sequence: server sends 'A', client replies 'B'.
  2. Confirm mssend(socket, struct) works for trial structs (not just strings).
  3. Confirm ScanImage replies 'received' or 'done' after struct send.
  4. Confirm frame timestamps are accessible post-acquisition.
  5. Confirm msocket path (C:\Users\adesniklab\Documents\MATLAB\msocket\).

Replace each %VERIFY comment with confirmed behaviour or a corrected
implementation. No new tests — manual verification on scope PC.

---

## TASK-P3-07: First real DMD test [BLOCKED]

**Blocked on:** BTF power supply arriving (expected tomorrow 2026-05-20).
**Files:** none — this is a hardware milestone, not a code task.

**Spec:**
Run scripts/verify_DLP650LNIR_DMD.m on the DLi4130 board (ALP-4.1,
DLP7000) using configs/dli4130.yaml.

Success criterion: AlpDevAlloc returns ret == 0 (ALP_OK).
This is the first real hardware integration milestone.

Log the outcome (pass/fail per step) and commit a note to
docs/hardware_log.md.

---

## TASK-P3-08: Spatial calibration first run [BLOCKED]

**Blocked on:** TASK-P3-07 (DMD working) + camera model known (P3-03).
**Files:** none — produces configs/calibration_YYYYMMDD.mat artifact.

**Spec:**
Run alignDMDtoCamera with the real DLi4130 + substage camera.
Produces the first real calibration.mat mapping DMD pixel coordinates
to sample µm coordinates.

Steps:
  1. Mount thin fluorescent film on sample stage.
  2. Project known DMD patterns (grid of spots) via verify script.
  3. Capture camera frames via SubstageCamera_generic.
  4. Run alignDMDtoCamera(dmdPts, cameraPts) to fit affine transform.
  5. Save output to configs/calibration_YYYYMMDD.mat.
  6. Spot-check: reproject a few points and verify residuals < 5 µm.

---

## TASK-P3-09: Real-time ROI fluorescence streaming [AVAILABLE]

**Blocked on:** Confirming with Masato that ScanImage ROI Integration
is enabled and whether a frame callback already sends F values back.

**Context:**
ScanImage has built-in ROI Integration that computes mean fluorescence
per ROI per frame in real time (hSI.hIntegrationRoiManager).
If a frame callback on the imaging PC sends these values back via
msocket, the scope PC can plot live ΔF/F traces and a live PPSF
curve during the session — no need to wait for suite2p.

**Architecture:**
Imaging PC (ScanImage) → mssend F values per frame →
Scope PC (ScanImageBridge receives) → liveFigures plots in real time

**Questions for Masato:**
1. Is ROI Integration enabled in your ScanImage setup?
2. Does any existing script send integration values back to scope PC
   during acquisition? (look for mssend calls in ScanImage callbacks)
3. What's the struct format of the integration output?
   (probably hSI.hIntegrationRoiManager.outputChannelsData)

**Files to create/modify:**
  src/+tfp/+hardware/ScanImageBridge.m (MODIFY)
  src/+tfp/+hardware/MockScanImageBridge.m (MODIFY)
  configs/real.yaml (MODIFY)
  configs/mock.yaml (MODIFY)
  scripts/si_frame_callback.m (NEW)

**Spec — ScanImageBridge additions:**
  - Properties: liveF_ (nCells × nFrames accumulator), liveFTimes_,
    nCellsExpected_, streamLiveF_
  - clearLiveTraces(): reset accumulator at trial start (call after armForExternalTrigger)
  - getLiveTraces(): return liveF_ for liveFigures
  - receiveLiveFrame(data): accumulate one frame packet (private)
  - pollLiveFrames(timeoutS): msocket polling loop inside waitForCompletion (private)
  - Config: config.streamLiveF (default false), config.nExpectedCells (default 10)

**MockScanImageBridge additions:**
  - getLiveTraces(): returns lastResult_.F from SyntheticImaging
  - clearLiveTraces(): no-op (F computed all at once in getLastAcquisition)

**Imaging-PC script:**
  scripts/si_frame_callback.m — ScanImage frameAcquiredFcn callback
  that sends hSI.hIntegrationRoiManager.outputChannelsData per frame.
  All ScanImage property names marked %VERIFY pending Masato confirmation.

**Verify:** runtests still green (mock path unaffected; streamLiveF defaults false).

---

---

## TASK-PLM-1: PLM pattern library generator [DONE]

**Depends on:** PLM.m (complete).
**Files (MODIFY):**
  src/+tfp/+hardware/PLM.m

**Context:**
PLM.m already implements the abstract PLM interface and `computeDefocusPattern`.
This task adds `generatePatternLibrary` — a convenience method that sweeps
`computeDefocusPattern` over a range of axial offsets and returns the full
pattern stack with system summary metadata.

**Spec:**
Add method to PLM:

  function [patterns, dz_um, sys] = generatePatternLibrary(obj, n_planes, dz_range_um, obj_name)

  Inputs:
    n_planes      — integer number of axial planes
    dz_range_um   — total axial range in µm (symmetric about 0)
    obj_name      — string key into objective lookup table (see below)

  Outputs:
    patterns      — Ny × Nx × n_planes uint8 array (PLM gray levels 0–31)
    dz_um         — 1 × n_planes double, linspace(-dz_range_um/2, dz_range_um/2, n_planes)
    sys           — struct with fields:
                      .r_PLM_um        radius of PLM active aperture (µm)
                      .N_radius        number of pixels across radius
                      .dz_nyquist_um   Nyquist-limited axial step (µm)
                      .dz_3px_um       3-pixel-quantization axial step (µm)
                      .memory_MB       total pattern stack size in MB

  Implementation:
    Look up objective from obj_name in private lookup table:
      'Avocado'    — f_obj = 16.8 mm, NA = 0.6, tube lens = 180 mm
      'Nikon16x'   — f_obj = 11.25 mm, NA = 0.8, tube lens = 180 mm
      'Olympus20x' — f_obj = 9.0 mm,  NA = 1.0, tube lens = 180 mm
    Throw tfp:hardware:PLM:unknownObjective if obj_name not in table.
    Compute dz_um = linspace(-dz_range_um/2, dz_range_um/2, n_planes).
    Loop: patterns(:,:,k) = obj.computeDefocusPattern(dz_um(k), objective).
    Compute sys fields from objective + PLM geometry.
    Print system summary table to console (fprintf):
      PLM pattern library: <n_planes> planes, <dz_range_um> µm range
      Objective: <obj_name>  NA=<NA>  f_obj=<f>mm
      PLM aperture radius: <r_PLM_um> µm  (<N_radius> px)
      Axial Nyquist step:  <dz_nyquist_um> µm
      3-px quantization:   <dz_3px_um> µm
      Pattern stack:       <memory_MB> MB

Error identifier: tfp:hardware:PLM:<reason>

**Verify:** runtests still green. File parses:
  matlab -batch "addpath('src'); help tfp.hardware.PLM"

---

## TASK-PLM-2: PLM unit tests [DONE]

**Depends on:** PLM.m, MockPLM.m, TIPLM_PLM.m (all complete).
**Files (NEW):**
  tests/+tfp/+hardware/PLMTest.m

**Context:**
No PLM tests exist yet. This task creates a full test class following the
exact structure of the existing DMD tests (e.g. `tests/+tfp/+hardware/DMDTest.m`).
All tests use MockPLM only — no real hardware required.

**Spec:**
classdef PLMTest < matlab.unittest.TestCase

  Test methods to implement:

  computeDefocusPattern_uint8Range:
    MockPLM.computeDefocusPattern(dz_um, obj_struct) returns uint8 array.
    All values in [0, 31].

  computeDefocusPattern_zeroIsFlat:
    dz = 0 gives an all-zero (or all-flat) pattern — verify max(pattern(:)) == 0.

  computeDefocusPattern_outsidePupilIsZero:
    Pixels outside the PLM pupil radius have state 0.
    (Construct a small synthetic PLM with known geometry to make this testable.)

  computeDefocusPattern_180degSymmetry:
    pattern at +dz equals rot90(pattern at +dz, 2) — 180-degree rotational symmetry
    of a circularly symmetric defocus wavefront.

  mockPLM_getLog_recordsCalls:
    Instantiate MockPLM. Call computeDefocusPattern. Call generatePatternLibrary.
    getLog() returns entries with eventType 'computeDefocusPattern' and
    'generatePatternLibrary'.

  tiplm_stubs_throw:
    Instantiate TIPLM_PLM (no hardware needed — constructor must not require
    a connected device).
    Calling displayPattern on TIPLM_PLM throws an MException with identifier
    containing 'tfp:hardware:TIPLM_PLM:notImplemented'.

Error identifier: test identifier not applicable — test class only.

**Verify:** runtests — PLMTest adds ≥ 6 new passing tests.
Total test count increases accordingly. Existing tests unaffected.

---

## TASK-PLM-3: Sync architecture design doc [DONE]

**No code dependencies.**
**Files (NEW):**
  docs/SYNC.md

**Context:**
The PLM (TI NIR PLM, DLPC641 controller) must switch axial planes in sync
with ScanImage frame acquisition. Two trigger architectures are being
evaluated. This task documents both in enough concrete detail that TI can
answer the open questions and the implementation can proceed.

Read the existing DMD trigger logic in DLP650LNIR_DMD.m for context on
how the DMD side of the timing is already structured.

**Spec:**
docs/SYNC.md must cover:

1. Overview: one paragraph on why PLM sync matters (axial multiplexing
   across ScanImage frames) and the two candidate architectures.

2. Option A — PLM as slave (preferred):
   - ScanImage frame-done TTL → DLPC641 TRIG_IN → advances one stored
     pattern per pulse.
   - ASCII timing diagram showing: ScanImage frame clock, TRIG_IN,
     PLM pattern index, laser gate (if any), DAQ acquisition window.
   - Configuration steps: how patterns are preloaded, how TRIG_IN mode
     is armed (I2C command sequence — include known register names from
     TI docs, mark unknowns as %TBD).
   - Latency budget: expected PLM switching latency (~50 µs) vs.
     ScanImage frame period (e.g. 33 ms at 30 Hz) — why this is acceptable.

3. Option B — PLM as master (fallback):
   - PLM sync-out → vDAQ digital input → delayed laser gate;
     ScanImage slaved to PLM via external trigger.
   - ASCII timing diagram for this topology.
   - Why this is more complex (ScanImage frame rate becomes PLM-determined,
     not freely settable).

4. Open questions requiring TI confirmation:
   - TRIG_IN voltage level (3.3 V or 5 V tolerant?).
   - Minimum TRIG_IN pulse width (µs).
   - I2C command sequence to arm trigger mode on DLPC641.
   - Whether PLM sync-out is available on the evaluation board GPIO.
   - Maximum preloaded pattern count in DLPC641 memory.

5. Recommended path: Option A, pending TI answers to questions above.

**Verify:** File exists at docs/SYNC.md. runtests unaffected.

---

## TASK-PLM-4: Psychtoolbox display scaffold [DONE]

**Depends on:** TIPLM_PLM.m (complete).
**Files (MODIFY):**
  src/+tfp/+hardware/TIPLM_PLM.m

**Context:**
TIPLM_PLM.m currently stubs out `displayPattern` with
`tfp:hardware:TIPLM_PLM:notImplemented`. This task implements the
Psychtoolbox (PTB) display path up through `Screen('Flip')`, which is
how the DLPC641 receives patterns over DisplayPort from the scope PC.

Bitplane encoding (how uint8 gray levels map to DLPC641 binary pattern
slots) is TBD pending TI documentation — leave a clearly marked TODO.

**Spec:**
Implement in TIPLM_PLM.m:

  displayPattern(obj, pattern_uint8):
    Validate pattern_uint8 is uint8, size matches obj.nRows × obj.nCols.
    Detect secondary screen: screens = Screen('Screens').
      If numel(screens) < 2, warn('tfp:hardware:TIPLM_PLM:noSecondScreen', ...).
      Use screens(end) as the PLM display (last screen index = secondary monitor).
    Open or reuse PTB window (persistent private property ptbWin_):
      If ptbWin_ is empty or invalid: ptbWin_ = Screen('OpenWindow', screenIdx, 0).
    Encode pattern: gray = obj.encode_for_DLPC641(pattern_uint8).
    Upload texture: tex = Screen('MakeTexture', ptbWin_, gray).
    Draw: Screen('DrawTexture', ptbWin_, tex).
    Flip: Screen('Flip', ptbWin_).
    Close texture: Screen('Close', tex).
    Log call.

  Private method encode_for_DLPC641(obj, pattern_uint8):
    Scales uint8 states 0–31 linearly to 0–255 grayscale (multiply by 8,
    clamp to 255). Returns uint8 Ny × Nx × 3 RGB image (replicate across
    RGB channels for grayscale display).
    Add comment block:
      % TODO: bitplane packing TBD pending TI DLPC641 docs.
      % Current implementation sends linear grayscale; DLPC641 may
      % interpret specific bit patterns as binary pattern indices.
      % Replace this encoding once TI confirms the DisplayPort protocol.

  Teardown method closePTBWindow(obj):
    If ptbWin_ is valid: Screen('Close', ptbWin_).
    Set ptbWin_ = [].
    Log call.

  Private property: ptbWin_ (initialized to [] in constructor).

Error identifier: tfp:hardware:TIPLM_PLM:<reason>

**Verify:** runtests still green (TASK-PLM-2 test for notImplemented stub
will need updating — TIPLM_PLM.displayPattern now runs rather than throwing;
update that test to verify Screen is called, or skip if PTB not on path).
File parses: matlab -batch "addpath('src'); help tfp.hardware.TIPLM_PLM"

---

---

## TASK-FUTURE-01: Bidirectional TCP ScanImage control [FUTURE]

**Deferred:** 2026-05-20. Implement post-grant if needed.
**Not on the critical path for preliminary data.**

**Context:**
`crossRegisterScanImage` currently uses Option A: the operator manually
sets ScanImage's scan pixel count (e.g. 512×256) before calling the
function. A future implementation would drive scan geometry directly from
the DAQ PC via TCP, enabling fully automated calibration without operator
intervention at the ScanImage workstation.

**Scope:**
  - Add `setScanGeometry(obj, nFast, nSlow)` to `ScanImageBridge` (tcp mode):
      hSI.hScan2D.scanPixelsPerLine = nFast
      hSI.hScan2D.linesPerFrame     = nSlow
      hSI.hScan2D.pixelBinFactor    = 1  (ensure square pixels)
    All property names marked %VERIFY against installed ScanImage version.
  - Add `setScanMode(obj, mode)` for 'focus' | 'grab' (tcp mode only).
  - Update `crossRegisterScanImage` to accept an optional `siBridge`
    argument (Option B flow): when provided, call setScanGeometry and
    setScanMode('focus') before snapping the camera.
  - Resolve TASK-P3-06 %VERIFY items before implementing.

---

## TASK-CAL-1: crossRegisterScanImage + verifyScanFieldComposition [IN PROGRESS]

**No blocking dependencies (works with mock hardware).**
**Files (NEW):**
  src/+tfp/+calibration/crossRegisterScanImage.m
  src/+tfp/+calibration/crossRegisterScanImage_mock.m
  src/+tfp/+calibration/verifyScanFieldComposition.m

**Files (MODIFY):**
  src/+tfp/+hardware/MockSubstageCamera.m  (add scan-rectangle rendering mode)
  tests/test_calibration_mock.m            (add 3 new test methods)

**Context:**
Implements the critical gap in the prelim-data calibration pipeline.
Step A (alignDMDtoCamera) is done. Step B is missing.
The verify step (operator confirmation of axis signs) has no implementation.

**crossRegisterScanImage spec:**
  function calib = crossRegisterScanImage(camera, existingCalib, options)
    Prereq: ScanImage running in Focus mode with non-square pixels
    (e.g. 256 lines × 512 pixels per line); fluorescent film on stage.

  options:
    .scanNCols (default 512), .scanNRows (default 256)
    .fovSizeUm (default 800), .exposureS (default 0.2)
    .showFigure (default true), .fastSign (default 1), .slowSign (default 1)

  Algorithm:
    1. snap() camera frame
    2. Otsu threshold → largest connected component → ConvexHull
    3. Minimum-area bounding rectangle (rotating calipers on hull)
    4. Assign 4 MABR corners to scan-field corner coords using fastSign/slowSign
    5. fitAffineCalib(sfPts, camPts) → scanToCam_affine
    6. Compose: dmdToScan_affine = inv(scanToCam) * dmdToCam
       (only if existingCalib.dmdToSample_affine is present)

  Output calib fields (extends existingCalib):
    .scanToCam_affine, .dmdToScan_affine, .scanNCols, .scanNRows
    .scan_fast_axis_sign, .scan_slow_axis_sign, .fovSizeUm
    .scanResidualErrorPx, .scanTimestamp, .scanNotes, .scanVerified

**verifyScanFieldComposition spec:**
  function calib = verifyScanFieldComposition(dmd, calib, options)
    options.testDmdCoord  — [col, row], default [dmd.nCols/2, dmd.nRows/2]
    options.fovSizeUm     — default from calib.fovSizeUm or 800
    options.mockResponse  — [fastSign, slowSign] to bypass input() in tests
    options.showFigure    — display diagnostic (default true)

  Algorithm:
    1. Project a single DMD spot at testDmdCoord
    2. Apply calib.dmdToScan_affine to get predicted scan-field [col, row]
    3. Convert to µm: x_um = (col/(scanNCols-1) - 0.5) * fovSizeUm
    4. Print: "Set ScanImage mROI center to: (X µm, Y µm)"
    5. Ask operator: "Is the DMD spot centered in the mROI? [y/n]"
       (or use mockResponse to bypass)
    6. If 'n': try all 4 sign combinations; recompute dmdToScan each time
    7. Update calib: scan_fast_axis_sign, scan_slow_axis_sign, dmdToScan_affine,
       scanVerified = true, scanVerifyTimestamp

**MockSubstageCamera scan-rectangle mode:**
  New config fields in initialize():
    config.scanTruthAffine  — 3×3, scan-field [col,row] → camera [x,y]
    config.scanNCols        — scan cols (default 512)
    config.scanNRows        — scan rows (default 256)
    config.scanMode         — logical (default false)
  When scanMode=true and scanTruthAffine is set, snap() renders a filled
  bright rectangle instead of DMD spots.

**Tests (add to test_calibration_mock.m):**
  crossRegisterScanImage_mock_fields:
    calib = crossRegisterScanImage_mock(); — verify required fields present.

  crossRegisterScanImage_live_mock:
    Build MockSubstageCamera in scanMode with a known scanTruthAffine.
    Run crossRegisterScanImage. Recovered scanToCam_affine must match
    truth within 1 px translation, 0.05 scale. scanResidualErrorPx < 2 px.

  crossRegisterScanImage_composition:
    Verify dmdToScan round-trip: apply dmdToScan_affine to a DMD point
    and check consistency with manual inv(scanToCam) * dmdToCam. Error < 0.5 px.

**Verify:** runtests gains 3 new passing tests. Existing tests unaffected.

---

## COMPLETED TASKS

TASK-15-01 through TASK-15-05: Phase 1.5 all-optical simulator
  (37/38 tests green, committed 2026-05-19)
TASK-P3-01: RealScanImageBridge (msocket) — structured VERIFY docs +
  verifyProtocol() diagnostic method (committed 2026-05-19)
TASK-PLM-2: PLM unit tests — tests/test_MockPLM.m, 13 tests covering
  computeDefocusPattern physics, pupil mask, 180° symmetry, MockPLM log,
  TIPLM_PLM stubs (committed 2026-05-20)