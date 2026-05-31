function result = runPLMTimingSweep_stub(cfgOverride, sessionName)
%runPLMTimingSweep_stub STUB — PLM switching-timing sweep (NOT YET IMPLEMENTED).
%
%   *** THIS IS A STUB.  IT ALWAYS ERRORS.  See "Why deferred" below. ***
%
%   This file reserves the function signature and documents the intended
%   design for the PLM (TI NIR PLM, dual DLPC900 controller) switching-
%   timing sweep.  It accepts the same arguments as runDMDTimingSweep and
%   would ultimately reuse the same toolset internals (acquireTimingRun,
%   analyzeTimingTrace, plotTimingResults); only the hardware layer and the
%   pattern-generation step differ.
%
%   result = runPLMTimingSweep_stub()
%   result = runPLMTimingSweep_stub(cfgOverride)
%   result = runPLMTimingSweep_stub(cfgOverride, sessionName)
%
%   Inputs
%   ------
%   cfgOverride : [] | struct (optional)
%       Partial config struct deep-merged onto defaultTimingConfig().
%       The same schema as runDMDTimingSweep; would be extended with PLM-
%       specific sub-fields (e.g. cfg.plm.nRows, cfg.plm.nCols,
%       cfg.plm.nPhaseStates, cfg.plm.exportDir) when implemented.
%
%   sessionName : char | string (optional)
%       Session sub-folder name (under cfg.paths.dataDir).
%
%   Output
%   ------
%   result : struct — identical schema to runDMDTimingSweep's output.
%       (Never returned; the function always errors before doing any work.)
%
% =========================================================================
% WHY THIS IS DEFERRED
% =========================================================================
%
%   The real DLPC900 USB-HID transport is not yet implemented.
%
%   In tfp.hardware.DLPC900_PLM, the connect() method only accepts
%   options.mockTransport = true (an in-process echo).  Calling
%   connect() without that flag throws:
%
%       tfp:hardware:DLPC900_PLM:notImplemented
%       "Real USB HID transport not yet implemented ..."
%
%   Until the hidapi mex or py.hid bridge is in place, on-the-fly pattern
%   upload to the DLPC900 cannot run on real hardware.  Without real
%   hardware the PLM timing measurement has no optical signal to capture,
%   so the sweep is meaningless.
%
% =========================================================================
% INTENDED REAL PATH  (implement when USB HID is available)
% =========================================================================
%
%   Step 0  — Hardware note on PLM phase patterns for timing measurements.
%
%     Unlike the DMD (where "all-off" sends zero light through a binary
%     amplitude mask), the PLM is a phase modulator: a flat/zero-phase
%     pattern sends light to the zero diffraction order, which is typically
%     BLOCKED by the Fourier-plane stop.  Therefore BOTH the ON pattern and
%     the OFF pattern must be non-zero phase ramps (tilts); the difference
%     between them is which lateral position the focused spot lands at:
%
%       Pattern A ("ON"):  a blazed-grating tilt that steers the focus onto
%                          the pinhole aperture over the APD.  This produces
%                          maximum APD photocurrent.
%
%       Pattern B ("OFF"): a different blazed-grating tilt that steers the
%                          focus to an off-pinhole position.  This produces
%                          minimum (dark) APD photocurrent.
%
%     Both patterns are uint8(nRows, nCols) with values in 0..31 (5-bit,
%     32 phase states for the TI NIR PLM).  They are generated as linear
%     phase ramps (diffraction gratings) with different spatial frequencies
%     (grating periods), giving different first-order deflection angles at
%     the back focal plane.  The tilt angle translates to a lateral shift at
%     the sample via the relay magnification.
%
%   Step 1  — Generate the two phase patterns.
%
%     plm = tfp.hardware.DLPC900_PLM(struct());
%     % Construct two linear-ramp (blazed-grating) phase patterns manually,
%     % or extend PLM.generatePatternLibrary to accept a 'tilt' mode.
%     % Pattern A: grating period pitchA_px steers spot onto pinhole.
%     % Pattern B: grating period pitchB_px steers spot off pinhole.
%     [col, ~] = meshgrid(1:plm.nCols, 1:plm.nRows);
%     patA = uint8(mod(col - 1, pitchA_px) * (plm.nPhaseStates / pitchA_px));
%     patB = uint8(mod(col - 1, pitchB_px) * (plm.nPhaseStates / pitchB_px));
%     pats = cat(3, patA, patB);   % uint8(nRows, nCols, 2)
%
%   Step 2  — Export the patterns as PNG files.
%
%     exportDir = fullfile(cfg.paths.dataDir, sessionName, 'plm_patterns');
%     filePaths = plm.exportPatternImages(pats, exportDir);
%     % filePaths{1} -> patA.png,  filePaths{2} -> patB.png
%
%   Step 3  — Flash the patterns to the DLPC900 via TI LightCrafter GUI.
%
%     This is a manual step (GUI-driven, not scriptable until USB HID lands):
%       a. Open the TI LightCrafter software on the scope PC.
%       b. Connect to the DLPC900 over USB.
%       c. Navigate to the Firmware tab → "Pre-stored Pattern Mode".
%       d. Import the two PNG files from exportDir.
%       e. Configure the pattern LUT: 2 entries, exposure per pattern = half
%          the commanded period (50% duty cycle).
%       f. Set trigger source to TRIG_IN_2, minimum pulse width >= 20 µs
%          (confirmed by TI FAE 2026-05-21).
%       g. Click "Validate" then "Play".
%       Estimated time: ~30 s per session.
%
%   Step 4  — Wiring note for TRIG_IN_2.
%
%     The NI PCIe-6323 DAQ outputs 3.3 V on its AO and DO lines.
%     The DLPC900 TRIG_IN_2 expects ~1.8 V logic (EVM schematic, TBD —
%     confirm from hardware docs before connecting).  A level-shifter
%     (e.g. TXB0101 or equivalent) is required between the DAQ AO output
%     and the DLPC900 EVM trigger input.  Minimum pulse width: 20 µs;
%     if the DAQ AO pulse is narrower, add a one-shot stretcher or use
%     a counter-output channel with a forced minimum width.
%
%   Step 5  — Run the sweep, reusing this toolset verbatim.
%
%     % Config: set device='PLM', tell acquireTimingRun to drive a PLM
%     % object instead of a DMD.  acquireTimingRun already accepts any
%     % hardware object that satisfies the timing shim interface; a thin
%     % PLM adapter struct or subclass will suffice.
%     cfg = defaultTimingConfig(struct('device', 'PLM', ...
%         'hardwareKind', 'real'));
%     % ... fill cfg.channels, cfg.sweep.ratesHz, cfg.plm fields ...
%
%     % acquireTimingRun(cfg, plmAdapter, daq, rate) — same call, same output
%     % analyzeTimingTrace, plotTimingResults — unchanged
%     % runDMDTimingSweep structure copied verbatim for the PLM case
%
%   Step 6  — Interpret results.
%
%     The PLM mirror response time and grating-order settling time set the
%     optical rise/fall; expected values are O(50 µs) for the DLPC900 in
%     Pre-stored Pattern Mode.  Compare against cfg.synth.riseTime_s for
%     plausibility.  The max reliable switching rate is limited by the
%     DLPC900 pattern rate (up to ~500 Hz in Pre-stored mode at full
%     resolution, or higher at reduced bit depth — check DLPU018 Table 1).
%
% =========================================================================
% THE SUPPORTED PATH TODAY
% =========================================================================
%
%   Use runDMDTimingSweep (same directory) for all current switching-timing
%   work.  The DMD path is fully implemented, mock-and-real tested, and
%   runs end-to-end on a dev Mac with no hardware:
%
%     result = runDMDTimingSweep(struct('hardwareKind','mock'), 'dmd_test');
%
%   See scripts/photodiode_timing_tests/README.md for the full toolset description.
%
% See also: runDMDTimingSweep, defaultTimingConfig, acquireTimingRun,
%           analyzeTimingTrace, plotTimingResults,
%           tfp.hardware.DLPC900_PLM, tfp.hardware.PLM,
%           scripts/photodiode_timing_tests/README.md

% -------------------------------------------------------------------------
% Accept (and ignore) the arguments so callers that construct this invocation
% never get an "too many input arguments" error before seeing the real one.
% -------------------------------------------------------------------------
if nargin < 1
    cfgOverride = []; %#ok<NASGU>
end
if nargin < 2
    sessionName = ''; %#ok<NASGU>
end

% -------------------------------------------------------------------------
% Suppress "variable defined but never used" lint warnings for the outputs.
% -------------------------------------------------------------------------
result = []; %#ok<NASGU>

% -------------------------------------------------------------------------
% Always error — this stub intentionally does no work.
% -------------------------------------------------------------------------
error('tfp:timing:runPLMTimingSweep:notImplemented', [ ...
    'runPLMTimingSweep is not yet implemented.\n\n' ...
    'REASON: tfp.hardware.DLPC900_PLM.connect() only supports a mock\n' ...
    'transport (options.mockTransport = true). The real USB-HID path\n' ...
    'needed to upload patterns on-the-fly is not yet written (hidapi\n' ...
    'mex / py.hid bridge pending). Without on-hardware pattern upload,\n' ...
    'the PLM timing sweep cannot acquire a meaningful optical signal.\n\n' ...
    'WHAT TO USE TODAY: runDMDTimingSweep — fully implemented, mock +\n' ...
    'real, runs end-to-end on a dev Mac:\n\n' ...
    '    result = runDMDTimingSweep(struct(''hardwareKind'',''mock''), ...\n' ...
    '                               ''dmd_timing_demo'');\n\n' ...
    'WHEN PLM IS READY: see the help block of this file (help\n' ...
    'runPLMTimingSweep_stub) for the full intended implementation path,\n' ...
    'including pattern-generation, LightCrafter GUI flashing, level-\n' ...
    'shifter wiring, and the acquireTimingRun/analyzeTimingTrace reuse\n' ...
    'plan.']);

end % runPLMTimingSweep_stub
