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

## TASK-P3-02: powerMeterSweep [NEEDS HARDWARE VERIFICATION]

**Code complete. All remaining steps require the scope PC.**

**Files implemented:**
  src/+tfp/+calibration/powerMeterSweep.m
  src/+tfp/+calibration/powerMeterSweep_mock.m
  src/+tfp/+hardware/NI6323_DAQ.m  (outputSingleAnalog added)
  scripts/run_powerMeterSweep.m

**What was built:**
Sweeps the FS-50 analog modulation input (Dev1/ao1) from 0–5 V in 25
steps, reads sample-plane power at each step via Thorlabs PM100D (S350C
thermal sensor) using the TLPM MATLAB driver, saves a `curve` struct
(voltageV, powerMw, powerStdMw, timestamp, notes) to a dated .mat file,
and plots the result. outputSingleAnalog auto-adds the AO channel to the
NI session if not yet configured, so no pre-configuration is needed.

**Pre-run checklist (do these before running on scope PC):**

> Laser note (2026-07-24): the NKT FS-50 referenced below was removed from this
> rig; the incoming laser is a Light Conversion Carbide (40 W), ~early Sept 2026.
> Re-confirm the AO channel/wiring and the Carbide's V→power behaviour before use.

  [ ] Physical setup
        PM100D connected via USB; S350C sensor attached.
        FS-50 analog modulation BNC → Dev1/ao1 on NI-6323.
        Sensor placed at sample plane (or exit pupil — note placement
        in the script's options.notes field before saving).

  [ ] Confirm FS-50 AO input polarity and range
        The script assumes 0 V = minimum power, 5 V = maximum power.
        Check FS-50 front panel or manual: if the sense is inverted
        (5 V = off, 0 V = full power), reverse voltageSteps in the
        script: options.voltageSteps = linspace(5, 0, 25).

  [ ] Verify TLPM measPower calling convention
        The real-hardware path uses a libpointer to receive the reading
        (powerMeterSweep.m lines 105–107). On the scope PC, run:
          pm = TLPM(); deviceCount = pm.findRsrc();
          rn = pm.getRsrcName(0); pm.init(rn, true, true);
          val = pm.measPower();
        If measPower() returns a scalar directly (no libpointer), replace
        the three-line block with: readings(j) = pm.measPower() * 1e3;
        The comment in powerMeterSweep.m (line 102) describes the swap.

  [ ] Verify pm.getRsrcName method name
        The TLPM MATLAB class ships with a few different wrapper versions.
        If pm.getRsrcName(0) throws "no such method", check:
          methods(pm)
        Common alternatives: getRsrcName, getResourceName, resourceName.
        Update powerMeterSweep.m line 80 with the correct name.

**Running the sweep:**
  cd to repo root on scope PC, then:
    >> addpath(fullfile(pwd, 'src'));
    >> run scripts/run_powerMeterSweep.m
  Expected duration: ~2 min (25 steps × 3 s settle + 5 s warmup).
  Output: power_curve_YYYYMMDD_HHMMSS.mat in the current directory.

**After a successful run:**
  [ ] Move the saved .mat to configs/ and update calibration_file in
      configs/windowed_mouse_v1.yaml:
        calibration_file: 'configs/power_curve_YYYYMMDD_HHMMSS.mat'
  [ ] Note in the .mat curve.notes: sensor position, NDF filters in
      path (if any), beam block / shutter state.
  [ ] Identify the AO voltage that delivers the target experiment power
      (~5–15 mW at sample for ChRmine). Record it in the rig log.

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

**Depends on:** PLM.m, MockPLM.m, DLPC900_PLM.m (all complete).
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
    Instantiate DLPC900_PLM (no hardware needed — constructor must not require
    a connected device).
    Calling displayPattern on DLPC900_PLM throws an MException with identifier
    containing 'tfp:hardware:DLPC900_PLM:notImplemented'.

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

## TASK-CAL-1: crossRegisterScanImage + verifyScanFieldComposition [DONE]

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

## TASK-PLM-5: Single-spot remote focus validation patterns [DONE]

**Depends on:** PLM.m (complete).
**Files (NEW):**
  scripts/generate_plm_single_spot_validation.m

**Description:** Generate 3 phase patterns demonstrating remote focusing of a
single diffraction-limited spot, laterally offset to avoid the zero-order
block. Each pattern = blazed grating tilt (100 µm lateral offset at sample) +
defocus phase. Three planes: dz = -150, 0, +150 µm. Wrap mod max_phase,
quantize to 32 states. Save .mat files per pattern plus a preview PNG montage
to `data/plm_patterns/validation/`.

---

## TASK-PLM-6: 50-spot multi-target CGH validation patterns [DONE]

**Depends on:** PLM.m (complete).
**Files (NEW):**
  scripts/generate_plm_multispot_validation.m

**Description:** Generate phase patterns producing 50 random diffraction-
limited spots via the random superposition (RS) algorithm: per-spot tilt +
defocus + random phase offset, sum complex fields, take angle, quantize.
Three patterns: spots in z = [-150, 0], z = 0, z = [0, +150] µm. Spot xy
positions uniformly random in 200×200 µm FOV at sample, excluding 30 µm
radius around optical axis. Save .mat files + preview PNG showing pattern and
expected far-field (2D FFT of exp(1j·phi)) to `data/plm_patterns/validation/`.

---

## TASK-PLM-7a: Rename TIPLM_PLM → DLPC900_PLM [DONE]

**Depends on:** TIPLM_PLM.m (complete).
**Files (RENAME/MODIFY):**
  src/+tfp/+hardware/TIPLM_PLM.m → src/+tfp/+hardware/DLPC900_PLM.m
  src/+tfp/+hardware/PLM.m            (update TIPLM_PLM in class comment, lines 3 and 10)
  tests/test_MockPLM.m                (update 4 references: class comment line 3,
                                       makeTiplm line 20, tiplm_stubs error IDs lines 228+230)
  TASKS.md                            (update TIPLM_PLM references in PLM-2 spec and PLM-7 depends-on)

**Context:**
TI confirmed the 0.67" PLM EVM uses the dual-DLPC900 controller (same
as DLP6500), not the DLPC641 as initially assumed. Rename reflects this.
This is a pure rename — no behavioural changes. All notImplemented stubs
and tests preserved. Update error identifiers:
  tfp:hardware:TIPLM_PLM:* → tfp:hardware:DLPC900_PLM:*

**Verify:** runtests still passes the same count. PLM tests pass with updated
error identifier strings.

---

## TASK-PLM-7: DLPC900 USB pattern loading and external trigger configuration [DONE]

**Depends on:** TASK-PLM-7a (rename complete), DLPC900 Programmer's Guide (DLPU018).
**Files (MODIFY):**
  src/+tfp/+hardware/DLPC900_PLM.m
**Files (NEW):**
  tests/test_DLPC900_PLM.m

**Description:** Implement USB HID interface to dual-DLPC900 controller per
TI's confirmation that the 0.67" PLM EVM uses the same controller as the
DLP6500. Reference Pycrafter6500 (public GitHub) for command structure.
Methods to add: `connect()`, `uploadPatternSequence(patterns, exposure_us,
triggerMode)`, `configureTrigger(mode)`, `startSequence()`, `stopSequence()`,
`uploadTwoPatternFlipTest(flat, grating, freq_Hz)`. Encode 5-bit phase states
into DLPC900 bitplane format. Configure TRIG_IN_2 for external pattern
advance (rising edge, ~20 µs min pulse width per TI). Every USB command
validates return status; failures throw `tfp:hardware:DLPC900_PLM:usbError`
with command and status detail. Unit tests exercise bitplane encoding on
mock data (no USB). Hardware testing deferred until EVM arrives.

---

## TASK-EXP-FF: Ensemble fill-factor power-modulation experiment [DONE 2026-05-22]

**No dependencies.** Pure mock build; runs end-to-end against MockDMD/MockDAQ.
**Files (NEW):**
  src/+tfp/+patterns/fillFactorEnsemble.m
  src/+tfp/+experiments/exp_ensemble_fill_factor_power.m
  scripts/run_ensemble_fill_factor_power.m
  tests/test_ensemble_fill_factor_mock.m

**Context:**
Hero-figure experiment for the BRAIN R01: hold the laser AO command at a
fixed voltage and modulate effective power per neuron by varying the
fraction of DMD pixels lit inside each per-neuron disk. Replaces analog
power sweeps with a DMD-only sweep, which is the unique capability the
DMD has over an SLM.

**What got built today:**
1. **Per-neuron disk subsampling** — `fillFactorEnsemble(dmd, centroids,
   radiusPx, fractions)` builds a logical mask per ROI by drawing a
   filled disk, then keeping a random `fractions(i)` subset of its pixels.
   Same RNG stream consumed across calls for reproducibility.
2. **Two conditions wired into the experiment**:
   - **Uniform sweep:** all ROIs share the same fill fraction; sweep
     10%–100% in 10% steps, 10 repeats per level (100 trials).
   - **Differential per-cell:** each ROI gets its own fill fraction in
     a single trial — used to drive distinct effective powers
     simultaneously across the ensemble. 10 repeats.
3. **10-repeat averaging** added to both conditions; trial structure
   logs per-ROI fill fraction and the realized pixel count so post-hoc
   analysis can recover the actual delivered "dose" per cell.
4. **Illuminated-region awareness**:
   - New `options.illuminatedRegion = [c0 c1 r0 r1]` argument bounds the
     DMD region actually lit by the laser (π-Shaper flat-top footprint).
   - Soft check emits `tfp:experiments:exp_ensemble_fill_factor_power:roiOutsideIllumination`
     warning if any ROI disk extends outside the lit zone — pixels there
     contribute zero power even though they're "on" in the mask.
   - Live figure (and mock-test companion figure) draws a yellow dashed
     outline of the region beneath the ROI markers.
   - `scripts/run_ensemble_fill_factor_power.m` and the mock test default
     to a 300×300 px region centered on the chip (~100 µm pilot FOV at
     ~3 DMD px/µm).

**Commits:**
  8f1a995 — fill-factor ensemble power modulation via per-neuron disk subsampling
  ec74efa — 10-repeat averaging + differential per-cell condition
  1df6c48 — illuminated-region warning + outline

**Verify:** `tests/test_ensemble_fill_factor_mock.m` runs the full
sequencer end-to-end on the mock stack; existing test count unaffected.

**Open follow-ups:**
- [ ] Decide whether to promote `illuminatedRegion` from a per-experiment
      option to a rig-level config field (likely yes — same number applies
      to every fill-factor / multi-spot experiment on this beam path).
- [ ] Confirm the 3 DMD px/µm scale on the real rig once the affine from
      `alignDMDtoCamera` is measured; adjust the 300 px default if needed.

---

## TASK-SYNC-ALIGN: Frame-precise stim → ScanImage frame association [IN PROGRESS]

**Goal:** Every ScanImage acquired frame is unambiguously tagged with the
stim condition active during that frame (trial id, condition 1/2,
sub-condition index, repeat index, per-cell fill fractions, phase relative
to stim onset). Achieved via two complementary timestamp paths recorded in
the trial schema so post-hoc analysis can use either or cross-check both:

  **(a) Out-pulse path** — DAQ emits a TTL on a DO line at every trial
       onset (and a longer pulse at session start). ScanImage records this
       on its aux input. Each rising edge in the aux trace = one trial
       onset in ScanImage's clock. Robust and minimal: only needs ScanImage
       to record the aux channel.

  **(b) In-capture path** — DAQ captures ScanImage's frame TTL on a DI
       line via a continuous hardware-clocked session running for the
       whole experiment. Each frame's rising edge gets a DAQ sample index.
       Trial onsets/offsets are also recorded in DAQ samples (clocked AO,
       not `outputSingleAnalog` + `pause`). A post-hoc lookup table assigns
       each frame to a trial/condition. This is the canonical precision
       path; the out-pulse path is the resilient backup + cross-check.

Once both are in, the per-trial result struct records:
  - `t_onset_daq_samples`, `t_offset_daq_samples`     (in-capture)
  - `t_onset_si_aux_edge_index`                       (out-pulse, filled
                                                       post-hoc from the
                                                       aux trace)
  - `frame_indices_during_stim`, `frame_indices_baseline`  (post-hoc)
  - `daq_master_sample_rate_hz`, `session_start_datetime`

---

### Sub-tasks

**Round 0 — Out-pulse path [PARTIAL]**

- [x] T-OUT-1  options + per-trial DO pulse in `exp_ensemble_fill_factor_power.m`
      Files: `src/+tfp/+experiments/exp_ensemble_fill_factor_power.m`,
             `src/+tfp/+hardware/NI6323_DAQ.m` (mixed AO/DO output fix),
             `tests/test_ensemble_fill_factor_mock.m`,
             `scripts/run_ensemble_fill_factor_power.m`
      `syncDOLine` + `sessionStartPulseS` + `trialOnsetPulseS` options
      wired through; pulses fired via `daq.sendDigitalPulse` on session
      start and each trial onset. Per-trial wall-clock + tic/toc
      timestamps recorded into `result.timing.run` (host-side; Round 3
      will add canonical DAQ-sample fields alongside).
      Commit: 3c6def9

- [ ] T-OUT-2  same options + pulse emission in `exp_ensemble_activation.m`
      Files: `src/+tfp/+experiments/exp_ensemble_activation.m`,
             `tests/test_ensemble_activation_mock.m`,
             `scripts/run_ensemble_activation.m`

- [ ] T-OUT-3  propagate to remaining experiments (optional for R01 prelim)
      Files: `src/+tfp/+experiments/{exp_ppsf_lateral,exp_power_curve,exp_pseudo_axial,exp_axial_ppsf,exp_rapid_sequential,exp_ppsf_2d}.m`

**Round 1 — Sync spec + abstract base + trial schema [SEQUENTIAL, single agent]**

Must land before anything in Round 2 starts. Single commit, no
implementations — only signatures, schema, and docs.

- [ ] T-SYNC-1  `docs/SYNC_FRAME.md` (or extend `docs/SYNC.md`):
                  - DAQ master-clock model
                  - Out-pulse pulse spec (line, widths, edges) — already in
                    code; this just documents it.
                  - In-capture continuous-session API contracts:
                      `startContinuousSession(cfg)`,
                      `stopContinuousSession()`,
                      `currentSampleIndex()`,
                      `queueClockedAO(samples, rate, startTrigger)`
                  - Frame-clock DI encoding (rising edges = frame start,
                    one pulse per frame, polarity)
                  - Trial schema fields and units
                Files: NEW `docs/SYNC_FRAME.md`,
                       `src/+tfp/+hardware/DAQ.m` (add abstract method
                       signatures, no body),
                       `src/+tfp/+trial/Trial.m` (add new schema fields,
                       SetAccess private, with markRunning/markComplete
                       transitions updated)

**Round 2 — Independent implementations [6 parallel agents, each touches one file]**

All 6 code against the locked Round 1 spec; no inter-agent dependencies.

- [ ] T-SYNC-2  MockDAQ continuous session + clocked AO + synthetic frame clock
                Files: `src/+tfp/+hardware/MockDAQ.m`

- [ ] T-SYNC-3  NI6323_DAQ continuous session + clocked AO + frame-clock DI capture
                Files: `src/+tfp/+hardware/NI6323_DAQ.m`
                Note: only mock-verifiable on Mac; final verification
                belongs to T-SYNC-7 on the scope PC.

- [ ] T-SYNC-4  `tfp.io.decodeFrameClock(diVec, sampleRate)` → frame start
                samples + inferred frame rate. Unit tests with synthetic
                pulse trains (regular, jittered, missing pulses, polarity).
                Files: NEW `src/+tfp/+io/decodeFrameClock.m`,
                       NEW `tests/test_decodeFrameClock.m`

- [ ] T-SYNC-5  `tfp.io.alignTrialsToFrames(trials, frameStartSamples)` →
                per-trial frame index lists + per-frame condition table.
                Files: NEW `src/+tfp/+io/alignTrialsToFrames.m`,
                       NEW `tests/test_alignTrialsToFrames.m`

- [ ] T-SYNC-6  Extend `tfp.io.saveTrial` for the new schema fields
                (preserve backward compat with existing trial files).
                Files: `src/+tfp/+io/saveTrial.m`, related test

- [ ] T-SYNC-7  Sync verification script for the scope PC: scopes the
                TTL + AO lines, captures and decodes the frame clock,
                asserts timing precision (jitter, latency, edge alignment).
                Codes against Round-1 API only; doesn't need Round-2 done.
                Files: NEW `scripts/verify_sync.m`

**Round 3 — Experiment refactor [3 parallel agents]**

Depends on T-SYNC-2 (mock path) and T-SYNC-6 (trial schema persistence).

- [ ] T-SYNC-8  Refactor `exp_ensemble_fill_factor_power.m`:
                  - Start continuous DAQ session at top, stop at end.
                  - Replace `outputSingleAnalog + pause` with clocked AO
                    (the DO out-pulse already records onset; keep it).
                  - Record `t_onset_daq_samples` / `t_offset_daq_samples`
                    per trial in the result struct.
                  - Save per-trial `.mat` via `tfp.io.saveTrial`.
                Files: `src/+tfp/+experiments/exp_ensemble_fill_factor_power.m`

- [ ] T-SYNC-9  Same refactor for `exp_ensemble_activation.m`.
                Files: `src/+tfp/+experiments/exp_ensemble_activation.m`

- [DEFERRED] T-SYNC-10 Same refactor for the remaining experiments
                (optional for R01 prelim).
                Files: `src/+tfp/+experiments/{exp_ppsf_lateral,exp_power_curve,exp_pseudo_axial,exp_axial_ppsf,exp_rapid_sequential,exp_ppsf_2d}.m`
                Note: `exp_axial_ppsf.m` already has PLM Sequencer
                integration; this refactor is more invasive there —
                handle separately.
                **Deferred 2026-05-22** — investigation found the listed
                experiments all delegate per-trial AO/timing to
                `tfp.trial.Sequencer` (`exp_ppsf_lateral`,
                `exp_power_curve`, `exp_rapid_sequential`,
                `exp_ppsf_2d`, `exp_axial_ppsf`); `exp_pseudo_axial.m`
                does not exist in-repo. The continuous-session +
                `queueClockedAO` + `markRunning(onsetSample,…)` +
                `saveTrial` pattern from T-SYNC-8/9 lives inside that
                per-trial loop, so applying it requires modifying
                `src/+tfp/+trial/Sequencer.m` (which calls
                `daq.start()` / `daq.stop()` per trial — incompatible
                with a continuous session held open across trials).
                A wrapper around `sequencer.run()` from the
                experiment files alone cannot work: the legacy
                `start/stop` calls toggle `isRunning` and would
                desynchronize the continuous-session state machine.
                **Prerequisite for resuming:** add a new Sequencer
                refactor sub-task that switches the per-trial loop to
                continuous-session APIs and the extended
                `markRunning` / `markComplete` signatures, then
                propagate to the listed experiments.

**Round 4 — Tests + runners + integration [3 parallel agents]**

Depends on Round 3.

- [ ] T-SYNC-11 Update mock tests to assert new behavior — frame-clock
                decode roundtrip, monotonic trial samples, per-trial
                onset/offset present, out-pulse + in-capture cross-check
                within tolerance.
                Files: `tests/test_ensemble_fill_factor_mock.m`,
                       `tests/test_ensemble_activation_mock.m`

- [ ] T-SYNC-12 Update scope-PC runner scripts to enable continuous
                session capture + save the full session DI/AI buffers.
                Files: `scripts/run_ensemble_fill_factor_power.m`,
                       `scripts/run_ensemble_activation.m`

- [ ] T-SYNC-13 End-to-end mock integration test: full session →
                `saveTrial` → reload → reconstruct frame→condition table
                → verify a synthetic GCaMP trace bins correctly by
                condition.
                Files: NEW `tests/test_sync_endtoend_mock.m`

---

**Parallelism summary:**
  Round 0: 1 agent (T-OUT-2), 1 deferred (T-OUT-3)
  Round 1: 1 agent (sequential prereq)
  Round 2: 6 parallel agents
  Round 3: 3 parallel agents
  Round 4: 3 parallel agents

**File-conflict map:** Each Round-2/3/4 sub-task touches a distinct file
list above; parallel agents will not collide as long as they stay within
their assigned file lists.

---

## TASK-EP: Switch ScanImage from continuous to episodic acquisition

**Tracking prefix:** `T-EP-`. **Top-level item:** TODO.md C9.
**Architecture target:** continuous DAQ session (unchanged) + episodic ScanImage
acquisition (one externally-triggered TIFF per trial). Replaces the prior
"continuous DAQ + continuous ScanImage + frame-count alignment" design;
that design is archived at tag `archive/continuous-alignment-2026-05-23` and
documented in [docs/ARCHIVE_CONTINUOUS_ALIGNMENT.md](docs/ARCHIVE_CONTINUOUS_ALIGNMENT.md).
Motivation: with trials ≥2 s long, ScanImage's external-trigger arm latency
(~50–100 ms) is well under 5% of a trial, and in exchange every trial is
anchored to its own trigger — a single frame drop or trigger glitch is bounded
to one trial instead of corrupting everything after.

**Round 0 — Design lock [1 agent, sequential prereq]**

No code deps. Must finish before Round 1.

- [ ] T-EP-0   Lock the new architecture spec:
                  - Write `docs/SYNC_EPISODIC.md` covering trigger topology,
                    ScanImage external-trigger config, continuous-DAQ +
                    episodic-SI coupling, Trial schema additions, aligner
                    contract, cross-check rules, failure modes.
                  - Add an archival banner to `docs/SYNC_FRAME.md` pointing to
                    the new doc and to the archive tag.
                  - Lock the episodic `ScanImageBridge` API contract:
                    signatures and semantics of `armForExternalTrigger(nFrames)`,
                    `waitForCompletion()`, `getLastTiffPath()`. All Round-1
                    tasks code against this.
                Files: NEW `docs/SYNC_EPISODIC.md`;
                       MODIFY `docs/SYNC_FRAME.md` (banner only).

**Round 1 — Foundation [4 parallel agents]**

Depends on T-EP-0.

- [ ] T-EP-1a  Trial schema additions:
                  - Add `SetAccess = private` properties `siTiffPath` (char/""),
                    `alignmentDiscrepancy` (int32/NaN), `alignmentConfidence`
                    (string: "none"|"high"|"low"|"quarantine").
                  - Extend `markComplete(data, offsetSample, siTiffPath)`.
                  - New method `attachEpisodicAlignment(frameIndicesDuringStim,
                    frameIndicesBaseline, discrepancy, confidence)` with
                    `tfp:trial:Trial:badTransition` enforcement.
                  - Old `attachFrameAlignment` deprecated with a one-shot
                    warning; keep callable for back-compat.
                Files: MODIFY `src/+tfp/+trial/Trial.m`;
                       NEW `tests/test_trial_schema_episodic.m`.

- [ ] T-EP-1b  TIFF metadata reader:
                  - `tfp.io.readScanImageTiff(tiffPath)` returns struct with
                    `numFrames`, `frameRateHz`, `frameTimestamps_s`,
                    `sourceTiff`.
                  - Wrap `scanimage.util.opentif` when available; otherwise
                    fall back to `imfinfo` + parsing
                    `ImageDescription.frameTimestamps_sec`.
                  - Handle multi-channel TIFFs (frames-per-channel × nChans).
                Files: NEW `src/+tfp/+io/readScanImageTiff.m`;
                       NEW `tests/test_read_scanimage_tiff.m`
                       (+ small fixture under `tests/fixtures/`).

- [ ] T-EP-1c  MockScanImageBridge episodic mode:
                  - `armForExternalTrigger(nFrames)` records expected frame
                    count; on `softTrigger` / external-trigger callback,
                    synthesize a fake TIFF placeholder (`.mat` sidecar under
                    mock data dir, or an in-memory struct dispatchable via a
                    URI scheme — pick one, document choice in T-EP-0).
                  - `getLastTiffPath()` returns the placeholder.
                  - Test hooks: `injectFrameDrop()`, `injectSpuriousEdge()`.
                Files: MODIFY `src/+tfp/+hardware/MockScanImageBridge.m`;
                       NEW `tests/test_mock_scanimage_episodic.m`.

- [ ] T-EP-1d  Real ScanImageBridge episodic mode:
                  - Implement `armForExternalTrigger(nFrames)`: configure
                    `hSI.hScan2D.framesPerAcq`, external-trigger mode,
                    `hSI.startGrab`. Mark items needing rig verification with
                    `%VERIFY`.
                  - `waitForCompletion()`: poll `hSI.acqState` until idle,
                    with timeout.
                  - `getLastTiffPath()`: read `hSI.hScan2D.logFileStem` +
                    counter.
                  - Stub `verifyEpisodicProtocol()` analogous to existing
                    `verifyProtocol`.
                Files: MODIFY `src/+tfp/+hardware/ScanImageBridge.m`
                       (or `RealScanImageBridge.m` — coordinate with current
                       class layout).

**Round 2 — Aligner + cross-check [2 agents, sequential pair]**

T-EP-2a depends on T-EP-1b. T-EP-2b depends on T-EP-2a and T-EP-1c.

- [ ] T-EP-2a  Episodic aligner:
                  - `tfp.io.alignTrialsEpisodic(trials, tiffPaths,
                    frameStartSamples, sampleRate)`:
                      perTrial(i).frame_indices_during_stim =
                        uint64(1 : siMeta(i).numFrames) [or sub-range if
                        pre-stim baseline frames were armed].
                      Cross-check: count DI rising edges in
                        [t_onset_daq_samples, t_offset_daq_samples] via
                        `decodeFrameClock` + window mask.
                      discrepancy = siMeta.numFrames -
                        numel(diEdgesInWindow).
                      confidence = |d|<=1 → "high", <=5 → "low",
                        else "quarantine".
                  - Session-level report: numel(tiffPaths) == numel(trials);
                    aligned-frame totals; per-confidence counts.
                  - Mark `tfp.io.alignTrialsToFrames` deprecated with a
                    one-shot `tfp:io:alignTrialsToFrames:deprecated` warning
                    on first call.
                Files: NEW `src/+tfp/+io/alignTrialsEpisodic.m`;
                       MODIFY `src/+tfp/+io/alignTrialsToFrames.m` (banner +
                       warning).

- [ ] T-EP-2b  Aligner integration tests:
                  - Clean run: all trials "high" confidence.
                  - Inject 1 missing DI edge → affected trial "low".
                  - Inject 1 spurious DI edge → symmetric.
                  - Inject 5-frame DI discrepancy → "quarantine".
                  - Missing TIFF (length mismatch) → fatal report, no
                    partial alignment returned.
                Files: NEW `tests/test_align_trials_episodic.m`.

**Round 3 — Experiment refactor [3 parallel agents + 1 coordinated]**

T-EP-3a, T-EP-3b, T-EP-3c can run in parallel after Round 2; T-EP-3d
coordinates with T-EP-3c (both touch `Sequencer.runOne`) — sequence them.

- [ ] T-EP-3a  Refactor `exp_ensemble_activation` for episodic SI:
                  - Per-trial: arm SI for nFrames → fire start-acq TTL on
                    `port0/line10` via `sendDigitalPulse` → `queueClockedAO`
                    → `waitForCompletion` → record TIFF path on Trial.
                  - Continuous DAQ session unchanged.
                  - Drop the per-trial onset `sendDigitalPulse` whose
                    alignment role is now obsolete (keep the session-start
                    long pulse for operator sanity).
                  - Fix `tr.powerMw = voltageV` bug (TODO S9) while in file.
                  - Call `alignTrialsEpisodic` at session end.
                Files: MODIFY `src/+tfp/+experiments/exp_ensemble_activation.m`;
                       MODIFY `tests/test_ensemble_activation_mock.m`.

- [ ] T-EP-3b  Refactor `exp_ensemble_fill_factor_power` for episodic SI:
                  - Mirror of T-EP-3a applied to the fill-factor experiment.
                Files: MODIFY
                       `src/+tfp/+experiments/exp_ensemble_fill_factor_power.m`;
                       MODIFY `tests/test_ensemble_fill_factor_mock.m`.

- [ ] T-EP-3c  Sequencer convergence (resolves TODO C1, C3, C4, S1):
                  - `Sequencer.run` opens one continuous DAQ session via
                    `startContinuousSession` (replaces per-trial start/stop).
                  - `Sequencer.runOne`:
                      nFrames = ceil(trial.duration_s *
                        config.imaging.frameRate) + bufferFrames
                      siBridge.armForExternalTrigger(nFrames)
                      daq.sendDigitalPulse(startAcqLine, pulseS)  % C1
                      daq.queueClockedAO(stimWaveform, sr, 'immediate')
                      siBridge.waitForCompletion()
                      trial.markComplete(data, offsetSample,
                        siBridge.getLastTiffPath())
                  - Frame-clock DI consumed via continuous session
                    (TODO C4 resolved by construction).
                  - Reorder DMD softTrigger before DAQ output queueing
                    (closes TODO S1).
                  - Remove `isa(..., 'MockScanImageBridge')` check at
                    Sequencer.m:204 (TODO S3).
                Files: MODIFY `src/+tfp/+trial/Sequencer.m`.

- [ ] T-EP-3d  Wire `powerLUT` through Sequencer AO (TODO C2):
                  - In `Sequencer.runOne` (post-T-EP-3c), translate
                    `trial.powerMw` to volts via the calibration's
                    `powerLUT` before queueing AO.
                  - Throw `tfp:trial:Sequencer:powerExceedsMax` if requested
                    `powerMw > config.laser.max_mw`.
                  - Hook to `safetyChecks` (links to TODO C5; full safety
                    work is a separate stream).
                Files: MODIFY `src/+tfp/+trial/Sequencer.m`;
                       MODIFY `src/+tfp/+util/safetyChecks.m`;
                       NEW `tests/test_sequencer_power.m`.

**Round 4 — Integration tests [2 parallel agents]**

Depends on Round 3.

- [ ] T-EP-4a  Episodic end-to-end mock test:
                  - Rename / refactor `tests/test_sync_endtoend_mock.m` →
                    `tests/test_episodic_endtoend_mock.m`.
                  - Exercises configure-mocks → 5-trial session → assert all
                    trials "high" confidence → TIFF paths recorded → DAQ
                    sample anchors monotonically increasing.
                Files: RENAME `tests/test_sync_endtoend_mock.m`
                       → `tests/test_episodic_endtoend_mock.m` (rewrite body).

- [ ] T-EP-4b  Frame-drop / glitch resilience integration test:
                  - Companion test injecting DI drops, spurious edges, and a
                    missing TIFF; asserts per-trial confidence flags and
                    session-level fatal report.
                Files: NEW `tests/test_episodic_resilience_mock.m`.

**Round 5 — Docs + probes + rig verification [3 parallel agents + 1 manual]**

Depends on Rounds 3–4.

- [ ] T-EP-5a  Rewrite `docs/SYNC_FRAME.md` (finalize the archival banner
                from T-EP-0 — replace bulk content with a 1-paragraph
                pointer to `SYNC_EPISODIC.md` and the archive tag). Ensure
                `SYNC_EPISODIC.md` links to landed source files.
                Files: MODIFY `docs/SYNC_FRAME.md`, `docs/SYNC_EPISODIC.md`.

- [ ] T-EP-5b  Update CLAUDE.md timing section:
                  - Brief rewrite of "Trigger topology" subsection to reflect
                    episodic SI acquisition and the continuous DAQ session.
                Files: MODIFY `CLAUDE.md`.

- [ ] T-EP-5c  ScanImage external-trigger probe script:
                  - `scripts/probe_scanimage_external_trigger.m` (runs on
                    imaging PC).
                  - Dumps the `hSI` properties needed to configure
                    external-trigger mode; measures arm-ready latency
                    (timer around `armForExternalTrigger` → first-frame
                    edge); writes a markdown report under `data/probes/`.
                Files: NEW `scripts/probe_scanimage_external_trigger.m`.

- [MANUAL] T-EP-5d  Rig verification (operator at scope PC, not for agents):
                  - Run T-EP-5c probe → confirm external-trigger config and
                    measure arm latency.
                  - Run end-to-end mock-disabled session → confirm TIFF
                    naming/path retrieval is stable; all trials land "high"
                    confidence.
                Files: rig-side checklist; logged to `docs/hardware_log.md`.

---

**Parallelism summary (episodic switch):**
  Round 0: 1 agent (sequential prereq)
  Round 1: 4 parallel agents (T-EP-1a/1b/1c/1d)
  Round 2: 1 agent on T-EP-2a; then T-EP-2b
  Round 3: 3 parallel agents (T-EP-3a/3b/3c); T-EP-3d after T-EP-3c
  Round 4: 2 parallel agents (T-EP-4a/4b)
  Round 5: 3 parallel agents (T-EP-5a/5b/5c); T-EP-5d manual at rig

**File-conflict map (episodic switch):**
  Trial.m              — T-EP-1a only
  readScanImageTiff.m  — T-EP-1b (new) + T-EP-2a (consumer)
  MockScanImageBridge.m — T-EP-1c only
  ScanImageBridge.m    — T-EP-1d only
  alignTrialsEpisodic.m — T-EP-2a (new) + T-EP-2b (consumer)
  alignTrialsToFrames.m — T-EP-2a only (banner + warning)
  exp_ensemble_activation.m         — T-EP-3a only
  exp_ensemble_fill_factor_power.m  — T-EP-3b only
  Sequencer.m          — T-EP-3c then T-EP-3d (sequence)
  test_episodic_endtoend_mock.m     — T-EP-4a only
  test_episodic_resilience_mock.m   — T-EP-4b only
  docs/SYNC_EPISODIC.md             — T-EP-0 (draft) then T-EP-5a (finalize)
  docs/SYNC_FRAME.md   — T-EP-0 (banner) then T-EP-5a (final state)
  CLAUDE.md            — T-EP-5b only
  probe_scanimage_external_trigger.m — T-EP-5c only

---

## TASK-BU: Bring-up optical path — align the control code with the real optics

**Tracking prefix:** `T-BU-`.
**Source of truth:** [docs/dmd_control_handoff.md](docs/dmd_control_handoff.md),
generated from the `TF optics simulator` repo for build
`33010FL01-530R 6.0mm 80/300 150/80`. Regenerate that doc rather than editing it.

**What this task family is for.** The bring-up arm is now specified:
CARBIDE 1030 nm → DMD → 4f (80/300) → 1200 g/mm grating → 4f (150/80) →
existing periscope / PBS / Olympus 180 mm tube / Nikon CFI75 LWD 16×/0.8 W.
No PLM, no πShaper. An audit of the repo against that spec (2026-07-26) found
the control code still encodes the *pre-optics guesses*: an isotropic
0.270 µm/px sample scale, no knowledge of the chip's 45° clocking, no
enforcement of the illuminated patch, and a laser interlock that cannot see
the pattern at all. These tasks close those gaps.

**Three facts drive almost every task below:**
1. **The chip is clocked 45°.** The optical axes are the chip *diagonals*, not
   its rows and columns. Every sample↔DMD transform carries that rotation.
2. **The sample scale is anisotropic and ~4× larger than configured.**
   1.1250 µm/px along the grooves, 1.4162 µm/px along the dispersion axis
   (ratio 1.2588). `configs/real.yaml` currently says 0.270 µm/px, isotropic.
3. **Pattern fill fraction is a laser-safety parameter.** Each 4f relay forms a
   real focus in air at its pupil; a uniform ON patch puts the whole pulse into
   one ~27 µm spot there.

**Corollary — a soma is now ~80 DMD pixels, not ~900** (Hillel, 2026-07-26).
This falls straight out of fact 2 and is worth stating separately because it
invalidates a default that appears in a dozen files. A round spot of radius
`R` µm at the sample needs an ellipse on the DMD with semi-axes
`R/1.1250` px (groove) and `R/1.4162` px (dispersion), so its area is
`π·R²/1.5932` pixels:

| Sample spot diameter | DMD semi-axes (px) | DMD pixels |
|---|---|---|
| 10 µm | 4.4 × 3.5 | ~49 |
| **12.7 µm (soma-sized)** | **5.7 × 4.5** | **~80** |
| 15 µm | 6.7 × 5.3 | ~111 |

Two consequences, one good and one bad:
  - **Good:** `fillFactorEnsemble` gets **~80 discrete power levels per neuron**
    (1.25% steps), set by how many of the ~80 pixels in that neuron's patch are
    ON. That is ample, but it is >10× coarser than the ~900 levels the pilot
    assumed, and the code should say so rather than let a caller silently
    request 500 levels. See T-BU-1e.
  - **There is a hard rasterization floor at soma scale** (measured 2026-07-26
    against the completed T-BU-1a + T-BU-1b, sweeping groove semi-axis and
    mapping the ON pixels back to the sample plane):

    | groove semi-axis (px) | ON px | sample aspect, anisotropic | isotropic |
    |---|---|---|---|
    | 2.8   | 21     | **1.2588** | 1.2588 |
    | 5.644 (soma) | 81 | 1.079 | 1.2588 |
    | 11.3  | 319    | 1.007 | 1.2588 |
    | 28    | 1969   | 1.0006 | 1.2588 |
    | 113   | 31849  | 0.998 | 1.2588 |

    The anisotropic correction is exact in the continuum — the residual converges
    to 1.000 — but on the pixel lattice it cannot be fully expressed at small
    radii. At soma scale ~8% aspect error remains, and **below ~4 px semi-axis
    the ellipse rasterizes to the same pixel set as the circle, so the
    correction buys nothing at all.** This is physics, not a defect: you cannot
    make a perfectly round 12.7 µm spot out of ~80 mirrors. Relevant to T-BU-3e
    (`measurePSF` deliberately wants a near-minimal spot and is at the floor)
    and worth stating in any figure caption that claims round targets.

  - **Bad:** every spot-radius default in the repo is **3–4× too large**. They
    were chosen against the old 0.270 µm/px guess. `radiusPx = 15`, drawn as an
    isotropic pixel circle, is a **34 × 42 µm ellipse** at the sample — not a
    ~12 µm round spot. Left unfixed this destroys single-cell resolution, which
    is the central claim of the hero figure. The defaults are spread across
    experiment and calibration files; each owning task fixes its own
    (T-BU-1e, 2b, 2c, 3b, 3e).

**%CORRECTION to the generated handoff doc (confirmed with Hillel 2026-07-26):**
§7 states the CARBIDE delivers 800 µJ at 100 kHz and quotes "80 W available".
**The laser is 40 W, not 80 W** — the 80 W figure is an error in the generator
and should be fixed upstream in the `TF optics simulator` repo. Consequences:
  - Max pulse energy at 100 kHz is **400 µJ**, not 800 µJ.
  - The **~68 µJ interlock threshold is UNCHANGED** — it is an air-ionization
    limit at the pupil, a property of the optics and the 230 fs pulse, not a
    laser spec. Full-field ON still exceeds it by ~5.9× (rather than ~12×).
  - The routine-operation headroom quote becomes ~2.83 W of laser output out of
    40 W available (~7%), not 10.8% of 80 W.
Any task that hardcodes a laser number takes it from `configs/real.yaml`, never
from §7 of the handoff doc.

---

### Round 0 — Constants and single source of truth [1 agent, sequential prereq]

- [x] T-BU-0  Optical constants config block + `opticalModel` accessor. **[DONE
              2026-07-26]** — `configs/real.yaml` dmd + laser blocks rewritten,
              `tfp.util.opticalModel` added as the single source of truth,
              23 new tests green (332 → 355 baseline).
              Everything downstream reads its constants from here; no other
              task may hardcode 1.1250, 1.4162, 45, 278, or 68.
                - `configs/real.yaml`: rewrite the `dmd` block for the bring-up
                  path. New keys (all `%VERIFY` — they are design intent, not
                  calibration):
                    `clockingDeg: 45`
                    `umPerPixelGroove: 1.1250`
                    `umPerPixelDispersion: 1.4162`
                    `anisotropy: 1.2588`
                    `patchCenterPx: [640, 400]`   # illumination centroid, NOT
                                                  # necessarily the chip centre
                    `patchRadiusPx: 278`          # design Ø6.0 mm
                    `patchMaxRadiusPx: 329`       # hard clip limit, Ø7.12 mm
                    `gaussianWaistPx: 555.6`      # I(r)=exp(-2r²/w²)
                    `depthGradientUmPerUm: 0.02174`
                    `fieldExtentUm: [625, 787]`
                  Retain the scalar `umPerPixel` ONLY as a deprecated key with
                  a comment pointing at the two axis-specific values; T-BU-2b
                  removes its last consumer.
                - `configs/real.yaml` `laser` block: add
                  `rep_rate_hz: 100000`, `max_power_w: 40`,
                  `max_pulse_energy_uj_pupil: 68`,
                  `pupil_interlock_fill_fraction: 0.2` (fill above which the
                  pupil check applies), all `%VERIFY` on CARBIDE arrival.
                - NEW `src/+tfp/+util/opticalModel.m`: reads a config struct and
                  returns a validated constants struct, applying documented
                  defaults via `configField`. This is the ONLY place the design
                  numbers appear in code.
                - NEW `tests/test_opticalModel.m`: defaults, validation errors,
                  and a consistency check that
                  `umPerPixelDispersion/umPerPixelGroove ≈ anisotropy`.
              Files: MODIFY `configs/real.yaml`;
                     NEW `src/+tfp/+util/opticalModel.m`,
                     NEW `tests/test_opticalModel.m`.

---

### Round 1 — Independent primitives [4 parallel agents]

All four are new-file-dominant and share no files. Each depends only on T-BU-0.

- [x] T-BU-1a  Anisotropic sample↔DMD coordinate mapping. **[DONE 2026-07-26]**
                22 tests green. Sample column order is [dispersion groove];
                DMD offsets are [dCol dRow] to match `multiSpot`/`singleSpot`.
                A supplied matrix is always interpreted DMD→sample, and
                supersedes `dispersionAxisSign` (a fit already carries its signs).
                **Units trap found during implementation — see T-BU-2b(ii):**
                the functions deliberately do NOT auto-read
                `calibration.dmdToSample_affine`, because in this repo that field
                maps DMD px → substage CAMERA px, not µm. Wiring it in directly
                would reintroduce exactly the units bug T-BU-2b exists to remove.
                Callers must pass an explicit µm-valued map. Any later task that
                wants to feed calibration output straight in needs a µm-valued
                fit first.
                The replacement for the scalar `pixelsPerUm`. Builds the
                forward and inverse linear maps from §5 of the handoff:
                  `d_disp = (dc + dr)/sqrt(2)`, `d_groove = (dc - dr)/sqrt(2)`
                  `x_disp = d_disp * 1.4162`, `y_groove = d_groove * 1.1250`
                Must accept EITHER the design constants (from `opticalModel`)
                OR the linear part of a fitted affine, so the same call site
                works pre- and post-calibration. Sign conventions are NOT
                specified by the optics doc — expose `dispersionAxisSign` and
                resolve it on the bench; default +1 with a `%VERIFY`.
              Files: NEW `src/+tfp/+patterns/sampleToDmdOffset.m`,
                     NEW `src/+tfp/+patterns/dmdToSampleOffset.m`,
                     NEW `tests/test_sampleDmdMapping.m`.

- [x] T-BU-1b  Anisotropic spot shapes. **[DONE 2026-07-26]** 14/14 green
                (6 pre-existing untouched + 8 new). Opt-in via a trailing
                `options` struct (`.anisotropic`, `.model`, `.config`); the
                default path returns early through the verbatim original
                expression, so it is bit-identical.
                **Direction (derived, then mutation-tested):** the SHORT
                semi-axis is on the (1,1) dispersion diagonal, the LONG one on
                (1,-1) groove. A pixel step along dispersion buys more sample µm
                (1.4162 vs 1.1250), so fewer pixels span the same distance.
                **INTEGRATION CONTRACT — T-BU-2b/2c/3e must honour this:** in
                anisotropic mode `radiusPx` means the **groove-axis (long)
                semi-axis**, so the sample spot is a disc of radius
                `radiusPx * umPerPixelGroove` µm. If a caller hands it the
                DISPERSION semi-axis from `somaSpotGeometry` (T-BU-1e) instead,
                every spot comes out 1.2588× too small with no error. Cross-check
                the two APIs before wiring.
                Also added: a degenerate-radius guard (anisotropic mode only) that
                forces the rounded target pixel ON when the coarsely-rasterized
                ellipse contains no lattice point — at ~5 px semi-axes a
                sub-pixel offset could otherwise rasterize to an all-OFF pattern,
                i.e. a silently skipped stimulus.
                `dispersionAxisSign` is read but the mask is provably invariant
                to it (the ellipse is centrosymmetric, the sign enters only
                squared); a test pins that so an orientation change cannot later
                be smuggled in through the sign. This matches T-BU-1a's
                convention, where the sign flips DIRECTION along the always-(1,1)
                dispersion diagonal rather than selecting which diagonal is
                dispersion.
                Caveat: `multiSpot` carries verbatim copies of three local
                helpers (MATLAB cannot share locals across files and the task
                owned only these two sources). A union test
                (`anisotropic_multiSpot_matches_singleSpot_union`) is the
                anti-drift lock — keep it if these are ever refactored.
                A circle drawn in DMD pixels lands as a 1.26× ellipse at the
                sample. Add an optional anisotropy mode to `singleSpot` and
                `multiSpot` that draws an ellipse compressed by 1.2588 along
                the `(1,1)` diagonal, so the SAMPLE spot is round. Default
                behaviour (isotropic pixel circle) must be unchanged so the
                existing tests stay green; the new mode is opt-in via an
                options struct.
              Files: MODIFY `src/+tfp/+patterns/singleSpot.m`,
                     MODIFY `src/+tfp/+patterns/multiSpot.m`,
                     MODIFY `tests/test_patterns.m` (add cases only).

- [x] T-BU-1c  Patch-containment guard (pure function, no wiring).
                **[DONE 2026-07-26]** 27 tests green.
                API for T-BU-2a to wire:
                  `info = tfp.util.assertPatternInPatch(patterns, config, options)`
                accepting logical H×W or H×W×N (numeric = nonzero means ON), any
                config `opticalModel` accepts, and `options.context` for a caller
                tag such as `[DLP650LNIR_DMD.loadPatternSequence]`.
                Decisions pinned by tests: boundary is inclusive
                (`r <= patchRadiusPx` passes, matching `singleSpot`'s inclusive
                radius — otherwise a spot generated at the patch edge would
                self-reject); the hard-limit error outranks the soft one when
                both are breached; `info` is returned only on success, since an
                MException carries no custom payload, so failing-case diagnostics
                live in the message text.
                Cost is ~1.5 ms per full-chip pattern, so it is cheap enough to
                sit on every load. It avoids a meshgrid via separable row/column
                squared-radius lookups plus an independent-max bounding-box
                upper bound per slice; exact enumeration runs only for slices
                that fail the bound. The bound can only over-estimate, so it
                never wrongly accepts — and a random-stack brute-force
                cross-check against a meshgrid is in the tests.
                §4: "Write nothing outside the patch — mirrors outside it must
                be OFF." Nothing in the repo enforces this today;
                `roiHalfWidthPx` is used only to lay out calibration grids.
                Signature mirrors `assertLaserPowerSafe`: given a logical
                pattern (or H×W×N stack) and the patch geometry, throw if any
                ON pixel lies outside `patchRadiusPx` of `patchCenterPx`.
                Error must name the offending pattern index and the worst-case
                radius, and say what to do (re-pick a more central target).
                Separate, harder error above `patchMaxRadiusPx` — beyond that
                the beam clips lens La and the grating ruling.
              Files: NEW `src/+tfp/+util/assertPatternInPatch.m`,
                     NEW `tests/test_assertPatternInPatch.m`.

- [x] T-BU-1d  Pupil pulse-energy interlock (pure function, no wiring).
                **[DONE 2026-07-26]** 42 tests green.
                `info = tfp.util.assertPulseEnergySafe(patternOrFill, voltageV, cfg)`
                — pure, no state, and deliberately **no override form** (the
                `powerMeterSweep` low-rep-rate exception is safe for average
                power and makes THIS hazard worse, so it must not bypass here).
                **Safety hole found and closed — the governing fill is
                PATCH-relative, not chip-relative.** The literal reading (mean
                over the whole pattern) is wrong on this chip: the design patch
                is only ~24% of a 1280×800 array, so an all-ON *patch* scores
                just 0.237 chip-wide and would scrape past a 0.2 gate, while a
                half-ON patch would be exempt outright despite being 50% of the
                illuminated area — which is the physically dangerous quantity.
                The function computes both and takes the LARGER, falling back to
                array-fill when the patch disc does not land on the supplied
                array (also the conservative direction).
                Does NOT discount energy by fill² above the gate — the 68 µJ
                figure is quoted for the near-uniform case, so applying it
                undiscounted is the conservative reading. fill² is reported as a
                diagnostic only, with an explicit "do not 'improve' this by
                scaling the limit with 1/fill²" warning.
                **For T-BU-2a:** the headless opt-in key is
                `autoConfirmPulseEnergy`, deliberately SEPARATE from
                `autoConfirmPower` and defaulting false even in mock configs, so
                the mock rig's `autoConfirmPower: true` cannot accidentally opt
                past the pupil confirmation band. Keep them separate.
                A NEW class of check the existing ao3 guard cannot express.
                Given (pattern fill fraction, commanded ao3 voltage, config),
                compute pulse energy = P/f and block when a high-fill pattern
                is paired with pulse energy above
                `max_pulse_energy_uj_pupil`. Pupil peak scales with the SQUARE
                of the pattern mean, so the check is written in terms of fill
                fraction, and sparse patterns must pass easily.
                **Document the rep-rate inversion prominently in the header.**
                `assertLaserPowerSafe` justifies its voltage-only model with
                "lower rep rate → less real power, so this never
                under-estimates." That is true for average power and BACKWARDS
                here: at fixed average power, lowering the rep rate RAISES
                pulse energy. The two guards are conservative in opposite
                directions and both must run.
              Files: NEW `src/+tfp/+util/assertPulseEnergySafe.m`,
                     NEW `tests/test_assertPulseEnergySafe.m`.

- [x] T-BU-1e  Soma-sized spot geometry + per-neuron power quantization.
                **[DONE 2026-07-26]** 25 new tests + 4 added blocks, green.
                `geom = tfp.patterns.somaSpotGeometry(diameterUm, config)`, taking
                a SAMPLE-plane diameter (default 12.7 µm). Confirms the corollary
                by rasterization: 10 µm → 47 px, 12.7 µm → **81 px**, 15 µm → 111
                px (analytic 49.3 / 79.5 / 110.9), giving **81 power levels at
                1.23% steps**.
                Three hand-off routes for downstream callers, and they are NOT
                interchangeable — see T-BU-1f:
                  `.spotOptions`   → pass to singleSpot/multiSpot (preferred)
                  `.offsetsPx` / `.localMask` → stamp directly at a centroid
                  `.radiusPx`      → AREA-MATCHED isotropic fallback for
                                     circle-only call sites. It preserves the
                                     pixel budget (so power levels and delivered
                                     energy stay right) while the sample spot is
                                     1.2588× elongated; `.isotropicExtentUm`
                                     reports that distortion so a caller can
                                     quote it honestly.
                `fillFactorEnsemble` docstring table rewritten against sample
                diameters (legacy `radiusPx = 14` is a 31.5 × 39.7 µm ellipse,
                2.8× a soma); `info` gains `.nPowerLevels` / `.powerStepPct`, and
                a new `options.requestedFillLevels` warns via
                `:fillQuantization` when a requested ladder is finer than the
                coarsest neuron patch can resolve. Nested-subset permutation
                behaviour untouched.

- [x] T-BU-1f  **Round-1 reconciliation — API mismatch found and fixed
                (2026-07-26).** Not originally planned; added after an
                integration cross-check of the completed T-BU-1b and T-BU-1e.
                The two were built to DIFFERENT contracts and the *intended*
                hand-off was the broken path: `somaSpotGeometry.spotOptions`
                carries `.semiAxisGroovePx`, but `singleSpot`/`multiSpot` only
                understood `.anisotropic` / `.model` / `.config` and took the
                geometry from the positional `radiusPx`. Unknown option fields
                were not rejected, so the documented call
                `singleSpot(dmd, ctr, geom.radiusPx, geom.spotOptions)`
                silently painted **67 pixels instead of 81** — a 17% pixel
                deficit, i.e. 17% less delivered power and 67 rather than 81
                power levels, with no error anywhere.
                Fix: `resolveSpotOptions` in both files now returns an explicit
                `semiAxisGroovePx` which OVERRIDES the positional radius in
                anisotropic mode, validated with a new `:badSemiAxis` error.
                Verified: the hand-off now yields 81 px, matching
                `somaSpotGeometry.nPixels`, and `.offsetsPx` stamps to a
                bit-identical mask.
                **Lesson for Round 2+:** two agents can each pass their own
                tests and still not compose. Cross-check every new API pairing
                at the seam before wiring it.
              Files: MODIFY `src/+tfp/+patterns/singleSpot.m`,
                     MODIFY `src/+tfp/+patterns/multiSpot.m`.
                See the "~80 DMD pixels per soma" corollary above.
                - NEW `somaSpotGeometry.m`: given a desired sample-plane spot
                  DIAMETER in µm, return the DMD semi-axes (groove,
                  dispersion), the expected in-patch pixel count, and hence the
                  number of achievable power levels. This is the function every
                  caller should use instead of picking a `radiusPx` by hand.
                - MODIFY `fillFactorEnsemble.m`: its docstring table
                  ("radiusPx = 17 → ~925 pixels, closest to the 900-px pilot
                  target") is correct as pixel geometry but wrong as biology —
                  radius 17 is a ~38 × 48 µm sample spot. Rewrite the table
                  against sample-plane diameters, and have `info` report
                  `nPowerLevels` (= `nPatchPixels`) plus a warning when the
                  requested fill fractions are spaced finer than `1/nPatchPixels`
                  and therefore quantize to the same pattern.
                - Note for the implementer: at ~80 px the disk is coarsely
                  rasterized, so prefer selecting an EXACT pixel count over
                  relying on the rounded disk area, and keep the existing
                  nested-subset permutation behaviour (it matters more now that
                  low fill fractions are only a few pixels).
              Files: NEW `src/+tfp/+patterns/somaSpotGeometry.m`,
                     MODIFY `src/+tfp/+patterns/fillFactorEnsemble.m`,
                     NEW `tests/test_somaSpotGeometry.m`,
                     MODIFY `tests/test_ensemble_fill_factor_mock.m` (add cases only).

---

### Round 2 — Wiring [3 parallel agents]

- [ ] T-BU-2a  Wire both guards into the DMD load choke point.
                Depends on T-BU-1c + T-BU-1d. `loadPatternSequence` is the one
                path every pattern crosses — same argument that put the laser
                check inside the DAQ rather than in each experiment. Add a
                protected validation hook on the `DMD` base class, call it from
                both backends, and configure it from `makeHardware`. Must cover
                `scripts/alpCheckerboard.m`-style all-ON alignment frames,
                which are precisely the dangerous case.
              Files: MODIFY `src/+tfp/+hardware/DMD.m`,
                     MODIFY `src/+tfp/+hardware/MockDMD.m`,
                     MODIFY `src/+tfp/+hardware/DLP650LNIR_DMD.m`,
                     MODIFY `src/+tfp/+util/makeHardware.m`,
                     MODIFY `tests/test_MockDMD.m` (add cases only).

- [ ] T-BU-2b  Retire the scalar `pixelsPerUm`; fix the field-name collision.
                Depends on T-BU-1a. Two separate defects:
                (i) `ppsfPattern` converts µm offsets with a single scalar
                applied to both row/column axes — wrong magnitude, wrong
                anisotropy, wrong axes. This directly corrupts the distance
                axis of the lateral-PPSF hero figure. Route it through
                `sampleToDmdOffset` instead.
                (ii) `calibration.pixelsPerUm` means CAMERA px per µm when it
                comes from `alignDMDtoCamera` (1/1.56) but is read as DMD px
                per µm by `ppsfPattern` — a ~5.8× error waiting for Phase 3 to
                wire `calibration_file` loading (which currently throws
                `notImplemented`). Rename the SCALAR to `cameraPixelsPerUm` /
                `dmdPixelsPerUm` so the two can never be confused. This part is
                in scope now and does not depend on the deferred decision below.
                **Instead of resolving the affine question, DEFEND against it**
                (see T-BU-2e): any call site that needs a µm-valued map must
                fail loudly when handed a camera-valued one, rather than
                silently scaling every target by ~5.8×.
                Also update `validatePPSFTarget`: replace the hardcoded 80 px
                from the GEOMETRIC centre with "target plus the largest
                requested sweep offset stays inside the calibrated patch",
                measured from `patchCenterPx`.
                (iii) Fix the `radiusPx = 15` defaults in the four experiment
                files owned here (~34 × 42 µm spots) and the `spotRadius = 8`
                default in `alignDMDtoCamera`, using `somaSpotGeometry` from
                T-BU-1e. Calibration spots need not be soma-sized, but they do
                need a stated sample-plane size rather than a stale pixel count.
              Files: MODIFY `src/+tfp/+patterns/ppsfPattern.m`,
                     MODIFY `src/+tfp/+util/validatePPSFTarget.m`,
                     MODIFY `src/+tfp/+calibration/alignDMDtoCamera.m`,
                     MODIFY `src/+tfp/+calibration/alignDMDtoCamera_mock.m`,
                     MODIFY `src/+tfp/+experiments/exp_ppsf_lateral.m`,
                     MODIFY `src/+tfp/+experiments/exp_ppsf_2d.m`,
                     MODIFY `src/+tfp/+experiments/exp_rapid_sequential.m`,
                     MODIFY `src/+tfp/+experiments/exp_axial_ppsf.m`.

- [ ] T-BU-2c  Spot-radius defaults in the remaining experiment scripts.
                Depends on T-BU-1e. Same defect as T-BU-2b(iii) in the files
                T-BU-2b does not own: `radiusPx = 15` in `exp_power_curve` and
                `exp_power_curve_3dshot`, `spotRadiusPx = 14` in
                `exp_ensemble_activation` and `exp_ensemble_fill_factor_power`
                (whose docstring also claims "~28 px ≈ cell-sized"). Replace
                with a sample-plane diameter routed through `somaSpotGeometry`.
                Note `exp_power_curve_3dshot` is the SLM arm — it does not go
                through the DMD/grating path, so its spot sizing is governed by
                the CGH model, not by §5. Fix the comment, and confirm before
                changing the number.
              Files: MODIFY `src/+tfp/+experiments/exp_power_curve.m`,
                     MODIFY `src/+tfp/+experiments/exp_power_curve_3dshot.m`,
                     MODIFY `src/+tfp/+experiments/exp_ensemble_activation.m`,
                     MODIFY `src/+tfp/+experiments/exp_ensemble_fill_factor_power.m`.

---

- [ ] T-BU-2e  Units guard on the DMD→sample map (defensive; replaces the
                deferred schema decision).
                Depends on T-BU-1a. Small but load-bearing.
                `calibration.dmdToSample_affine` is misleadingly named: it maps
                DMD px → substage CAMERA px, not µm. `sampleToDmdOffset` /
                `dmdToSampleOffset` already refuse to consume it implicitly
                (T-BU-1a), which is correct but passive — a future caller can
                still pass it in explicitly and get every target scaled by
                ~5.8× with no complaint.
                Add an explicit units tag to the map a caller supplies, and
                throw `tfp:patterns:sampleToDmdOffset:wrongUnits` when a
                camera-valued map reaches a µm-valued call site. A cheap
                plausibility check is a good backstop even without a tag: on
                this rig a genuine µm-valued DMD→sample linear part has
                singular values near 1.125 / 1.416, whereas a camera-valued one
                is near 0.72 / 0.91 (µm/px over the 1.56 µm camera pixel), so
                anything off by more than ~2× from the optical model is almost
                certainly the wrong map. Warn loudly, name both hypotheses.
              Files: MODIFY `src/+tfp/+patterns/sampleToDmdOffset.m`,
                     MODIFY `src/+tfp/+patterns/dmdToSampleOffset.m`,
                     MODIFY `tests/test_sampleDmdMapping.m` (add cases only).

---

### Round 3 — Calibration and reporting [5 parallel agents]

- [ ] T-BU-3a  Affine sanity check + periscope-reversal diagnostic.
                §9 asks the control code to fit its own affine and use §5 only
                as an expected starting point. The fit is already 6-DOF
                (`fitgeotrans(...,'affine')`), so it absorbs the 45° rotation
                and the anisotropy for free — what's missing is the check.
                Take an SVD of the fitted linear part: the two singular values
                are the principal scales, their ratio should be 1.2588, and the
                rotation should be ≈45°. Convert to camera px (divide by
                `camera.umPerPixel`) before comparing.
                Make it a DIAGNOSTIC, not just a warning: the periscope's
                unconfirmed lens order is a clean **1.778×** hypothesis, so if
                the fitted scale is off by that factor the routine should say
                "the periscope is installed reversed relative to the handoff
                doc" rather than "calibration looks wrong."
              Files: MODIFY `src/+tfp/+calibration/private/fitAffineCalib.m`,
                     NEW `tests/test_affineScaleCheck.m`.

- [ ] T-BU-3b  Focal-plane-tilt defaults and expectation check.
                The routine already exists and has the right shape; it just
                carries stale constants. Replace the `umPerPixel` default of
                0.270 with the `opticalModel` values, and compare the measured
                tilt against the design expectation: 1.245° entirely along the
                DISPERSION axis, 0.03079 µm per pixel along the `(1,1)`
                diagonal, 17.1 µm across the patch. A measured groove-axis
                component is a red flag (the design has none) — surface it.
              Files: MODIFY `src/+tfp/+calibration/measureFocalPlaneTilt.m`,
                     MODIFY `src/+tfp/+calibration/measureFocalPlaneTilt_mock.m`,
                     MODIFY `tests/test_focalPlaneTilt_mock.m` (add cases only).

- [ ] T-BU-3c  Per-target depth offset helper (pure function, no wiring).
                17.1 µm of depth walk across the patch against a 17.7 µm axial
                FWHM means two targets at opposite field edges are NOT in the
                same plane. The handoff says to surface this rather than hide
                it. Compute `z_um ≈ x_disp * 0.02174` per target and flag when
                a multi-target ensemble spans more than one axial FWHM.
                Helper + tests ONLY — Sequencer wiring is T-BU-4b, because
                `Sequencer.m` is owned by the in-progress TASK-EP work.
              Files: NEW `src/+tfp/+util/targetDepthOffset.m`,
                     NEW `tests/test_targetDepthOffset.m`.

- [ ] T-BU-3d  Gaussian-uniformity dwell correction.
                §8: no πShaper, so the patch sits inside a Gaussian —
                `I(r)/I0 = exp(-2r²/555.6²)`, falling to 0.61 at the patch
                edge, needing a 1.65× dwell correction there. The flat-field
                map already comes out of `measureIlluminationUniformity` but
                nothing consumes it. Convert a per-target relative intensity
                into a per-target dwell in 80 µs binary frames.
                **Correct in time, not in fill fraction** — and note WHY in the
                header, because we already own a fill-fraction knob
                (`fillFactorEnsemble`) and reusing it here would be wrong:
                raising an edge target's fill to compensate for dimming raises
                the pupil peak quadratically (see T-BU-1d), whereas raising its
                dwell leaves the peak untouched.
              Files: NEW `src/+tfp/+patterns/dwellCorrection.m`,
                     NEW `tests/test_dwellCorrection.m`.

- [ ] T-BU-3e  Spot-radius defaults in the calibration routines.
                Depends on T-BU-1e. `spotRadius = 15` in
                `measureIlluminationUniformity` (whose comment says
                "≈ cell-sized" — it is ~34 × 42 µm), `spotRadiusPx = 5` in
                `verifyScanFieldComposition`, `spotRadiusPx = 3` in
                `measurePSF`, `spotRadius = 8` in `calibrationGUI`.
                These do not all need to be soma-sized — `measurePSF`
                deliberately wants a near-minimal spot — but every one should
                state its intended SAMPLE-plane size and derive the pixel
                geometry, so the next optics change updates them automatically.
                `measurePSF` in particular should note that its minimum useful
                spot is now a few pixels across, near the rasterization floor.
              Files: MODIFY `src/+tfp/+calibration/measureIlluminationUniformity.m`,
                     MODIFY `src/+tfp/+calibration/verifyScanFieldComposition.m`,
                     MODIFY `src/+tfp/+calibration/measurePSF.m`,
                     MODIFY `src/+tfp/+calibration/calibrationGUI.m`.

---

### Round 4 — Integration and docs [serialized]

- [ ] T-BU-4a  CLAUDE.md sync. Single-file task, serialized because every
                agent reads it. Stale for the bring-up path: the objective is a
                Nikon CFI75 LWD 16×/0.8 W (not the Olympus 20×/1.0), the
                addressable field is a 625×787 µm ellipse (not 3×3 mm), the
                pixel scale is the anisotropic pair (not ~40× demag /
                0.270 µm/px), and the laser-safety section needs the pupil
                interlock and the rep-rate inversion added alongside the
                existing ao3 policy.
              Files: MODIFY `CLAUDE.md`.

- [ ] T-BU-4b  Sequencer wiring for depth reporting and dwell correction.
                Depends on T-BU-3c + T-BU-3d **and on TASK-EP landing** —
                `Sequencer.m` is owned by T-EP-3c/3d until then. Attach the
                per-target z estimate to trial metadata and apply the dwell
                correction when a uniformity map is present in the config.
              Files: MODIFY `src/+tfp/+trial/Sequencer.m`.

- [ ] T-BU-4c  `slm.NA_eff` follow-up. `configs/real.yaml` carries
                `NA_eff: 0.6` for the 3D-SHOT arm, which no longer matches an
                0.8 NA objective. Small, but it feeds the CGH model.
                Sequenced AFTER T-BU-0 to avoid two agents editing
                `configs/real.yaml`.
              Files: MODIFY `configs/real.yaml`.

---

### MANUAL — operator at the rig, not for agents

- [DEFERRED] T-BU-M0  **Decide what `dmdToSample_affine` should be** — raise
                this at the FIRST CALIBRATION RUN, not before (Hillel,
                2026-07-26: "hold that question for when I actually get to
                running the calibration"). The field maps DMD px → substage
                CAMERA px despite its name. Two options: rename it
                `dmdToCam_affine` (which is already what `composeCalibration`
                calls it downstream), or compose it with `camera.umPerPixel` to
                produce a genuinely µm-valued fit. It is a saved-calibration
                schema question, so it wants real calibration data in hand
                rather than a guess.
                Until then T-BU-2e guards the hazard defensively, so nothing is
                blocked. Whoever runs the first calibration: read T-BU-2e first,
                then decide.

- [MANUAL] T-BU-M1  Resolve the periscope lens order. §9 flags this as the
                largest single risk in the numbers: the 200/150 pair's order is
                unconfirmed, and reversing it changes every µm/px figure by
                1.778×. T-BU-3a will diagnose it from a calibration grid;
                confirming it optically is faster.
- [MANUAL] T-BU-M2  Re-confirm the Olympus 180 mm tube lens focal length.
- [MANUAL] T-BU-M3  Measure the illumination centroid on the chip and write it
                into `dmd.patchCenterPx`. The patch centre is where the
                Gaussian actually lands, which is not necessarily the chip
                centre; both the containment guard and the dwell correction key
                off it.
- [MANUAL] T-BU-M4  Determine the two unresolved signs on the bench:
                which chip diagonal is `+disp`, and which way depth runs.
                Two-point calibration, per §5.
- [MANUAL] T-BU-M5  `%VERIFY` the CARBIDE power-control interface on arrival
                (~early Sept 2026): analog ao3 as assumed, or the Light
                Conversion software/TCP API. If the latter, both the existing
                ao3 guard and the new pupil interlock move into a
                `tfp.hardware.Laser` driver.
- [MANUAL] T-BU-M6  Fix the 80 W → 40 W error upstream in the
                `TF optics simulator` repo and regenerate
                `docs/dmd_control_handoff.md`. Cannot be done from this repo.

---

**STATUS 2026-07-26:** Round 0 and Round 1 complete (T-BU-0, 1a–1e, plus the
unplanned reconciliation T-BU-1f). Full suite **479/479 green**, up from a
332 baseline. Round 2 is unblocked.
The `dmdToSample_affine` units/naming question is **DEFERRED to the first
calibration run** (T-BU-M0) — it is a saved-calibration schema decision that
wants real data in hand. T-BU-2e guards the hazard defensively in the meantime,
so no task waits on it.

**Parallelism summary (bring-up optical path):**
  Round 0: 1 agent  (T-BU-0, sequential prereq — everything reads its constants)
  Round 1: 5 agents (T-BU-1a/1b/1c/1d/1e) + 1f reconciliation at the seam
  Round 2: 4 agents (T-BU-2a/2b/2c/2e)
  Round 3: 5 agents (T-BU-3a/3b/3c/3d/3e)
  Round 4: serialized (T-BU-4a; 4b blocked on TASK-EP; 4c after 0)

**Dependency edges that force the rounds:**
  everything            → T-BU-0   (constants)
  T-BU-2b               → T-BU-1a  (needs the coordinate map)
  T-BU-2a               → T-BU-1c + T-BU-1d  (wires both guards)
  T-BU-2b/2c, T-BU-3b/3e → T-BU-1e (needs somaSpotGeometry)
  T-BU-4b               → T-BU-3c + T-BU-3d + TASK-EP

**File-conflict map (bring-up optical path):**
  configs/real.yaml            — T-BU-0, then T-BU-4c (sequence)
  opticalModel.m               — T-BU-0 only
  sampleToDmdOffset.m / dmdToSampleOffset.m — T-BU-1a (new), T-BU-2b (consumer)
  singleSpot.m / multiSpot.m   — T-BU-1b only
  tests/test_patterns.m        — T-BU-1b only
  assertPatternInPatch.m       — T-BU-1c (new) + T-BU-2a (consumer)
  assertPulseEnergySafe.m      — T-BU-1d (new) + T-BU-2a (consumer)
  somaSpotGeometry.m           — T-BU-1e (new); consumed by 2b/2c/3b/3e
  fillFactorEnsemble.m         — T-BU-1e only
  tests/test_ensemble_fill_factor_mock.m — T-BU-1e only
  DMD.m / MockDMD.m / DLP650LNIR_DMD.m / makeHardware.m — T-BU-2a only
  tests/test_MockDMD.m         — T-BU-2a only
  ppsfPattern.m                — T-BU-2b only
  validatePPSFTarget.m         — T-BU-2b only
  alignDMDtoCamera.m / _mock.m — T-BU-2b only
  exp_ppsf_lateral / _2d / rapid_sequential / axial_ppsf — T-BU-2b only
  exp_power_curve / _3dshot / ensemble_activation / ensemble_fill_factor_power
                               — T-BU-2c only
  fitAffineCalib.m             — T-BU-3a only
  measureFocalPlaneTilt.m / _mock.m — T-BU-3b only
  tests/test_focalPlaneTilt_mock.m  — T-BU-3b only
  targetDepthOffset.m          — T-BU-3c (new) + T-BU-4b (consumer)
  dwellCorrection.m            — T-BU-3d (new) + T-BU-4b (consumer)
  measureIlluminationUniformity / verifyScanFieldComposition / measurePSF /
    calibrationGUI             — T-BU-3e only
  CLAUDE.md                    — T-BU-4a only
  Sequencer.m                  — TASK-EP (T-EP-3c/3d) first, then T-BU-4b

---

## COMPLETED TASKS

TASK-15-01 through TASK-15-05: Phase 1.5 all-optical simulator
  (37/38 tests green, committed 2026-05-19)
TASK-P3-01: RealScanImageBridge (msocket) — structured VERIFY docs +
  verifyProtocol() diagnostic method (committed 2026-05-19)
TASK-PLM-2: PLM unit tests — tests/test_MockPLM.m, 13 tests covering
  computeDefocusPattern physics, pupil mask, 180° symmetry, MockPLM log,
  TIPLM_PLM stubs (committed 2026-05-20)
TASK-EXP-FF: Ensemble fill-factor power-modulation experiment — per-neuron
  disk subsampling, 2 conditions (uniform sweep + differential per-cell),
  10-repeat averaging, illuminated-region awareness (commits 8f1a995,
  ec74efa, 2026-05-22; one uncommitted illuminated-region patch)