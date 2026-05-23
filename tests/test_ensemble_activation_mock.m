%test_ensemble_activation_mock  Smoke-test exp_ensemble_activation with mock hardware.
%
%   Runs the full two-condition ensemble activation experiment against
%   MockDMD, MockDAQ, and MockScanImageBridge — no real hardware, no
%   ScanImage connection. T-EP-3a refactored the experiment to drive
%   ScanImage episodically; this test asserts the new per-trial flow on
%   the mock bridge log.
%
%   20 random ROI centroids are generated within the mock DMD FOV.
%   The live figure is shown; the experiment takes ~20.5 s (20 sequential
%   500 ms stim + 500 ms gap each, then 1 ensemble stim, then 5 power-
%   series stims).
%
%   Usage:
%     cd to repo root, then:
%       >> run tests/test_ensemble_activation_mock
%     or:
%       >> addpath(fullfile(pwd, 'src'));
%       >> run tests/test_ensemble_activation_mock

addpath(fullfile(fileparts(mfilename('fullpath')), '..', 'src'));

% -------------------------------------------------------------------------
% Hardware
% -------------------------------------------------------------------------
dmd = tfp.hardware.MockDMD();
dmd.initialize(struct('nRows', 800, 'nCols', 1280));

% Frame-clock DI line — gives the experiment a synthetic frame clock to
% decode at session end so the aligner runs with real edge data.
syncDoLine      = 'port0/line10';
frameClockDiLine = 'port0/line2';
syncFrameRateHz = 30;

daq = tfp.hardware.MockDAQ();
daq.initialize(struct( ...
    'sampleRate',         10000, ...
    'analogInChannels',   [], ...
    'analogOutChannels',  1, ...
    'digitalInChannels',  {{frameClockDiLine}}, ...
    'digitalOutChannels', {{syncDoLine}}));
daq.configureDigitalOutput({syncDoLine});

% Mock ScanImage bridge for the episodic API. Uses a fresh tempdir so
% sidecars from prior runs don't bleed in.
mockTiffDir = fullfile(tempdir(), ...
    sprintf('tfp_mock_tiffs_%s', char(matlab.lang.makeValidName(datestr(now, 'HHMMSS_FFF')))));
if exist(mockTiffDir, 'dir')
    rmdir(mockTiffDir, 's');
end
mkdir(mockTiffDir);

bridgeCfg = struct( ...
    'frameRate',       syncFrameRateHz, ...
    'frameRateHz',     syncFrameRateHz, ...
    'simulateLatency', false, ...
    'mockTiffDir',     mockTiffDir);
siBridge = tfp.hardware.MockScanImageBridge({}, bridgeCfg);

% -------------------------------------------------------------------------
% Calibration (identity: scan-field coords == DMD pixel coords)
% -------------------------------------------------------------------------
calib.dmdToScan_affine    = eye(3);
calib.scan_fast_axis_sign = 1;
calib.scan_slow_axis_sign = 1;

% -------------------------------------------------------------------------
% Illuminated DMD region — 420x420 px centered on the chip (pilot FOV).
% -------------------------------------------------------------------------
spotRadiusPx     = 14;
regionSizePx     = 420;
cCenter          = floor(dmd.nCols / 2);
rCenter          = floor(dmd.nRows / 2);
half             = regionSizePx / 2;
illuminatedRegion = [cCenter - half, cCenter + half, ...
                     rCenter - half, rCenter + half];   % [c0 c1 r0 r1]

% -------------------------------------------------------------------------
% 20 random ROI centroids placed inside the illuminated region.
% -------------------------------------------------------------------------
rng(42);
nROIs = 20;
m     = spotRadiusPx;
roiCentroids_scan = [ ...
    randi([illuminatedRegion(1) + m, illuminatedRegion(2) - m], nROIs, 1), ...
    randi([illuminatedRegion(3) + m, illuminatedRegion(4) - m], nROIs, 1)];
roiCentroids_scan = double(roiCentroids_scan);

fprintf('\nIlluminated DMD region: cols [%g..%g], rows [%g..%g] (%dx%d px).\n', ...
    illuminatedRegion, regionSizePx, regionSizePx);
fprintf('Mock ROI centroids (DMD pixel coords, inside illuminated region):\n');
for k = 1:nROIs
    fprintf('  ROI %2d: col=%4d  row=%3d\n', k, ...
        roiCentroids_scan(k,1), roiCentroids_scan(k,2));
end

% -------------------------------------------------------------------------
% Mock power curve (linear 0–100 mW over 0–5 V)
% -------------------------------------------------------------------------
mockPowerCurve.voltageV = linspace(0, 5,   25);
mockPowerCurve.powerMw  = linspace(0, 100, 25);

% -------------------------------------------------------------------------
% Experiment options
% -------------------------------------------------------------------------
options.siBridge          = siBridge;
options.siBridgeBeginSessionOpts = struct('startAcqNumOverride', uint32(1));
options.spotRadiusPx      = spotRadiusPx;
options.illuminatedRegion = illuminatedRegion;
options.stimDurationS  = 0.5;
options.interStimS     = 0.5;
options.aoChannel      = 'ao1';
options.powerV         = 5.0;
options.powerCurve     = mockPowerCurve;
options.powerFractions = 0.2:0.2:1.0;
options.showLiveFigure = true;
options.syncDOLine     = syncDoLine;
options.frameClockLine = frameClockDiLine;
options.imagingFrameRate = syncFrameRateHz;
% Reset one-shot warnings the aligner emits so repeated test runs see them again.
tfp.io.resetAlignTrialsEpisodicWarnings();

% -------------------------------------------------------------------------
% Run
% -------------------------------------------------------------------------
fprintf('\nStarting mock ensemble activation (est. %.0f s)...\n', ...
    nROIs * (options.stimDurationS + options.interStimS) + options.stimDurationS);

result = tfp.experiments.exp_ensemble_activation( ...
    dmd, daq, roiCentroids_scan, calib, options);

% -------------------------------------------------------------------------
% Verify via DAQ + bridge logs.
% -------------------------------------------------------------------------
nPowerLevels   = numel(options.powerFractions);
expectedStims  = nROIs + 1 + nPowerLevels;
expectedAdv    = nROIs + 1 + nPowerLevels;

daqLog       = daq.getLog();
clockedAo    = daqLog(strcmp({daqLog.eventType}, 'queueClockedAO'));
safetyEvents = daqLog(strcmp({daqLog.eventType}, 'outputSingleAnalog'));
% sendDigitalPulse: session-start (long) + one per trial.
doPulses     = daqLog(strcmp({daqLog.eventType}, 'sendDigitalPulse'));

bridgeLog    = siBridge.getLog();
beginSessionEvents   = bridgeLog(strcmp({bridgeLog.eventType}, 'beginSession'));
armEvents            = bridgeLog(strcmp({bridgeLog.eventType}, 'armForExternalTrigger'));
waitEvents           = bridgeLog(strcmp({bridgeLog.eventType}, 'waitForCompletion'));
getTiffPathEvents    = bridgeLog(strcmp({bridgeLog.eventType}, 'getLastTiffPath'));

fprintf('\n--- Mock verification ---\n');
fprintf('  DAQ queueClockedAO events:     %d  (expected %d)\n', ...
    numel(clockedAo), expectedStims);
fprintf('  DAQ outputSingleAnalog events: %d  (safety-off only)\n', ...
    numel(safetyEvents));
fprintf('  DAQ sendDigitalPulse events:   %d  (expected %d = 1 session-start + %d per-trial)\n', ...
    numel(doPulses), expectedStims + 1, expectedStims);

fprintf('  siBridge beginSession events:  %d  (expected 1)\n', numel(beginSessionEvents));
fprintf('  siBridge arm events:           %d  (expected %d)\n', ...
    numel(armEvents), expectedStims);
fprintf('  siBridge wait events:          %d  (expected %d)\n', ...
    numel(waitEvents), expectedStims);
fprintf('  siBridge getLastTiffPath:      %d  (expected %d)\n', ...
    numel(getTiffPathEvents), expectedStims);

dmdLog = dmd.getLog();
advEvents = dmdLog(strcmp({dmdLog.eventType}, 'advanceToPattern'));
fprintf('  DMD advanceToPattern calls:    %d  (expected %d)\n', ...
    numel(advEvents), expectedAdv);

fprintf('\nPower-series voltages:\n');
for k = 1:nPowerLevels
    fprintf('  %.0f%%  →  %.3f V\n', ...
        options.powerFractions(k) * 100, result.powerSeriesVoltages(k));
end

fprintf('\nResult struct:\n');
fprintf('  nROIs:              %d\n', result.nROIs);
fprintf('  nSequentialTrials:  %d\n', result.nSequentialTrials);
fprintf('  nEnsembleTrials:    %d\n', result.nEnsembleTrials);
fprintf('  nPowerSeriesTrials: %d\n', result.nPowerSeriesTrials);
fprintf('  completedAt:        %s\n', char(result.completedAt));

assert(result.nROIs == nROIs, 'result.nROIs mismatch');
assert(result.nSequentialTrials == nROIs, 'nSequentialTrials mismatch');
assert(result.nEnsembleTrials == 1, 'nEnsembleTrials mismatch');
assert(result.nPowerSeriesTrials == nPowerLevels, 'nPowerSeriesTrials mismatch');
assert(numel(clockedAo) == expectedStims, ...
    'Expected %d queueClockedAO events, got %d', expectedStims, numel(clockedAo));
assert(numel(advEvents) == expectedAdv, ...
    'Expected %d advanceToPattern events, got %d', expectedAdv, numel(advEvents));
assert(all(diff(result.powerSeriesVoltages) > 0), ...
    'Power-series voltages should be monotonically increasing for linear curve');

% =========================================================================
% T-EP-3a: assert episodic bridge call sequence.
% =========================================================================
% (1) beginSession called exactly once before the trial loop.
assert(numel(beginSessionEvents) == 1, ...
    'Expected exactly 1 beginSession event, got %d.', numel(beginSessionEvents));
% beginSession must precede every arm event in log order.
firstArmTs = armEvents(1).timestamp;
assert(beginSessionEvents(1).timestamp <= firstArmTs, ...
    'beginSession must occur before the first armForExternalTrigger.');

% (2) armForExternalTrigger called once per trial with nFrames > 0.
assert(numel(armEvents) == expectedStims, ...
    'Expected %d arm events, got %d.', expectedStims, numel(armEvents));
for k = 1:numel(armEvents)
    nF = armEvents(k).payload.nFrames;
    assert(isnumeric(nF) && isscalar(nF) && nF > 0, ...
        'arm event %d nFrames must be a positive scalar; got %s.', ...
        k, mat2str(nF));
end

% (3) getLastTiffPath called once per trial; each returned path is a
%     non-empty .mat sidecar.
assert(numel(getTiffPathEvents) == expectedStims, ...
    'Expected %d getLastTiffPath events, got %d.', ...
    expectedStims, numel(getTiffPathEvents));
for k = 1:numel(getTiffPathEvents)
    p = getTiffPathEvents(k).payload.tiffPath;
    assert(~isempty(p) && endsWith(p, '.mat'), ...
        'getLastTiffPath event %d returned bad path: %s', k, char(p));
    assert(exist(p, 'file') == 2, ...
        'getLastTiffPath event %d points to a non-existent file: %s', ...
        k, char(p));
end

% (4) Every trial has its siTiffPath populated after the session.
assert(isfield(result, 'trials') && numel(result.trials) == expectedStims, ...
    'result.trials must carry %d Trial objects (got %d).', ...
    expectedStims, numel(result.trials));
for k = 1:numel(result.trials)
    p = result.trials(k).siTiffPath;
    assert(ischar(p) && ~isempty(p), ...
        'trial %d siTiffPath should be a non-empty char; got %s.', ...
        k, class(p));
    assert(exist(p, 'file') == 2, ...
        'trial %d siTiffPath points to a missing file: %s', k, p);
end

% (5) result.alignReport.fatal == false for a clean mock session.
assert(isfield(result, 'alignReport') && isstruct(result.alignReport), ...
    'result.alignReport must be present.');
assert(isfield(result.alignReport, 'fatal'), ...
    'result.alignReport must have a fatal field.');
assert(~result.alignReport.fatal, ...
    'result.alignReport.fatal must be false on a clean mock session; reason=%s', ...
    char(result.alignReport.fatalReason));

% (6) result.perFrame is a table with the right column names.
assert(istable(result.perFrame), ...
    'result.perFrame must be a table; got %s.', class(result.perFrame));
expectedCols = {'frameIdx', 'frameStartSample', 'trialIdx', 'phase'};
actualCols   = result.perFrame.Properties.VariableNames;
for k = 1:numel(expectedCols)
    assert(ismember(expectedCols{k}, actualCols), ...
        'perFrame missing expected column "%s" (got %s).', ...
        expectedCols{k}, strjoin(actualCols, ','));
end

% =========================================================================
% Sample-anchor invariants (preserved from T-SYNC-11)
% =========================================================================
allOnsetSamples = double([ ...
    result.sequentialOnsetSamples(:); ...
    result.ensembleOnsetSample; ...
    result.powerSeriesOnsetSamples(:)]);
allOffsetSamples = double([ ...
    result.sequentialOffsetSamples(:); ...
    result.ensembleOffsetSample; ...
    result.powerSeriesOffsetSamples(:)]);

nAllTrials = nROIs + 1 + nPowerLevels;
assert(numel(allOnsetSamples)  == nAllTrials);
assert(numel(allOffsetSamples) == nAllTrials);
assert(all(allOnsetSamples  > 0));
assert(all(allOffsetSamples > 0));
assert(all(diff(allOnsetSamples)  > 0));
assert(all(diff(allOffsetSamples) > 0));
assert(all(allOffsetSamples > allOnsetSamples));

% Trials must lie inside the captured continuous-session buffer.
assert(isstruct(result.sessionData) && isfield(result.sessionData, 'nSamplesTotal'), ...
    'result.sessionData must carry the captured continuous-session buffers.');
assert(allOffsetSamples(end) <= double(result.sessionData.nSamplesTotal), ...
    'Final trial offset sample (%d) exceeds session sample count (%d).', ...
    allOffsetSamples(end), double(result.sessionData.nSamplesTotal));

% Per-trial DAQ pulses: session-start + one per trial.
assert(numel(doPulses) == expectedStims + 1, ...
    'Expected %d sendDigitalPulse events (1 session-start + %d per-trial), saw %d.', ...
    expectedStims + 1, expectedStims, numel(doPulses));

% Frame-clock decode roundtrip — the experiment captured the synthetic DI
% via the continuous session and decoded it post-hoc.
assert(isfield(result, 'frameStartSamples'), ...
    'result.frameStartSamples must be present.');
assert(~isempty(result.frameStartSamples), ...
    'frame-clock decode produced an empty edge vector — DI was not captured.');
assert(abs(result.frameRateInferredHz - syncFrameRateHz) < 0.5, ...
    'Decoded frame rate %.3f Hz disagrees with synthetic %.3f Hz.', ...
    result.frameRateInferredHz, syncFrameRateHz);

fprintf('\nAll assertions passed.\n');
fprintf('[T-EP-3a] episodic bridge call sequence PASS — %d trials, %d arm/wait/path cycles.\n', ...
    nAllTrials, numel(armEvents));

dmd.cleanup();
daq.cleanup();

% Clean up the mock sidecar directory.
try
    rmdir(mockTiffDir, 's');
catch
end
