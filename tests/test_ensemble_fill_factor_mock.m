%test_ensemble_fill_factor_mock  Mac-runnable demo of fill-factor power experiment.
%
%   Exercises both conditions of tfp.experiments.exp_ensemble_fill_factor_power
%   against MockDMD + MockDAQ + MockScanImageBridge (episodic, T-EP-3b) — no
%   real hardware needed.
%
%   Cond 1: 10 fill levels (10% .. 100%) x 3 repeats = 30 trials, shuffled.
%   Cond 2: 3 decorrelated per-cell distributions x 3 repeats = 9 trials.
%
%   Timing is compressed for the dev machine (150 ms ON / 150 ms ISI):
%   39 trials -> ~12 s total. The real-hardware runner uses 10 repeats per
%   sub-condition and 0.5 s / 3 s ISI.
%
%   Live figure: pops up the DMD-mask viewer that updates every trial. During
%   Cond 2 the per-cell fill fractions are overlaid as yellow text labels
%   next to each ROI so you can see who's getting what.
%
%   A companion figure shows the full-disk reference (every disk at 100%
%   fill, numbered) so you can eyeball the partial masks against it.
%
%   Usage (from repo root, in MATLAB R2023a on this Mac):
%       >> run tests/test_ensemble_fill_factor_mock
%   or (already inside tests/):
%       >> test_ensemble_fill_factor_mock

addpath(fullfile(fileparts(mfilename('fullpath')), '..', 'src'));

% Episodic-aligner one-shot warnings (overlap, lowConfidence) are persistent
% across MATLAB sessions; reset so a previous test's state cannot mask a
% warning we want to observe here.
tfp.io.resetAlignTrialsEpisodicWarnings();

% -------------------------------------------------------------------------
% Mock hardware
% -------------------------------------------------------------------------
dmd = tfp.hardware.MockDMD();
dmd.initialize(struct('nRows', 800, 'nCols', 1280));

frameClockLine = 'port0/line2';

daq = tfp.hardware.MockDAQ();
daq.initialize(struct( ...
    'sampleRate',         10000, ...
    'analogInChannels',   [], ...
    'analogOutChannels',  1, ...
    'digitalInChannels',  {{frameClockLine}}, ...
    'digitalOutChannels', {{'port0/line10'}}));

% Episodic ScanImage bridge — writes one .mat sidecar per trial to a
% test-private tempdir so the aligner has real files to read.
mockTiffDir = fullfile(tempdir(), 'tfp_test_fill_factor_tiffs');
if exist(mockTiffDir, 'dir')
    rmdir(mockTiffDir, 's');
end
siBridge = tfp.hardware.MockScanImageBridge({}, struct( ...
    'frameRateHz',     30, ...
    'simulateLatency', false, ...
    'mockTiffDir',     mockTiffDir));

% Identity calibration: scan-field coords == DMD pixel coords for the mock.
calib.dmdToScan_affine    = eye(3);
calib.scan_fast_axis_sign = 1;
calib.scan_slow_axis_sign = 1;

% -------------------------------------------------------------------------
% Illuminated DMD region — 420x420 px centered on the chip (pilot FOV).
% Each "cell" is modeled as a 28x28 px disk (~10 µm diameter at the sample).
% -------------------------------------------------------------------------
diskRadiusPx   = 14;
regionSizePx   = 420;
cCenter        = floor(dmd.nCols / 2);
rCenter        = floor(dmd.nRows / 2);
half           = regionSizePx / 2;
illuminatedRegion = [cCenter - half, cCenter + half, ...
                     rCenter - half, rCenter + half];   % [c0 c1 r0 r1]

% -------------------------------------------------------------------------
% 10 ROI centroids placed inside the illuminated region, with a one-radius
% margin so every disk fits fully within the lit zone.
% -------------------------------------------------------------------------
rng(7);
nROIs = 10;
m = diskRadiusPx;
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
% Companion live figure — static reference of the full disks (100% fill),
% with the illuminated-region outline overlaid.
% -------------------------------------------------------------------------
initCompanionFigure(dmd, roiCentroids_scan, diskRadiusPx, illuminatedRegion);

% -------------------------------------------------------------------------
% Experiment options (compressed timing for the mock)
% -------------------------------------------------------------------------
options.radiusPx          = diskRadiusPx;          % ~615 px/neuron at r=14
options.illuminatedRegion = illuminatedRegion;     % yellow outline + range check
options.stimDurationS  = 0.15;        % short for snappy mock; 0.5 on scope
options.interStimS     = 0.15;        % short for mock; 3.0 on scope (GCaMP recovery)
options.aoChannel      = 'ao1';
options.powerV         = 5.0;
options.rngSeed        = 0;           % reproducible

% Cond 1 — 3 repeats per fill level in the mock (real run uses 10)
options.runUniform           = true;
options.uniformFillFractions = 0.1:0.1:1.0;
options.uniformNRepeats      = 3;

% Cond 2 — 3 repeats per distribution in the mock (real run uses 10)
options.runDifferential          = true;
options.differentialNDistributions = 3;
options.differentialNRepeats     = 3;
options.differentialFillSet      = [0.2 0.4 0.6 0.8 1.0];
options.differentialMaxCorr      = 0.15;

% Sync TTL + episodic ScanImage bridge — exercises the per-trial start-acq
% pulse path and the post-session frame-clock cross-check.
options.syncDOLine         = 'port0/line10';
options.sessionStartPulseS = 0.025;
options.startAcqPulseS     = 0.002;
options.frameClockLine     = frameClockLine;
options.frameRateHz        = 30;
options.frameBufferFrames  = 2;
options.siBridge           = siBridge;

% -------------------------------------------------------------------------
% Run
% -------------------------------------------------------------------------
result = tfp.experiments.exp_ensemble_fill_factor_power( ...
    dmd, daq, roiCentroids_scan, calib, options);

% -------------------------------------------------------------------------
% Sanity checks against MockDMD + MockDAQ logs
% -------------------------------------------------------------------------
dmdLog = dmd.getLog();
nAdvance = sum(strcmp({dmdLog.eventType}, 'advanceToPattern'));
expected = result.condition1.nTrials + result.condition2.nTrials;
assert(nAdvance == expected, ...
    'Expected %d advanceToPattern events, saw %d.', expected, nAdvance);

aoLog = daq.getLog();
% Episodic refactor (T-EP-3b): stim AO is queued via queueClockedAO against
% a single continuous DAQ session. The remaining outputSingleAnalog calls
% are the pre-session safety-off and the onCleanup safety-off (2 total).
clockedAoEvents = strcmp({aoLog.eventType}, 'queueClockedAO');
assert(sum(clockedAoEvents) == expected, ...
    'Expected %d queueClockedAO events (1 per trial), saw %d.', ...
    expected, sum(clockedAoEvents));
aoEvents = strcmp({aoLog.eventType}, 'outputSingleAnalog');

% DO pulse log: 1 session-start pulse + 1 per-trial start-acq pulse.
pulseEvents = strcmp({aoLog.eventType}, 'sendDigitalPulse');
assert(sum(pulseEvents) == expected + 1, ...
    'Expected %d sendDigitalPulse events (1 session-start + %d trials), saw %d.', ...
    expected + 1, expected, sum(pulseEvents));

% Per-trial timing tables are populated and monotonic.
assert(isfield(result, 'timing') && isfield(result.timing, 'run'), ...
    'result.timing.run missing.');
assert(numel(result.timing.run.onsetTSec) == expected, ...
    'result.timing.run.onsetTSec must have %d entries, saw %d.', ...
    expected, numel(result.timing.run.onsetTSec));
assert(all(isfinite(result.timing.run.onsetTSec)) ...
        && all(isfinite(result.timing.run.offsetTSec)), ...
    'All onset/offset timestamps must be finite.');
assert(all(diff(result.timing.run.onsetTSec) > 0), ...
    'Trial onsetTSec must be strictly increasing across the run.');
assert(all(result.timing.run.offsetTSec > result.timing.run.onsetTSec), ...
    'Each offset must follow its onset.');
assert(all(ismember(result.timing.run.condition, [1 2])), ...
    'Run condition labels must be 1 or 2.');

% Decorrelation sanity: pairwise |r| should all be <= the requested threshold
% (unless the fallback path was taken — we still report).
maxR = max(abs(result.condition2.pairwiseCorr));
fprintf('\nCond 2 distributions (per-cell fill fractions, %d cells x %d dists):\n', ...
    nROIs, result.condition2.nDistributions);
disp(result.condition2.distributions);
fprintf('Pairwise correlations: %s    max |r| = %.3f (threshold %.3f, %d sampling attempts)\n', ...
    mat2str(result.condition2.pairwiseCorr(:)', 3), ...
    maxR, result.condition2.maxCorrAccepted, result.condition2.attempts);

if ~result.condition2.fallback
    assert(maxR <= result.condition2.maxCorrAccepted + 1e-12, ...
        'Decorrelation post-check failed: max |r| = %.3f > threshold %.3f.', ...
        maxR, result.condition2.maxCorrAccepted);
end

% =========================================================================
% T-SYNC-11 carryover: per-trial DAQ-sample anchors are populated and
% monotonic; captured session buffers fully cover the experiment window.
% =========================================================================
onsetSamplesRun  = double(result.timing.run.onsetDaqSamples);
offsetSamplesRun = double(result.timing.run.offsetDaqSamples);

assert(numel(onsetSamplesRun) == expected, ...
    'result.timing.run.onsetDaqSamples must have %d entries, saw %d.', ...
    expected, numel(onsetSamplesRun));
assert(all(onsetSamplesRun  > 0), ...
    't_onset_daq_samples must be populated (>0) for every trial.');
assert(all(offsetSamplesRun > 0), ...
    't_offset_daq_samples must be populated (>0) for every trial.');
assert(all(diff(onsetSamplesRun)  > 0), ...
    'Trial onset sample indices must be strictly increasing across the run.');
assert(all(diff(offsetSamplesRun) > 0), ...
    'Trial offset sample indices must be strictly increasing across the run.');
assert(all(offsetSamplesRun > onsetSamplesRun), ...
    'Every trial offset sample must follow its onset sample.');

% Out-pulse vs in-capture cross-check: per-trial start-acq pulses fire
% just before queueClockedAO on each trial, so their host-time deltas must
% match the canonical sample-index deltas to within host jitter.
nTrialPulses = sum(pulseEvents) - 1;   % subtract the session-start pulse
assert(nTrialPulses == expected, ...
    'Start-acq pulse count mismatch: expected %d per-trial pulses, saw %d.', ...
    expected, nTrialPulses);

gapsFromSamples = diff(onsetSamplesRun) / result.sampleRate;
gapsFromHost    = diff(result.timing.run.onsetTSec);
maxSkewS        = max(abs(gapsFromSamples - gapsFromHost));
assert(maxSkewS < 0.050, ...
    'Start-acq host timing and in-capture sample timing disagree by %.3f ms (>50 ms tol).', ...
    1000 * maxSkewS);

% Captured continuous-session buffers must cover every trial: the last
% offset sample cannot extend past the final captured sample count.
sessionData = result.sessionData;
assert(isstruct(sessionData) && isfield(sessionData, 'nSamplesTotal'), ...
    'result.sessionData must carry the captured session buffers.');
assert(offsetSamplesRun(end) <= double(sessionData.nSamplesTotal), ...
    'Final trial offset sample (%d) exceeds session sample count (%d).', ...
    offsetSamplesRun(end), double(sessionData.nSamplesTotal));

fprintf('\n[test_ensemble_fill_factor_mock] legacy path PASS — %d patterns advanced, %d AO events, %d sync TTLs.\n', ...
    nAdvance, sum(aoEvents), sum(pulseEvents));
fprintf('[T-SYNC-11] experiment sync PASS — %d trials, monotonic samples, max out/in skew %.3f ms.\n', ...
    expected, 1000 * maxSkewS);

% =========================================================================
% T-EP-3b: assert episodic-bridge behaviour
%   (1) beginSession was called exactly once before the trial loop.
%   (2) armForExternalTrigger was called once per trial.
%   (3) getLastTiffPath was called once per trial; each returned path is
%       a non-empty .mat sidecar that exists on disk.
%   (4) Every trial.siTiffPath is populated.
%   (5) result.alignReport.fatal == false for the clean mock session.
%   (6) result.perFrame is a table with the documented columns.
% =========================================================================
bridgeLog        = siBridge.getLog();
beginSessionEvts = strcmp({bridgeLog.eventType}, 'beginSession');
armEvts          = strcmp({bridgeLog.eventType}, 'armForExternalTrigger');
tiffPathEvts     = strcmp({bridgeLog.eventType}, 'getLastTiffPath');
assert(sum(beginSessionEvts) == 1, ...
    'beginSession must be called exactly once; saw %d.', sum(beginSessionEvts));
% The beginSession event must precede every arm event.
firstBeginIdx = find(beginSessionEvts, 1, 'first');
firstArmIdx   = find(armEvts,          1, 'first');
assert(~isempty(firstArmIdx) && firstBeginIdx < firstArmIdx, ...
    'beginSession must precede the trial loop''s first armForExternalTrigger.');
assert(sum(armEvts) == expected, ...
    'Expected %d armForExternalTrigger calls (1 per trial), saw %d.', ...
    expected, sum(armEvts));
assert(sum(tiffPathEvts) == expected, ...
    'Expected %d getLastTiffPath calls (1 per trial), saw %d.', ...
    expected, sum(tiffPathEvts));

% Every per-trial TIFF path is a non-empty .mat sidecar that exists on disk.
runTiffPaths = result.timing.run.tiffPaths;
assert(numel(runTiffPaths) == expected, ...
    'result.timing.run.tiffPaths must hold %d entries; saw %d.', ...
    expected, numel(runTiffPaths));
for k = 1:expected
    p = runTiffPaths{k};
    assert(~isempty(p), 'Trial %d has empty siTiffPath.', k);
    assert(endsWith(p, '.mat'), ...
        'Trial %d TIFF path %s does not end in .mat.', k, p);
    assert(exist(p, 'file') == 2, ...
        'Trial %d sidecar %s does not exist on disk.', k, p);
end

% Trial-object copies inside result.trials also carry the siTiffPath.
assert(isfield(result, 'trials') && numel(result.trials) == expected, ...
    'result.trials must contain %d Trial objects.', expected);
for k = 1:expected
    assert(~isempty(result.trials(k).siTiffPath), ...
        'result.trials(%d).siTiffPath is empty.', k);
    assert(strcmp(result.trials(k).siTiffPath, runTiffPaths{k}), ...
        'Trial(%d).siTiffPath disagrees with timing.run.tiffPaths.', k);
end

% Align report exists and is non-fatal for the clean mock run.
assert(isfield(result, 'alignReport') && isstruct(result.alignReport), ...
    'result.alignReport must be a struct.');
assert(islogical(result.alignReport.fatal) && ~result.alignReport.fatal, ...
    'result.alignReport.fatal must be false for a clean mock session (reason="%s").', ...
    char(result.alignReport.fatalReason));

% perFrame is a table with the documented column set.
assert(isfield(result, 'perFrame') && istable(result.perFrame), ...
    'result.perFrame must be a table.');
expectedVars = {'frameIdx', 'frameStartSample', 'trialIdx', 'phase'};
actualVars   = result.perFrame.Properties.VariableNames;
for v = 1:numel(expectedVars)
    assert(any(strcmp(actualVars, expectedVars{v})), ...
        'result.perFrame missing column "%s" (have: %s).', ...
        expectedVars{v}, strjoin(actualVars, ', '));
end
assert(height(result.perFrame) == numel(result.frameStartSamples), ...
    'result.perFrame row count (%d) must match numel(frameStartSamples) (%d).', ...
    height(result.perFrame), numel(result.frameStartSamples));

fprintf('[T-EP-3b] episodic bridge PASS — beginSession=1, arm=%d, getLastTiffPath=%d, alignReport.fatal=false, perFrame=%dx%d.\n', ...
    sum(armEvts), sum(tiffPathEvts), height(result.perFrame), width(result.perFrame));

% =========================================================================
% T-SYNC-11 (cont.): frame-clock decode roundtrip
%   (1) decodeFrameClock recovers synthesized rising-edge positions and
%       inferred rate from a MockDAQ continuous session that exposes a
%       frame-clock DI line. Exercised on a fresh, short session here so
%       the assertions are independent of the experiment's pacing.
% =========================================================================
runFrameClockDecodeRoundtrip();

% =========================================================================
% T-BU-1e: soma-sized spot geometry + per-neuron power quantization.
%   (1) info.nPowerLevels == info.nPatchPixels, and a soma-sized disk gives
%       ~80 levels — not the ~900 the pilot assumed.
%   (2) The nested-subset permutation guarantee still holds, and matters
%       more now that 10% fill is only a handful of pixels.
%   (3) A fill ladder spaced finer than 1/nPatchPixels warns instead of
%       silently delivering duplicate patterns.
% =========================================================================
runSomaQuantizationChecks(dmd);

% Best-effort cleanup of the test's mock-TIFF sidecar directory.
if exist(mockTiffDir, 'dir')
    rmdir(mockTiffDir, 's');
end

% =========================================================================
% Local helper — frame-clock decode roundtrip on a fresh sync session.
% =========================================================================
function runFrameClockDecodeRoundtrip()
syncSampleRate  = 100000;
syncFrameRateHz = 30;
syncDiLine      = 'port0/line2';

syncDAQ = tfp.hardware.MockDAQ();
syncDAQ.initialize(struct( ...
    'sampleRate',         syncSampleRate, ...
    'analogInChannels',   [], ...
    'analogOutChannels',  [], ...
    'digitalInChannels',  {{syncDiLine}}, ...
    'digitalOutChannels', {{}}));

syncCfg                      = struct();
syncCfg.sampleRate           = syncSampleRate;
syncCfg.aiChannels           = [];
syncCfg.aoChannels           = [];
syncCfg.diLines              = {syncDiLine};
syncCfg.doLines              = {};
syncCfg.frameClockLine       = syncDiLine;
syncCfg.syntheticFrameRateHz = syncFrameRateHz;

syncDAQ.startContinuousSession(syncCfg);
pause(0.3);   % capture ~9 frames at 30 Hz
sessionResult = syncDAQ.stopContinuousSession();

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

syncDAQ.cleanup();

fprintf('[T-SYNC-11] frame-clock decode roundtrip PASS — %d edges, %.2f Hz.\n', ...
    numel(edges), decodedRateHz);
end

% =========================================================================
% Local helper
% =========================================================================
function initCompanionFigure(dmd, centroids, radiusPx, illuminatedRegion)
%initCompanionFigure  Static reference figure: full disks at 100% fill.

full = tfp.patterns.fillFactorEnsemble( ...
    dmd, centroids, radiusPx, ones(size(centroids, 1), 1));

fig = figure('Name', 'Full disks (reference at 100% fill)', ...
    'NumberTitle', 'off', 'Color', 'k', ...
    'Position', [1060 80 720 540]);
ax = axes(fig, 'Color', 'k', 'Position', [0.04 0.06 0.94 0.88]);
imagesc(ax, double(full));
colormap(ax, gray);
clim(ax, [0 1]);
axis(ax, 'image');
axis(ax, 'off');
hold(ax, 'on');

% Illuminated-region outline
if nargin >= 4 && ~isempty(illuminatedRegion)
    c0 = illuminatedRegion(1); c1 = illuminatedRegion(2);
    r0 = illuminatedRegion(3); r1 = illuminatedRegion(4);
    plot(ax, [c0 c1 c1 c0 c0], [r0 r0 r1 r1 r0], ...
        '--', 'Color', [1.0 0.85 0.2], 'LineWidth', 1.5);
end

plot(ax, centroids(:,1), centroids(:,2), 'ro', ...
    'MarkerSize', 22, 'LineWidth', 1.5);
for k = 1:size(centroids, 1)
    text(ax, centroids(k,1) + radiusPx + 6, centroids(k,2), ...
        sprintf('%d', k), 'Color', 'y', ...
        'FontSize', 11, 'FontWeight', 'bold');
end
title(ax, sprintf('Reference: %d disks at 100%% fill (r = %d px), illuminated region dashed', ...
    size(centroids, 1), radiusPx), ...
    'Color', 'w', 'FontSize', 12, 'FontWeight', 'bold');
drawnow;
end

% =========================================================================
% Local helper — T-BU-1e soma-sized geometry + power quantization.
% =========================================================================
function runSomaQuantizationChecks(dmd)
%runSomaQuantizationChecks  Pin the "~80 px, ~80 power levels" corollary.
%
%   The corrected optical model (docs/dmd_control_handoff.md §5) makes the
%   sample scale ~4x larger than the pilot assumed, so a soma-sized disk is
%   ~80 DMD pixels rather than ~900. That number is simultaneously the
%   per-neuron power resolution of fillFactorEnsemble.

model = tfp.util.opticalModel();
geom  = tfp.patterns.somaSpotGeometry();     % 12.7 um soma, design constants
somaRadiusPx = geom.radiusPx;                % area-matched isotropic fallback

centroids = [400 300; 700 500; 900 620];
nCells    = size(centroids, 1);

% --- (1) nPowerLevels is reported and equals the patch pixel count --------
[~, info] = tfp.patterns.fillFactorEnsemble(dmd, centroids, somaRadiusPx, 1.0);

assert(isfield(info, 'nPowerLevels'), ...
    'info.nPowerLevels must be reported (T-BU-1e).');
assert(isequal(info.nPowerLevels, info.nPatchPixels), ...
    'info.nPowerLevels must equal info.nPatchPixels.');
assert(isequal(info.requestedFractions, ones(nCells, 1)), ...
    'info.requestedFractions must echo the requested fill fractions.');
assert(all(abs(info.powerStepPct - 100 ./ info.nPatchPixels) < 1e-12), ...
    'info.powerStepPct must be 100/nPowerLevels.');
assert(all(info.nPatchPixels >= 70 & info.nPatchPixels <= 92), ...
    ['A soma-sized disk must be ~80 DMD pixels; saw %s. If this reads ~900 ' ...
     'the optical constants have regressed to the pre-optics guess.'], ...
    mat2str(info.nPatchPixels(:)'));
assert(all(abs(info.nPatchPixels - geom.nPixels) <= 5), ...
    'fillFactorEnsemble disk (%s px) disagrees with somaSpotGeometry (%d px).', ...
    mat2str(info.nPatchPixels(:)'), geom.nPixels);
assert(all(info.nOnPixels == info.nPatchPixels), ...
    '100%% fill must turn on every patch pixel.');

fprintf('\n[T-BU-1e] %s\n', geom.description);
fprintf('[T-BU-1e] fillFactorEnsemble at r = %.2f px -> %d patch px = %d power levels (%.2f%% steps).\n', ...
    somaRadiusPx, info.nPatchPixels(1), info.nPowerLevels(1), info.powerStepPct(1));

% The stale default this task retires: r = 14 px is not a cell.
legacyExtentUm = 2 * 14 * [model.umPerPixelGroove, model.umPerPixelDispersion];
assert(min(legacyExtentUm) > 30, ...
    'Sanity: the legacy radiusPx = 14 default should be a >30 um blob, not a soma.');
fprintf('[T-BU-1e] legacy radiusPx = 14 is a %.1f x %.1f um sample ellipse (%.1fx a soma).\n', ...
    legacyExtentUm, mean(legacyExtentUm) / geom.diameterUm);

% --- (2) Nested subsets still hold across a 10-level ladder ---------------
% Low fill is now only ~8 pixels, so a non-nested ordering would make the
% power sweep confound pattern identity with power.
levels = 0.1:0.1:1.0;

seedOpts = struct();
seedOpts.rngSeed = 11;
[~, base] = tfp.patterns.fillFactorEnsemble( ...
    dmd, centroids, somaRadiusPx, levels(1), seedOpts);

prevMasks = base.neuronMasks;
prevOn    = base.nOnPixels;
for i = 2:numel(levels)
    stepOpts = struct();
    stepOpts.permutations = base.permutations;
    [~, stepInfo] = tfp.patterns.fillFactorEnsemble( ...
        dmd, centroids, somaRadiusPx, levels(i), stepOpts);
    for k = 1:nCells
        assert(all(prevMasks{k}(:) <= stepInfo.neuronMasks{k}(:)), ...
            ['Nested-subset guarantee broken: neuron %d at fill %.1f is not ' ...
             'a superset of fill %.1f.'], k, levels(i), levels(i-1));
        assert(stepInfo.nOnPixels(k) == ...
            round(levels(i) * stepInfo.nPatchPixels(k)), ...
            'Neuron %d ON count must be the exact rounded pixel count.', k);
        assert(stepInfo.nOnPixels(k) >= prevOn(k), ...
            'ON count must be non-decreasing with fill fraction.');
    end
    prevMasks = stepInfo.neuronMasks;
    prevOn    = stepInfo.nOnPixels;
end
fprintf('[T-BU-1e] nested-subset ladder PASS — %d levels, %d..%d ON px per soma.\n', ...
    numel(levels), round(levels(1) * info.nPatchPixels(1)), info.nPatchPixels(1));

% --- (3) Too-fine a ladder warns rather than silently duplicating ---------
lastwarn('');
fineOpts = struct();
fineOpts.requestedFillLevels = linspace(0.005, 1, 200);   % 200 levels of ~80
tfp.patterns.fillFactorEnsemble(dmd, centroids, somaRadiusPx, 0.5, fineOpts);
[~, fineId] = lastwarn();
assert(strcmp(fineId, 'tfp:patterns:fillFactorEnsemble:fillQuantization'), ...
    ['Requesting 200 fill levels from an ~80-pixel spot must warn; ' ...
     'lastwarn id was "%s".'], fineId);

% A ladder the spot can actually resolve stays quiet.
lastwarn('');
coarseOpts = struct();
coarseOpts.requestedFillLevels = levels;
tfp.patterns.fillFactorEnsemble(dmd, centroids, somaRadiusPx, 0.5, coarseOpts);
[~, coarseId] = lastwarn();
assert(~strcmp(coarseId, 'tfp:patterns:fillFactorEnsemble:fillQuantization'), ...
    'A 10-level ladder on an ~80-level spot must not warn.');

% The warning is suppressible for callers that already reported it.
lastwarn('');
quietOpts = fineOpts;
quietOpts.warnOnQuantization = false;
tfp.patterns.fillFactorEnsemble(dmd, centroids, somaRadiusPx, 0.5, quietOpts);
[~, quietId] = lastwarn();
assert(~strcmp(quietId, 'tfp:patterns:fillFactorEnsemble:fillQuantization'), ...
    'options.warnOnQuantization = false must silence the advisory.');

% Bad ladder input is rejected.
badOpts = struct();
badOpts.requestedFillLevels = [0.5 1.7];
try
    tfp.patterns.fillFactorEnsemble(dmd, centroids, somaRadiusPx, 0.5, badOpts);
    error('Expected tfp:patterns:fillFactorEnsemble:badFillLevels.');
catch ME
    assert(strcmp(ME.identifier, 'tfp:patterns:fillFactorEnsemble:badFillLevels'), ...
        'Out-of-range requestedFillLevels must throw badFillLevels; got "%s".', ...
        ME.identifier);
end

% --- (4) Default behaviour is unchanged ----------------------------------
% Same seed, no new options -> byte-identical result to the legacy call.
o1 = struct(); o1.rngSeed = 3;
[patA, infoA] = tfp.patterns.fillFactorEnsemble(dmd, centroids, 14, 0.35, o1);
o2 = struct(); o2.rngSeed = 3;
[patB, infoB] = tfp.patterns.fillFactorEnsemble(dmd, centroids, 14, 0.35, o2);
assert(isequal(patA, patB) && isequal(infoA.nOnPixels, infoB.nOnPixels), ...
    'Default behaviour must be deterministic and unchanged.');
assert(all(infoA.nOnPixels == round(0.35 * infoA.nPatchPixels)), ...
    'Legacy radius path must still round fill fraction against the exact patch size.');

fprintf('[T-BU-1e] quantization advisory PASS — warns at 200 levels, quiet at 10, suppressible.\n');
end
