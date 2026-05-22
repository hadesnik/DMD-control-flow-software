%test_ensemble_fill_factor_mock  Mac-runnable demo of fill-factor power experiment.
%
%   Exercises both conditions of tfp.experiments.exp_ensemble_fill_factor_power
%   against MockDMD + MockDAQ — no real hardware needed.
%
%   Cond 1: 10 fill levels (10% .. 100%) x 10 repeats = 100 trials, shuffled.
%   Cond 2: 3 decorrelated per-cell distributions x 10 repeats = 30 trials.
%
%   Timing is compressed for the dev machine (150 ms ON / 150 ms ISI):
%   130 trials -> ~39 s total. On the scope PC you'd use 0.5 s / 3 s ISI.
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
    'digitalOutChannels', {{}}));

% Identity calibration: scan-field coords == DMD pixel coords for the mock.
calib.dmdToScan_affine    = eye(3);
calib.scan_fast_axis_sign = 1;
calib.scan_slow_axis_sign = 1;

% -------------------------------------------------------------------------
% 10 ROI centroids scattered across the DMD FOV.
% -------------------------------------------------------------------------
rng(7);
nROIs  = 10;
margin = 80;
roiCentroids_scan = [ ...
    randi([margin, dmd.nCols - margin], nROIs, 1), ...
    randi([margin, dmd.nRows - margin], nROIs, 1)];
roiCentroids_scan = double(roiCentroids_scan);

fprintf('\nMock ROI centroids (DMD pixel coords):\n');
for k = 1:nROIs
    fprintf('  ROI %2d: col=%4d  row=%3d\n', k, ...
        roiCentroids_scan(k,1), roiCentroids_scan(k,2));
end

% -------------------------------------------------------------------------
% Companion live figure — static reference of the full disks (100% fill).
% -------------------------------------------------------------------------
initCompanionFigure(dmd, roiCentroids_scan, 15);

% -------------------------------------------------------------------------
% Experiment options (compressed timing for the mock)
% -------------------------------------------------------------------------
options.radiusPx       = 15;          % ~709 px/neuron; use 17 for ~925 px
options.stimDurationS  = 0.15;        % short for snappy mock; 0.5 on scope
options.interStimS     = 0.15;        % short for mock; 3.0 on scope (GCaMP recovery)
options.aoChannel      = 'ao1';
options.powerV         = 5.0;
options.rngSeed        = 0;           % reproducible

% Cond 1
options.runUniform           = true;
options.uniformFillFractions = 0.1:0.1:1.0;
options.uniformNRepeats      = 10;

% Cond 2
options.runDifferential          = true;
options.differentialNDistributions = 3;
options.differentialNRepeats     = 10;
options.differentialFillSet      = [0.2 0.4 0.6 0.8 1.0];
options.differentialMaxCorr      = 0.15;

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

aoLog  = daq.getLog();
aoEvents = strcmp({aoLog.eventType}, 'outputSingleAnalog');
% 2 events per trial (ON + OFF) + 1 init-zero + 1 cleanup-zero
assert(sum(aoEvents) == 2 * expected + 2, ...
    'Expected %d AO events, saw %d.', 2 * expected + 2, sum(aoEvents));

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

fprintf('\n[test_ensemble_fill_factor_mock] PASS — %d patterns advanced, %d AO events.\n', ...
    nAdvance, sum(aoEvents));

% =========================================================================
% Local helper
% =========================================================================
function initCompanionFigure(dmd, centroids, radiusPx)
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
plot(ax, centroids(:,1), centroids(:,2), 'ro', ...
    'MarkerSize', 22, 'LineWidth', 1.5);
for k = 1:size(centroids, 1)
    text(ax, centroids(k,1) + radiusPx + 6, centroids(k,2), ...
        sprintf('%d', k), 'Color', 'y', ...
        'FontSize', 11, 'FontWeight', 'bold');
end
title(ax, sprintf('Reference: %d disks at 100%% fill (r = %d px)', ...
    size(centroids, 1), radiusPx), ...
    'Color', 'w', 'FontSize', 12, 'FontWeight', 'bold');
drawnow;
end
