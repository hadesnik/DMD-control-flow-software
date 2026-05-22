function result = exp_ensemble_fill_factor_power(dmd, daq, roiCentroids_scan, calib, options)
%exp_ensemble_fill_factor_power Sweep ensemble power via DMD fill factor.
%
%   Photostimulates an ensemble of neurons (circular disk per neuron, default
%   radius 15 px -> ~709 pixels per neuron) while controlling effective
%   per-neuron laser power by varying the fraction of pixels in each neuron's
%   disk that are ON. The laser AO voltage is held constant; power modulation
%   comes from the DMD pattern itself, not from the FS-50 modulator.
%
%   Each trial drives every neuron at the same fill fraction; trials step
%   through 10%, 20%, ..., 100% (i.e. 0.1:0.1:1.0). By default pixel ordering
%   per neuron is fixed across the sweep so the 10% ON pixels are a strict
%   subset of the 20% ON pixels — this removes random pattern variance from
%   the resulting power curve. Set options.nestedSubsets = false to draw a
%   fresh random subset for every level.
%
%   result = exp_ensemble_fill_factor_power(dmd, daq, roiCentroids_scan, calib)
%   result = exp_ensemble_fill_factor_power(dmd, daq, roiCentroids_scan, calib, options)
%
%   Inputs:
%     dmd               - tfp.hardware.DMD subclass (MockDMD or real).
%     daq               - tfp.hardware.DAQ subclass (MockDAQ or real).
%     roiCentroids_scan - N x 2 double, [x y] centroids in ScanImage scan-field
%                         coordinates.
%     calib             - Calibration struct with .dmdToScan_affine (3x3).
%                         For mock/identity mapping pass struct with eye(3).
%     options - struct (all fields optional):
%       .radiusPx            - Disk radius per neuron, in DMD pixels (default
%                              15 -> ~709 px/neuron; use 17 for ~925 px which
%                              is closest to the 900-pixel pilot target).
%       .fillFractions       - 1 x K vector of fill fractions in [0, 1]
%                              (default 0.1:0.1:1.0).
%       .nestedSubsets       - true: nested pixel subsets across the sweep
%                              (no inter-level pattern variance, default).
%                              false: fresh random subset per level.
%       .rngSeed             - Seed for pixel-permutation RNG (default 0 so
%                              the experiment is reproducible from the seed
%                              alone). Pass 'shuffle' for non-reproducible.
%       .stimDurationS       - Laser ON duration per trial (default 0.5 s).
%       .interStimS          - Gap between trials in seconds (default 3.0 s,
%                              long enough for GCaMP to return to baseline).
%       .aoChannel           - AO channel for laser modulation (default 'ao1').
%       .powerV              - AO voltage during stim (default 5.0 V). This
%                              is held FIXED across all trials by design.
%       .showLiveFigure      - Display live DMD pattern (default true).
%       .sessionDir          - Directory for session log (default '').
%       .exposureUs          - DMD per-frame exposure (default 5000).
%       .darkTimeUs          - DMD inter-frame dark time (default 0).
%
%   Output result struct:
%     .nROIs              - Number of ROIs targeted.
%     .radiusPx           - Disk radius used.
%     .nFillLevels        - Number of fill-factor trials.
%     .fillFractions      - 1 x K commanded fill fractions.
%     .nPatchPixels       - N x 1 in-bounds patch pixel counts.
%     .nOnPixelsPerLevel  - N x K achieved ON-pixel counts per (neuron, level).
%     .dmdCentroids       - N x 2 DMD-pixel centroids (clamped).
%     .powerV             - Fixed AO voltage used (V).
%     .stimDurationS      - Stim duration used (s).
%     .interStimS         - ISI used (s).
%     .nestedSubsets      - Whether nested-subset mode was used.
%     .rngSeed            - Seed actually used.
%     .completedAt        - datetime of completion.
%
%   See also tfp.patterns.fillFactorEnsemble, tfp.experiments.exp_ensemble_activation.

if nargin < 5 || isempty(options)
    options = struct();
end

radiusPx       = configField(options, 'radiusPx',       15);
fillFractions  = configField(options, 'fillFractions',  0.1:0.1:1.0);
nestedSubsets  = configField(options, 'nestedSubsets',  true);
rngSeed        = configField(options, 'rngSeed',        0);
stimDurationS  = configField(options, 'stimDurationS',  0.5);
interStimS     = configField(options, 'interStimS',     3.0);
aoChannel      = configField(options, 'aoChannel',      'ao1');
powerV         = configField(options, 'powerV',         5.0);
showLiveFigure = configField(options, 'showLiveFigure', true);
sessionDir     = configField(options, 'sessionDir',     '');
exposureUs     = configField(options, 'exposureUs',     5000);
darkTimeUs     = configField(options, 'darkTimeUs',     0);

% --- Validate ROI input ---
if ~isnumeric(roiCentroids_scan) || ndims(roiCentroids_scan) ~= 2 ...
        || size(roiCentroids_scan, 2) ~= 2 || size(roiCentroids_scan, 1) < 1
    error('tfp:experiments:exp_ensemble_fill_factor_power:badROIs', ...
        'roiCentroids_scan must be Nx2 with N >= 1.');
end
if ~isstruct(calib) || ~isfield(calib, 'dmdToScan_affine')
    error('tfp:experiments:exp_ensemble_fill_factor_power:badCalib', ...
        'calib must be a struct with field .dmdToScan_affine (3x3).');
end

fillFractions = fillFractions(:)';
if any(~isfinite(fillFractions)) || any(fillFractions < 0) || any(fillFractions > 1)
    error('tfp:experiments:exp_ensemble_fill_factor_power:badFractions', ...
        'fillFractions entries must be finite values in [0, 1].');
end

nROIs        = size(roiCentroids_scan, 1);
nFillLevels  = numel(fillFractions);

% --- Coordinate transform ---
dmdCentroids = scanFieldToDMD(roiCentroids_scan, calib);
dmdCentroids = clampToDMD(dmdCentroids, dmd, roiCentroids_scan);

% --- Build patterns ----------------------------------------------------------
fprintf('[fill_factor_power] Building %d fill-factor patterns for %d ROIs ', ...
    nFillLevels, nROIs);
fprintf('(disk r = %g px = ~%d px/neuron, nested=%d)...\n', ...
    radiusPx, round(pi * radiusPx^2), nestedSubsets);

patternStack       = false(dmd.nRows, dmd.nCols, nFillLevels);
nOnPixelsPerLevel  = zeros(nROIs, nFillLevels);
nPatchPixels       = [];        % filled after first call
perms_             = {};        % persistent perms for nested-subset mode

ffOpts = struct('rngSeed', rngSeed);
for k = 1:nFillLevels
    if nestedSubsets && ~isempty(perms_)
        ffOpts.permutations = perms_;
    else
        ffOpts.permutations = {};   % redraw per level
    end
    fracVec = repmat(fillFractions(k), nROIs, 1);
    [pat, info] = tfp.patterns.fillFactorEnsemble( ...
        dmd, dmdCentroids, radiusPx, fracVec, ffOpts);
    patternStack(:, :, k)     = pat;
    nOnPixelsPerLevel(:, k)   = info.nOnPixels;
    if isempty(nPatchPixels)
        nPatchPixels = info.nPatchPixels;
    end
    if nestedSubsets
        perms_ = info.permutations;     % preserve order for next level
    end
end

% --- Load sequence onto DMD ---
dmdSeqOpts.exposureUs = exposureUs;
dmdSeqOpts.darkTimeUs = darkTimeUs;
dmd.loadPatternSequence(patternStack, dmdSeqOpts);
dmd.armSequence();

% --- Live figure ---
if showLiveFigure
    lh = initLiveFigure(dmd.nRows, dmd.nCols, dmdCentroids);
else
    lh = [];
end

% Safety: ensure laser starts off
daq.outputSingleAnalog(aoChannel, 0);
cleanupLaser = onCleanup(@() safetyOff(daq, aoChannel));  %#ok<NASGU>

% =========================================================================
% Fill-factor sweep
% =========================================================================
fprintf('\n=== FILL-FACTOR SWEEP (%d levels at %.3f V, %.0f ms ON / %.0f s ISI) ===\n', ...
    nFillLevels, powerV, stimDurationS * 1e3, interStimS);

for k = 1:nFillLevels
    f = fillFractions(k);
    meanOn = mean(nOnPixelsPerLevel(:, k));
    fprintf('  Level %2d/%2d: fill = %3.0f%%  ->  ~%.0f ON px/neuron\n', ...
        k, nFillLevels, f * 100, meanOn);

    dmd.advanceToPattern(k);

    updateFigure(lh, patternStack(:,:,k), dmdCentroids, 1:nROIs, ...
        sprintf('Fill-factor sweep  %d/%d  —  %.0f%% fill (%.0f px/neuron)  —  ON', ...
            k, nFillLevels, f * 100, meanOn));

    daq.outputSingleAnalog(aoChannel, powerV);
    pause(stimDurationS);
    daq.outputSingleAnalog(aoChannel, 0);

    updateFigure(lh, patternStack(:,:,k), dmdCentroids, 1:nROIs, ...
        sprintf('Fill-factor sweep  %d/%d  —  %.0f%% fill  —  off', ...
            k, nFillLevels, f * 100));

    pause(interStimS);
end
fprintf('  [fill-factor sweep] done\n');

% --- Log ---
if ~isempty(sessionDir) && isfolder(sessionDir)
    tfp.io.sessionLog(sessionDir, 'fill-factor-power-complete', struct( ...
        'nROIs', nROIs, 'nFillLevels', nFillLevels, ...
        'radiusPx', radiusPx, 'powerV', powerV, ...
        'stimDurationS', stimDurationS, 'interStimS', interStimS, ...
        'nestedSubsets', nestedSubsets, 'rngSeed', rngSeed));
end

% --- Result ---
result.nROIs             = nROIs;
result.radiusPx          = radiusPx;
result.nFillLevels       = nFillLevels;
result.fillFractions     = fillFractions;
result.nPatchPixels      = nPatchPixels;
result.nOnPixelsPerLevel = nOnPixelsPerLevel;
result.dmdCentroids      = dmdCentroids;
result.powerV            = powerV;
result.stimDurationS     = stimDurationS;
result.interStimS        = interStimS;
result.nestedSubsets     = nestedSubsets;
result.rngSeed           = rngSeed;
result.completedAt       = datetime('now');

fprintf('\n[fill_factor_power] Complete: %d trials across fill fractions [%s].\n', ...
    nFillLevels, num2str(fillFractions, '%.2f '));
end

% =========================================================================
% Coordinate transform
% =========================================================================

function dmdCoords = scanFieldToDMD(scanCoords, calib)
scanToDmd = inv(calib.dmdToScan_affine);
nPts  = size(scanCoords, 1);
pts_h = [scanCoords, ones(nPts, 1)]';
dmd_h = scanToDmd * pts_h;
dmdCoords = dmd_h(1:2, :)';
end

function dmdCoords = clampToDMD(dmdCoords, dmd, scanCoords)
nPts = size(dmdCoords, 1);
for k = 1:nPts
    col = dmdCoords(k, 1);
    row = dmdCoords(k, 2);
    if col < 1 || col > dmd.nCols || row < 1 || row > dmd.nRows
        warning('tfp:experiments:exp_ensemble_fill_factor_power:roiOutOfBounds', ...
            'ROI %d at scan-field [%.1f %.1f] maps to DMD [%.1f %.1f], outside [1..%d, 1..%d]. Clamping.', ...
            k, scanCoords(k,1), scanCoords(k,2), col, row, dmd.nCols, dmd.nRows);
        dmdCoords(k, 1) = max(1, min(dmd.nCols, col));
        dmdCoords(k, 2) = max(1, min(dmd.nRows, row));
    end
end
end

% =========================================================================
% Live figure
% =========================================================================

function lh = initLiveFigure(nRows, nCols, dmdCentroids)
lh.fig = figure('Name', 'Fill-Factor Power Sweep — Live DMD Pattern', ...
    'NumberTitle', 'off', 'Color', 'k', ...
    'Position', [80 80 960 640]);
lh.ax = axes(lh.fig, 'Color', 'k', ...
    'Position', [0.02 0.10 0.96 0.83]);

lh.img = imagesc(lh.ax, zeros(nRows, nCols));
colormap(lh.ax, gray);
clim(lh.ax, [0 1]);
axis(lh.ax, 'image');
axis(lh.ax, 'off');
hold(lh.ax, 'on');

lh.markersAll = plot(lh.ax, dmdCentroids(:,1), dmdCentroids(:,2), ...
    'o', 'Color', [0.35 0.35 0.35], 'MarkerSize', 18, ...
    'LineWidth', 1.5, 'MarkerFaceColor', 'none');

lh.markersActive = plot(lh.ax, NaN, NaN, 'ro', ...
    'MarkerSize', 18, 'LineWidth', 2.5, 'MarkerFaceColor', 'none');

lh.titleTxt = title(lh.ax, 'Loading patterns...', ...
    'Color', 'w', 'FontSize', 13, 'FontWeight', 'bold');
drawnow;
end

function updateFigure(lh, pattern, dmdCentroids, activeIdx, titleStr)
if isempty(lh)
    return
end
set(lh.img, 'CData', double(pattern));
if isempty(activeIdx)
    set(lh.markersActive, 'XData', NaN, 'YData', NaN);
else
    set(lh.markersActive, ...
        'XData', dmdCentroids(activeIdx, 1), ...
        'YData', dmdCentroids(activeIdx, 2));
end
set(lh.titleTxt, 'String', titleStr);
drawnow limitrate;
end

% =========================================================================
% Safety / cleanup
% =========================================================================

function safetyOff(daq, aoChannel)
try
    daq.outputSingleAnalog(aoChannel, 0);
catch
end
end

% =========================================================================
% Local helpers
% =========================================================================

function value = configField(s, name, default)
if isfield(s, name)
    value = s.(name);
else
    value = default;
end
end
