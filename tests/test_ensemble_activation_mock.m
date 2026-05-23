%test_ensemble_activation_mock  Smoke-test exp_ensemble_activation with mock hardware.
%
%   Runs the full two-condition ensemble activation experiment against
%   MockDMD and MockDAQ — no real hardware, no ScanImage connection.
%
%   20 random ROI centroids are generated within the mock DMD FOV.
%   The live figure is shown; the experiment takes ~20.5 s (20 sequential
%   500 ms stim + 500 ms gap each, then 1 ensemble stim).
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

daq = tfp.hardware.MockDAQ();
daq.initialize(struct( ...
    'sampleRate',         10000, ...
    'analogInChannels',   [], ...
    'analogOutChannels',  1, ...
    'digitalInChannels',  {{}}, ...
    'digitalOutChannels', {{}}));

% -------------------------------------------------------------------------
% Calibration (identity: scan-field coords == DMD pixel coords)
% -------------------------------------------------------------------------
% dmdToScan_affine maps [dmd_col; dmd_row; 1] -> [scan_x; scan_y; 1].
% Identity means the mock ROIs can be expressed directly in DMD pixel coords.
calib.dmdToScan_affine    = eye(3);
calib.scan_fast_axis_sign = 1;
calib.scan_slow_axis_sign = 1;

% -------------------------------------------------------------------------
% Illuminated DMD region — 420x420 px centered on the chip (pilot FOV).
% Each "cell" is modeled as a 28x28 px disk (~10 µm diameter at the sample),
% so the spot radius is 14 px.
% -------------------------------------------------------------------------
spotRadiusPx     = 14;
regionSizePx     = 420;
cCenter          = floor(dmd.nCols / 2);
rCenter          = floor(dmd.nRows / 2);
half             = regionSizePx / 2;
illuminatedRegion = [cCenter - half, cCenter + half, ...
                     rCenter - half, rCenter + half];   % [c0 c1 r0 r1]

% -------------------------------------------------------------------------
% 20 random ROI centroids placed inside the illuminated region, with a
% one-radius margin so every spot fits fully within the lit zone.
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
% Mock power curve (linear 0–100 mW over 0–5 V, as if from powerMeterSweep)
% Fractions [0.2 0.4 0.6 0.8 1.0] → voltages [1 2 3 4 5] V
% -------------------------------------------------------------------------
mockPowerCurve.voltageV = linspace(0, 5,   25);
mockPowerCurve.powerMw  = linspace(0, 100, 25);

% -------------------------------------------------------------------------
% Experiment options
% -------------------------------------------------------------------------
options.spotRadiusPx      = spotRadiusPx;        % ~28 px ~ 10 µm cell at sample
options.illuminatedRegion = illuminatedRegion;   % range-check spots fit in lit zone
options.stimDurationS  = 0.5;           % 500 ms laser ON
options.interStimS     = 0.5;           % 500 ms gap between sequential pulses
options.aoChannel      = 'ao1';         % FS-50 power modulation channel
options.powerV         = 5.0;           % full power (mock: just logged)
options.powerCurve     = mockPowerCurve;
options.powerFractions = 0.2:0.2:1.0;
options.showLiveFigure = true;

% -------------------------------------------------------------------------
% Run
% -------------------------------------------------------------------------
fprintf('\nStarting mock ensemble activation (est. %.0f s)...\n', ...
    nROIs * (options.stimDurationS + options.interStimS) + options.stimDurationS);

result = tfp.experiments.exp_ensemble_activation( ...
    dmd, daq, roiCentroids_scan, calib, options);

% -------------------------------------------------------------------------
% Verify via DAQ log
%
% Round-3 refactor: stim AO is now driven via `queueClockedAO` against a
% single continuous DAQ session, not via per-trial `outputSingleAnalog +
% pause`. The only `outputSingleAnalog` calls left are the pre-session
% safety-off and the onCleanup safety-off — counted, but not used to
% verify per-trial activity.
% -------------------------------------------------------------------------
nPowerLevels   = numel(options.powerFractions);
% Expected clocked-AO stims: nROIs (sequential) + 1 (ensemble) + nPowerLevels (series)
expectedStims = nROIs + 1 + nPowerLevels;
% Expected advanceToPattern: nROIs (sequential) + 1 (ensemble) + nPowerLevels (series)
expectedAdv   = nROIs + 1 + nPowerLevels;

daqLog       = daq.getLog();
clockedAo    = daqLog(strcmp({daqLog.eventType}, 'queueClockedAO'));
safetyEvents = daqLog(strcmp({daqLog.eventType}, 'outputSingleAnalog'));

fprintf('\n--- Mock verification ---\n');
fprintf('  DAQ queueClockedAO events:     %d  (expected %d)\n', ...
    numel(clockedAo), expectedStims);
fprintf('  DAQ outputSingleAnalog events: %d  (safety-off only)\n', ...
    numel(safetyEvents));

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
% Verify voltages are monotonically increasing (linear mock curve)
assert(all(diff(result.powerSeriesVoltages) > 0), ...
    'Power-series voltages should be monotonically increasing for linear curve');

% =========================================================================
% T-SYNC-11: assert new sync behavior on the experiment's result struct.
%   (2) Per-trial t_onset_daq_samples / t_offset_daq_samples are populated.
%   (3) Sample indices increase monotonically across the full run, with
%       every offset > its onset.
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
assert(numel(allOnsetSamples)  == nAllTrials, ...
    'Combined onset-sample vector length mismatch: expected %d, saw %d.', ...
    nAllTrials, numel(allOnsetSamples));
assert(numel(allOffsetSamples) == nAllTrials, ...
    'Combined offset-sample vector length mismatch: expected %d, saw %d.', ...
    nAllTrials, numel(allOffsetSamples));
assert(all(allOnsetSamples  > 0), ...
    't_onset_daq_samples must be populated (>0) for every trial.');
assert(all(allOffsetSamples > 0), ...
    't_offset_daq_samples must be populated (>0) for every trial.');
assert(all(diff(allOnsetSamples)  > 0), ...
    'Trial onset sample indices must be strictly increasing across the run.');
assert(all(diff(allOffsetSamples) > 0), ...
    'Trial offset sample indices must be strictly increasing across the run.');
assert(all(allOffsetSamples > allOnsetSamples), ...
    'Every trial offset sample must follow its onset sample.');

% Trials must lie inside the captured continuous-session buffer.
assert(isstruct(result.sessionData) && isfield(result.sessionData, 'nSamplesTotal'), ...
    'result.sessionData must carry the captured continuous-session buffers.');
assert(allOffsetSamples(end) <= double(result.sessionData.nSamplesTotal), ...
    'Final trial offset sample (%d) exceeds session sample count (%d).', ...
    allOffsetSamples(end), double(result.sessionData.nSamplesTotal));

fprintf('\nAll assertions passed.\n');
fprintf('[T-SYNC-11] experiment sync PASS — %d trials, sample indices monotonic.\n', ...
    nAllTrials);

dmd.cleanup();
daq.cleanup();

% =========================================================================
% T-SYNC-11 (cont.): frame-clock decode roundtrip + out-pulse cross-check
%
% The activation experiment does not yet drive the out-pulse DO path
% (T-OUT-2) nor configure a frame-clock DI line, so these two
% guarantees are exercised against a fresh, short MockDAQ continuous
% session here:
%   (1) decodeFrameClock recovers synthesized rising-edge positions and
%       inferred rate.
%   (4) One DO pulse per trial; inter-trial host-time deltas agree with
%       the sample-index deltas captured by currentSampleIndex within a
%       generous tolerance.
% =========================================================================
runSyncPipelineCheck();

% =========================================================================
% Local helper — T-SYNC-11 sync-pipeline assertions.
% =========================================================================
function runSyncPipelineCheck()
syncSampleRate  = 100000;
syncFrameRateHz = 30;
syncDoLine      = 'port0/line10';
syncDiLine      = 'port0/line2';

syncDAQ = tfp.hardware.MockDAQ();
syncDAQ.initialize(struct( ...
    'sampleRate',         syncSampleRate, ...
    'analogInChannels',   [], ...
    'analogOutChannels',  [], ...
    'digitalInChannels',  {{syncDiLine}}, ...
    'digitalOutChannels', {{syncDoLine}}));
syncDAQ.configureDigitalOutput({syncDoLine});

syncCfg                      = struct();
syncCfg.sampleRate           = syncSampleRate;
syncCfg.aiChannels           = [];
syncCfg.aoChannels           = [];
syncCfg.diLines              = {syncDiLine};
syncCfg.doLines              = {syncDoLine};
syncCfg.frameClockLine       = syncDiLine;
syncCfg.syntheticFrameRateHz = syncFrameRateHz;

syncDAQ.startContinuousSession(syncCfg);
sessionStart  = datetime('now');
sessionTic    = tic;

nSyncTrials   = 5;
stimDur_s     = 0.05;
isi_s         = 0.05;
syncTrials    = tfp.trial.Trial.empty;
outPulseSecs  = nan(nSyncTrials, 1);

for k = 1:nSyncTrials
    tr            = tfp.trial.Trial();
    tr.trialIdx   = k;
    tr.duration_s = stimDur_s;
    tr.preStim_s  = isi_s;

    onsetIdx = syncDAQ.currentSampleIndex();
    tr.markRunning(onsetIdx, syncSampleRate, sessionStart);
    syncDAQ.sendDigitalPulse(syncDoLine, 0.002);
    outPulseSecs(k) = toc(sessionTic);
    pause(stimDur_s);

    offsetIdx = syncDAQ.currentSampleIndex();
    tr.markComplete(struct(), offsetIdx);

    syncTrials(end+1) = tr; %#ok<AGROW>
    pause(isi_s);
end

sessionResult = syncDAQ.stopContinuousSession();

% (1) Frame-clock decode roundtrip — synthesized edges recovered exactly.
diCol = find(strcmp(sessionResult.lineNames.diLines, ...
    sessionResult.lineNames.frameClockLine), 1);
assert(~isempty(diCol), 'frameClockLine column not present in diData.');
diVec = sessionResult.diData(:, diCol);

[edges, decodedRateHz] = tfp.io.decodeFrameClock(diVec, sessionResult.sampleRate);

framePeriodSamples  = max(1, round(sessionResult.sampleRate / syncFrameRateHz));
nS                  = double(sessionResult.nSamplesTotal);
expectedEdgeSamples = uint64((1:framePeriodSamples:nS).');
assert(isequal(edges, expectedEdgeSamples), ...
    'Frame-clock decode roundtrip failed: %d decoded vs %d synthesized edges.', ...
    numel(edges), numel(expectedEdgeSamples));
assert(abs(decodedRateHz - syncFrameRateHz) < 0.5, ...
    'Frame rate roundtrip failed: decoded %.3f Hz vs synthesized %.3f Hz.', ...
    decodedRateHz, syncFrameRateHz);

% (4) Out-pulse vs in-capture cross-check.
syncLog   = syncDAQ.getLog();
nDoPulses = sum(strcmp({syncLog.eventType}, 'sendDigitalPulse'));
assert(nDoPulses == nSyncTrials, ...
    'Expected %d sendDigitalPulse events (1 per trial), saw %d.', ...
    nSyncTrials, nDoPulses);

onsetSamples    = arrayfun(@(t) double(t.t_onset_daq_samples), syncTrials);
gapsFromSamples = diff(onsetSamples) / sessionResult.sampleRate;
gapsFromHost    = diff(outPulseSecs(:).');
maxSkewS        = max(abs(gapsFromSamples - gapsFromHost));
assert(maxSkewS < 0.020, ...
    'Out-pulse host timing and in-capture sample timing disagree by %.3f ms (>20 ms tol).', ...
    1000 * maxSkewS);

% Bonus: alignTrialsToFrames runs cleanly against the decoded edges.
[perTrial, perFrame] = tfp.io.alignTrialsToFrames(syncTrials, edges);
assert(numel(perTrial) == nSyncTrials, ...
    'alignTrialsToFrames perTrial length mismatch.');
assert(height(perFrame) == numel(edges), ...
    'alignTrialsToFrames perFrame row count mismatch.');

syncDAQ.cleanup();

fprintf(['[T-SYNC-11] sync pipeline PASS — %d trials, %d frame-clock edges ' ...
         '(%.2f Hz), max out/in skew %.3f ms.\n'], ...
    nSyncTrials, numel(edges), decodedRateHz, 1000 * maxSkewS);
end
