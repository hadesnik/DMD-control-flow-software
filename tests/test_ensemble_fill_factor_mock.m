%test_ensemble_fill_factor_mock  Mac-runnable demo of fill-factor power sweep.
%
%   Runs tfp.experiments.exp_ensemble_fill_factor_power against MockDMD and
%   MockDAQ — no real hardware needed. Designed to be runnable on the dev
%   Mac. Pops up a live figure that shows:
%
%       (left)  the live DMD mask updating in real time as the sweep steps
%               through fill fractions 10% -> 100%, with overlaid ROI markers
%               (gray = inactive, red = currently driven).
%       (right) per-neuron disk masks before any fill subsampling, so the
%               full 30-px disks are visible alongside the partial masks
%               actually projected at each fill level.
%
%   Sweep: 10 ROIs scattered across the DMD FOV, disk radius 15 px (~709 px
%   per neuron), fill fractions 0.1:0.1:1.0, 400 ms ON / 400 ms ISI per
%   level so the full demo finishes in ~8 s.
%
%   Usage (from repo root):
%       >> run tests/test_ensemble_fill_factor_mock
%   or:
%       >> addpath(fullfile(pwd, 'src'));
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

% -------------------------------------------------------------------------
% Calibration (identity: scan-field coords == DMD pixel coords for the demo)
% -------------------------------------------------------------------------
calib.dmdToScan_affine    = eye(3);
calib.scan_fast_axis_sign = 1;
calib.scan_slow_axis_sign = 1;

% -------------------------------------------------------------------------
% 10 ROI centroids spread across the DMD FOV (in scan-field = DMD pixel
% coords thanks to identity calibration).
% -------------------------------------------------------------------------
rng(7);
nROIs  = 10;
margin = 80;    % keep disks away from DMD edges so no clamping warnings
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
% Companion live figure — shows full disks per neuron on the right.
% The experiment script will manage the main live mask on the left.
% -------------------------------------------------------------------------
companion = initCompanionFigure(dmd, roiCentroids_scan, 15);

% -------------------------------------------------------------------------
% Experiment options
% -------------------------------------------------------------------------
options.radiusPx       = 15;          % disk radius -> ~709 px / neuron; bump to 17 for ~925 px
options.fillFractions  = 0.1:0.1:1.0; % 10% .. 100% in 10% steps
options.nestedSubsets  = true;        % nested ON-pixel subsets -> clean power curve
options.rngSeed        = 0;           % reproducible
options.stimDurationS  = 0.4;         % short for a snappy demo
options.interStimS     = 0.4;
options.aoChannel      = 'ao1';
options.powerV         = 5.0;         % held constant; mock just logs the value
options.showLiveFigure = true;        % main DMD-mask live figure

% -------------------------------------------------------------------------
% Run
% -------------------------------------------------------------------------
result = tfp.experiments.exp_ensemble_fill_factor_power( ...
    dmd, daq, roiCentroids_scan, calib, options);  %#ok<NASGU>

% -------------------------------------------------------------------------
% Sanity checks against MockDMD's recorded log
% -------------------------------------------------------------------------
log = dmd.getLog();
nAdvance = sum(strcmp({log.eventType}, 'advanceToPattern'));
assert(nAdvance == numel(options.fillFractions), ...
    'Expected %d advanceToPattern events, saw %d.', ...
    numel(options.fillFractions), nAdvance);

aolog = daq.getLog();
aoEvents = strcmp({aolog.eventType}, 'outputSingleAnalog');
assert(any(aoEvents), 'Expected outputSingleAnalog events in MockDAQ log.');

fprintf('\n[test_ensemble_fill_factor_mock] PASS — %d patterns, %d AO events.\n', ...
    nAdvance, sum(aoEvents));

% =========================================================================
% Local helper — companion "full disks" figure
% =========================================================================
function companion = initCompanionFigure(dmd, centroids, radiusPx)
%initCompanionFigure  Static reference figure: full disks per neuron at 100% fill.
%
%   Shows the maximum-fill ensemble (every pixel in every disk ON) plus
%   numbered ROI markers. The main mask figure (created by the experiment
%   script) updates beside this — visually it's clear what fraction of each
%   disk is being lit at each fill level.

[full, ~] = tfp.patterns.fillFactorEnsemble( ...
    dmd, centroids, radiusPx, ones(size(centroids, 1), 1));

companion.fig = figure('Name', 'Full disks (reference at 100% fill)', ...
    'NumberTitle', 'off', 'Color', 'k', ...
    'Position', [1060 80 720 540]);
ax = axes(companion.fig, 'Color', 'k', 'Position', [0.04 0.06 0.94 0.88]);
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
