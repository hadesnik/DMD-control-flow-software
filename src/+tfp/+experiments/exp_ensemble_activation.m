function result = exp_ensemble_activation(dmd, daq, roiCentroids_scan, calib, options)
%exp_ensemble_activation Photostimulate a neuronal ensemble via two trial types.
%
%   Runs three stimulus conditions against a pre-defined set of ROIs whose
%   centroids are provided in ScanImage scan-field coordinates:
%
%     Sequential condition — each ROI stimulated alone in order.
%       Timing per ROI: 500 ms laser ON, 500 ms laser OFF.
%       The DMD pattern shows only the single target ROI during each pulse.
%
%     Ensemble condition — all ROIs stimulated simultaneously at full power.
%       Timing: 500 ms laser ON, 500 ms laser OFF (one pulse).
%       The DMD pattern is the logical OR of all individual ROI patterns.
%
%     Power-series condition — ensemble pattern repeated at 5 power levels.
%       Fractions of max power: [0.2, 0.4, 0.6, 0.8, 1.0].
%       AO voltages are looked up from options.powerCurve (output of
%       powerMeterSweep); if no curve is provided, voltages are scaled
%       linearly from options.powerV.
%       Timing per level: 500 ms laser ON, 500 ms laser OFF.
%
%   Laser power is set by driving the FS-50 AO input via daq.outputSingleAnalog.
%
%   result = exp_ensemble_activation(dmd, daq, roiCentroids_scan, calib)
%   result = exp_ensemble_activation(dmd, daq, roiCentroids_scan, calib, options)
%
%   Inputs:
%     dmd                - tfp.hardware.DMD subclass (MockDMD or real).
%     daq                - tfp.hardware.DAQ subclass (MockDAQ or real).
%     roiCentroids_scan  - Nx2 double, [x y] centroids in ScanImage scan-field
%                          coordinates (same units used during calibration).
%     calib              - Calibration struct containing .dmdToScan_affine (3×3).
%                          Produced by tfp.calibration.composeCalibration.
%                          For mock/identity mapping pass eye(3) as the affine.
%     options            - Struct (all fields optional):
%       .spotRadiusPx    - DMD spot radius in pixels (default 8).
%       .stimDurationS   - Stim pulse duration in seconds (default 0.5).
%       .interStimS      - Gap between sequential pulses in seconds (default 0.5).
%       .aoChannel       - AO channel for laser modulation (default 'ao1').
%       .powerV          - Voltage for laser ON at full power (default 5.0 V).
%       .powerCurve      - Struct from powerMeterSweep with fields .voltageV
%                          and .powerMw (merged curve). Used to convert power
%                          fractions to AO voltages. If empty, voltages are
%                          scaled linearly from powerV (default []).
%       .powerFractions        - 1xK vector of power fractions for the power-series
%                                condition (default [0.2 0.4 0.6 0.8 1.0]).
%       .powerSeriesInterStimS - ISI between power-series pulses in seconds
%                                (default 3.0 — allows GCaMP signal to return
%                                to baseline between levels).
%       .showLiveFigure  - Display live DMD pattern figure (default true).
%       .sessionDir      - Directory for log output (default '').
%
%   Output result struct:
%     .nROIs               - Number of ROIs targeted.
%     .nSequentialTrials   - Number of sequential pulses delivered (= nROIs).
%     .nEnsembleTrials     - 1.
%     .nPowerSeriesTrials  - Number of power-series pulses (= numel(powerFractions)).
%     .powerSeriesVoltages - AO voltages used for each power-series trial (V).
%     .powerSeriesFractions - Power fractions used.
%     .dmdCentroids        - Nx2 DMD-pixel coords for each ROI.
%     .stimDurationS       - Stim duration used (s).
%     .interStimS          - Inter-stim gap used (s).
%     .powerV              - Full-power AO voltage (V).
%     .completedAt         - datetime of completion.
%
%   See also tfp.io.receiveROIsFromScanImage, tfp.calibration.composeCalibration.

if nargin < 5 || isempty(options)
    options = struct();
end

spotRadiusPx   = configField(options, 'spotRadiusPx',   8);
stimDurationS  = configField(options, 'stimDurationS',  0.5);
interStimS     = configField(options, 'interStimS',     0.5);
aoChannel      = configField(options, 'aoChannel',      'ao1');
powerV         = configField(options, 'powerV',         5.0);
powerCurve            = configField(options, 'powerCurve',            []);
powerFractions        = configField(options, 'powerFractions',        0.2:0.2:1.0);
powerSeriesInterStimS = configField(options, 'powerSeriesInterStimS', 3.0);
showLiveFigure = configField(options, 'showLiveFigure', true);
sessionDir     = configField(options, 'sessionDir',     '');
exposureUs     = configField(options, 'exposureUs',     5000);   % µs per pattern frame
darkTimeUs     = configField(options, 'darkTimeUs',     0);

% --- Validate inputs ---
if ~isnumeric(roiCentroids_scan) || ndims(roiCentroids_scan) ~= 2 ...
        || size(roiCentroids_scan, 2) ~= 2 || size(roiCentroids_scan, 1) < 1
    error('tfp:experiments:exp_ensemble_activation:badROIs', ...
        'roiCentroids_scan must be Nx2 with N >= 1.');
end
if ~isstruct(calib) || ~isfield(calib, 'dmdToScan_affine')
    error('tfp:experiments:exp_ensemble_activation:badCalib', ...
        'calib must be a struct with field .dmdToScan_affine (3x3).');
end

nROIs = size(roiCentroids_scan, 1);

% --- Convert scan-field coords -> DMD pixel coords ---
dmdCentroids = scanFieldToDMD(roiCentroids_scan, calib);

% Clamp to DMD bounds (warn if any ROI is outside)
dmdCentroids = clampToDMD(dmdCentroids, dmd, roiCentroids_scan);

% --- Build patterns ---
fprintf('[ensemble_activation] Generating %d spot patterns + 1 ensemble...\n', nROIs);
individualPatterns = cell(nROIs, 1);
for i = 1:nROIs
    individualPatterns{i} = tfp.patterns.singleSpot(dmd, dmdCentroids(i,:), spotRadiusPx);
end
ensemblePattern = individualPatterns{1};
for i = 2:nROIs
    ensemblePattern = ensemblePattern | individualPatterns{i};
end

% Stack all N+1 patterns for DMD sequence: [ROI_1 ... ROI_N  ensemble]
allPatterns = false(dmd.nRows, dmd.nCols, nROIs + 1);
for i = 1:nROIs
    allPatterns(:,:,i) = individualPatterns{i};
end
allPatterns(:,:, nROIs + 1) = ensemblePattern;

% --- Load sequence onto DMD ---
dmdSeqOpts.exposureUs = exposureUs;
dmdSeqOpts.darkTimeUs = darkTimeUs;
dmd.loadPatternSequence(allPatterns, dmdSeqOpts);
dmd.armSequence();

% --- Live figure ---
if showLiveFigure
    lh = initLiveFigure(dmd.nRows, dmd.nCols, dmdCentroids);
else
    lh = [];
end

% Safety: ensure laser is off at start
daq.outputSingleAnalog(aoChannel, 0);
cleanupLaser = onCleanup(@() safetyOff(daq, aoChannel));  %#ok<NASGU>

% =========================================================================
% Sequential condition
% =========================================================================
fprintf('\n=== SEQUENTIAL (%d ROIs, %.0f ms on / %.0f ms off) ===\n', ...
    nROIs, stimDurationS * 1e3, interStimS * 1e3);

for i = 1:nROIs
    dmd.advanceToPattern(i);

    updateFigure(lh, individualPatterns{i}, dmdCentroids, i, ...
        sprintf('Sequential  %d / %d  —  ROI %d  —  ON', i, nROIs, i));

    daq.outputSingleAnalog(aoChannel, powerV);
    pause(stimDurationS);
    daq.outputSingleAnalog(aoChannel, 0);

    updateFigure(lh, individualPatterns{i}, dmdCentroids, [], ...
        sprintf('Sequential  %d / %d  —  ROI %d  —  off', i, nROIs, i));

    pause(interStimS);
    fprintf('  [seq] ROI %d / %d done\n', i, nROIs);
end

% =========================================================================
% Ensemble condition
% =========================================================================
fprintf('\n=== ENSEMBLE (all %d ROIs simultaneously, %.0f ms) ===\n', ...
    nROIs, stimDurationS * 1e3);

dmd.advanceToPattern(nROIs + 1);

updateFigure(lh, ensemblePattern, dmdCentroids, 1:nROIs, ...
    sprintf('Ensemble  —  all %d ROIs  —  ON', nROIs));

daq.outputSingleAnalog(aoChannel, powerV);
pause(stimDurationS);
daq.outputSingleAnalog(aoChannel, 0);

updateFigure(lh, ensemblePattern, dmdCentroids, 1:nROIs, ...
    sprintf('Ensemble  —  all %d ROIs  —  done', nROIs));

pause(interStimS);
fprintf('  [ensemble] done\n');

% =========================================================================
% Power-series condition — ensemble pattern at [0.2:0.2:1.0] × max power
% =========================================================================
powerFractions  = powerFractions(:)';           % ensure row vector
nPowerLevels    = numel(powerFractions);
seriesVoltages  = zeros(1, nPowerLevels);
for k = 1:nPowerLevels
    seriesVoltages(k) = fractionToVoltage(powerFractions(k), powerCurve, powerV);
end

fprintf('\n=== POWER SERIES (ensemble, %d levels: %s of max, %.0f s ISI) ===\n', ...
    nPowerLevels, mat2str(powerFractions, 2), powerSeriesInterStimS);
for k = 1:nPowerLevels
    v = seriesVoltages(k);
    fprintf('  Level %d/%d: %.0f%% max  →  %.3f V\n', ...
        k, nPowerLevels, powerFractions(k) * 100, v);

    dmd.advanceToPattern(nROIs + 1);   % ensemble pattern already loaded

    updateFigure(lh, ensemblePattern, dmdCentroids, 1:nROIs, ...
        sprintf('Power series  %d/%d  —  %.0f%% (%.3f V)  —  ON', ...
            k, nPowerLevels, powerFractions(k) * 100, v));

    daq.outputSingleAnalog(aoChannel, v);
    pause(stimDurationS);
    daq.outputSingleAnalog(aoChannel, 0);

    updateFigure(lh, ensemblePattern, dmdCentroids, 1:nROIs, ...
        sprintf('Power series  %d/%d  —  %.0f%%  —  off', ...
            k, nPowerLevels, powerFractions(k) * 100));

    pause(powerSeriesInterStimS);
end
fprintf('  [power series] done\n');

% --- Log ---
if ~isempty(sessionDir) && isfolder(sessionDir)
    tfp.io.sessionLog(sessionDir, 'ensemble-activation-complete', struct( ...
        'nROIs', nROIs, 'powerV', powerV, ...
        'stimDurationS', stimDurationS, 'interStimS', interStimS));
end

% --- Result ---
result.nROIs                 = nROIs;
result.nSequentialTrials     = nROIs;
result.nEnsembleTrials       = 1;
result.nPowerSeriesTrials    = nPowerLevels;
result.powerSeriesVoltages   = seriesVoltages;
result.powerSeriesFractions  = powerFractions;
result.dmdCentroids          = dmdCentroids;
result.stimDurationS         = stimDurationS;
result.interStimS            = interStimS;
result.powerV                = powerV;
result.completedAt           = datetime('now');

fprintf('\n[ensemble_activation] Complete: %d sequential + 1 ensemble + %d power-series trials.\n', ...
    nROIs, nPowerLevels);
end

% =========================================================================
% Coordinate transform
% =========================================================================

function dmdCoords = scanFieldToDMD(scanCoords, calib)
%scanFieldToDMD Apply inverse of dmdToScan_affine to map scan-field -> DMD pixels.
scanToDmd = inv(calib.dmdToScan_affine);
nPts  = size(scanCoords, 1);
pts_h = [scanCoords, ones(nPts, 1)]';   % 3 x N homogeneous
dmd_h = scanToDmd * pts_h;              % 3 x N
dmdCoords = dmd_h(1:2, :)';            % N x 2  [col row]
end

function dmdCoords = clampToDMD(dmdCoords, dmd, scanCoords)
nPts = size(dmdCoords, 1);
for k = 1:nPts
    col = dmdCoords(k, 1);
    row = dmdCoords(k, 2);
    if col < 1 || col > dmd.nCols || row < 1 || row > dmd.nRows
        warning('tfp:experiments:exp_ensemble_activation:roiOutOfBounds', ...
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
lh.fig = figure('Name', 'Ensemble Activation — Live DMD Pattern', ...
    'NumberTitle', 'off', 'Color', 'k', ...
    'Position', [80 80 960 640]);
lh.ax = axes(lh.fig, 'Color', 'k', ...
    'Position', [0.02 0.10 0.96 0.83]);

% Pattern image (starts all-black)
lh.img = imagesc(lh.ax, zeros(nRows, nCols));
colormap(lh.ax, gray);
clim(lh.ax, [0 1]);
axis(lh.ax, 'image');
axis(lh.ax, 'off');
hold(lh.ax, 'on');

% All ROI markers (dim gray circles, always visible)
lh.markersAll = plot(lh.ax, dmdCentroids(:,1), dmdCentroids(:,2), ...
    'o', 'Color', [0.35 0.35 0.35], 'MarkerSize', 15, ...
    'LineWidth', 1.5, 'MarkerFaceColor', 'none');

% Active ROI markers (bright red, updated each trial)
lh.markersActive = plot(lh.ax, NaN, NaN, 'ro', ...
    'MarkerSize', 15, 'LineWidth', 2.5, 'MarkerFaceColor', 'none');

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

function v = fractionToVoltage(fraction, powerCurve, maxV)
%fractionToVoltage Convert a fraction of max power to an AO voltage.
%   Uses the measured power curve (output of powerMeterSweep) to invert
%   power → voltage.  Falls back to linear scaling on voltage if no curve.
if isempty(powerCurve) || ~isfield(powerCurve, 'powerMw') ...
        || ~isfield(powerCurve, 'voltageV')
    % No calibration: treat voltage as linear proxy for power.
    v = fraction * maxV;
    return
end
maxPowerMw = max(powerCurve.powerMw);
targetMw   = fraction * maxPowerMw;
[sortedP, idx] = sort(powerCurve.powerMw);
sortedV = powerCurve.voltageV(idx);
v = interp1(sortedP, sortedV, targetMw, 'linear', 'extrap');
v = max(0, min(maxV, v));
end

function value = configField(s, name, default)
if isfield(s, name)
    value = s.(name);
else
    value = default;
end
end
