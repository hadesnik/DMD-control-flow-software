%test_ensemble_fill_factor_mock  Mac-runnable demo of fill-factor power experiment.
%
%   Exercises both conditions of tfp.experiments.exp_ensemble_fill_factor_power
%   against MockDMD + MockDAQ — no real hardware needed.
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

% -------------------------------------------------------------------------
% Mock hardware
% -------------------------------------------------------------------------
dmd = tfp.hardware.MockDMD();
dmd.initialize(struct('nRows', 800, 'nCols', 1280));

daq = tfp.hardware.MockDAQ();
daq.initialize(struct( ...
    'sampleRate',         10000, ...
    'analogInChannels',   [], ...
    'analogOutChannels',  1, ...
    'digitalInChannels',  {{}}, ...
    'digitalOutChannels', {{'port0/line10'}}));

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

% Sync TTL — exercise the per-trial onset pulse path in the mock.
options.syncDOLine         = 'port0/line10';
options.sessionStartPulseS = 0.025;
options.trialOnsetPulseS   = 0.002;

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
% Round-3 refactor: stim AO is queued via queueClockedAO against a single
% continuous DAQ session. The remaining outputSingleAnalog calls are the
% pre-session safety-off and the onCleanup safety-off (2 total).
clockedAoEvents = strcmp({aoLog.eventType}, 'queueClockedAO');
assert(sum(clockedAoEvents) == expected, ...
    'Expected %d queueClockedAO events (1 per trial), saw %d.', ...
    expected, sum(clockedAoEvents));
aoEvents = strcmp({aoLog.eventType}, 'outputSingleAnalog');

% Sync TTL log: 1 session-start pulse + 1 per-trial onset pulse.
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
% T-SYNC-11: assert new sync behavior on the experiment's result struct.
%   (2) Per-trial t_onset_daq_samples / t_offset_daq_samples are populated.
%   (3) Trial sample indices increase monotonically across the run.
%   (4) Out-pulse vs in-capture cross-check: one DO pulse per trial, and
%       inter-trial gaps derived from sample indices agree with host-side
%       toc gaps within a generous tolerance.
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

% Out-pulse vs in-capture cross-check: per-trial DO pulses are emitted
% just before queueClockedAO on each trial, so their host-time deltas
% must match the canonical sample-index deltas to within host jitter.
nTrialPulses = sum(pulseEvents) - 1;   % subtract the session-start pulse
assert(nTrialPulses == expected, ...
    'Out-pulse count mismatch: expected %d per-trial pulses, saw %d.', ...
    expected, nTrialPulses);

gapsFromSamples = diff(onsetSamplesRun) / result.sampleRate;
gapsFromHost    = diff(result.timing.run.onsetTSec);
maxSkewS        = max(abs(gapsFromSamples - gapsFromHost));
assert(maxSkewS < 0.050, ...
    'Out-pulse host timing and in-capture sample timing disagree by %.3f ms (>50 ms tol).', ...
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
% T-SYNC-11 (cont.): frame-clock decode roundtrip
%   (1) decodeFrameClock recovers synthesized rising-edge positions and
%       inferred rate from a MockDAQ continuous session that exposes a
%       frame-clock DI line. The fill-factor experiment itself does not
%       configure a frame-clock line (sessionCfg.diLines = {}), so this
%       roundtrip is exercised against a fresh, short session here.
% =========================================================================
runFrameClockDecodeRoundtrip();

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
