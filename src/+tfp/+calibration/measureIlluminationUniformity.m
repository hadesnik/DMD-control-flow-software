function calib = measureIlluminationUniformity(dmd, camera, options)
%measureIlluminationUniformity Measure illumination uniformity and reach across the field.
%   Tiles single spots across the DMD's active region, captures each on the
%   substage widefield camera, integrates the 2p fluorescence signal per spot,
%   and reports (a) a flat-field map of relative excitation across the field
%   and (b) the DMD-reachable extent — expressed in ScanImage scan-field
%   coordinates when a DMD→scan affine is supplied. This answers two rig
%   questions: "is the illumination uniform across the field?" and "how much
%   of the 2p scanning field can the DMD actually address?".
%
%   calib = measureIlluminationUniformity(dmd, camera)
%   calib = measureIlluminationUniformity(dmd, camera, options)
%
%   IMPORTANT — imaging constraint (same as alignDMDtoCamera):
%     ScanImage uses a PMT point detector and cannot image DMD spots. The
%     'camera' argument must be a tfp.hardware.SubstageCamera (real or mock).
%     The substage image of a temporal-focusing spot is 2p fluorescence
%     (∝ I²), so the integrated per-spot signal is a *2p-response* map. The
%     flat-field correction that equalises response uses this raw map
%     (calib.intensityNorm); calib.intensitySqrtNorm is its square root, the
%     relative *intensity* (∝ I), reported for reference.
%
%   Inputs:
%     dmd    - tfp.hardware.DMD-derived object, already initialised.
%     camera - tfp.hardware.SubstageCamera-derived object, already initialised.
%     options - optional struct:
%       .nGridPoints    — grid points per axis, odd (default 9)
%       .gridSpacing    — DMD-pixel spacing between grid points. If omitted,
%                         derived so the grid spans the active region:
%                         2*roiHalfWidthPx/(nGridPoints-1).
%       .roiHalfWidthPx — half-width of the active region in DMD px, used for
%                         the default span and the nominal active box
%                         (default floor(0.4*min(nRows,nCols)); pass the rig
%                         value, e.g. 278 for the DLP650LNIR).
%       .spotRadius     — spot radius in DMD px (default 15 ≈ cell-sized)
%       .intWindowPx    — half-size of the camera integration window (default 12)
%       .detectFrac     — a spot counts as reachable if its integrated signal
%                         is >= detectFrac * max signal (default 0.1)
%       .exposureS      — pause after each advanceToPattern before snap (default 0.1)
%       .dmdToScan_affine — 3×3 DMD→scan-field affine (from composeCalibration).
%                         When supplied, the reachable extent is mapped into
%                         scan-field coordinates.
%       .scanFieldBox   — [xmin ymin xmax ymax] imaging FOV in scan-field coords,
%                         for the coverage fraction.
%       .scanPixels     — [nFast nSlow]; if scanFieldBox is omitted, the FOV box
%                         defaults to [0.5 0.5 nFast+0.5 nSlow+0.5].
%       .umPerPixel     — camera pixel size at the sample plane (default 1.56)
%       .showFigure     — show diagnostic figure after measurement (default true)
%       .notes          — char note appended to calib.notes
%
%   Output calibration struct:
%     .dmdGridPts        — nPts×2 projected grid coords [col row] (DMD px)
%     .cameraPts         — nPts×2 detected spot centroids [x y] (camera px; NaN if undetected)
%     .intensity         — nPts×1 integrated 2p signal per spot (NaN if undetected)
%     .intensityNorm     — nPts×1 flat-field map, peak reachable spot = 1 (NaN outside)
%     .intensitySqrtNorm — sqrt of intensityNorm (relative intensity ∝ I)
%     .reachable         — nPts×1 logical, inside the illuminated footprint
%     .cv                — coefficient of variation over reachable spots (std/mean)
%     .minMaxRatio       — min/max over reachable spots
%     .nReachable        — count of reachable spots
%     .reachableHullDmd / .reachableHullScan — reachable-region convex hull
%     .activeBoxDmd      / .activeBoxScan     — nominal active-region box
%     .coverageFraction  — fraction of the imaging FOV the DMD can reach (or NaN)
%     .scanFieldBox, .nGridPoints, .gridSpacingPx, .roiHalfWidthPx
%     .umPerPixel, .timestamp, .notes
%
%   Requires: Image Processing Toolbox (via findSpotCentroid).
%
%   See also tfp.calibration.alignDMDtoCamera, tfp.calibration.composeCalibration.

if nargin < 3
    options = struct();
end

nGridPoints  = configField(options, 'nGridPoints', 9);
spotRadius   = configField(options, 'spotRadius',  15);
intWindowPx  = configField(options, 'intWindowPx', 12);
detectFrac   = configField(options, 'detectFrac',  0.1);
exposureS    = configField(options, 'exposureS',   0.1);
showFigure   = logical(configField(options, 'showFigure', true));
umPerPixel   = configField(options, 'umPerPixel',  1.56);
notes        = configField(options, 'notes', 'illumination uniformity + extent');
dmdToScan    = configField(options, 'dmdToScan_affine', []);
scanFieldBox = configField(options, 'scanFieldBox', []);
scanPixels   = configField(options, 'scanPixels', []);

% --- validate ---
if ~isnumeric(nGridPoints) || ~isscalar(nGridPoints) || nGridPoints < 3 || mod(nGridPoints,2) == 0
    error('tfp:calibration:measureIlluminationUniformity:badOptions', ...
        'options.nGridPoints must be an odd integer >= 3; got %g.', nGridPoints);
end
if ~isa(camera, 'tfp.hardware.SubstageCamera')
    error('tfp:calibration:measureIlluminationUniformity:badCamera', ...
        'camera must be a tfp.hardware.SubstageCamera; got %s.', class(camera));
end
if ~camera.isInitialized
    error('tfp:calibration:measureIlluminationUniformity:cameraNotInitialized', ...
        'camera must be initialized before calling measureIlluminationUniformity.');
end
if ~dmd.isInitialized
    error('tfp:calibration:measureIlluminationUniformity:dmdNotInitialized', ...
        'dmd must be initialized before calling measureIlluminationUniformity.');
end

roiHalfWidth = configField(options, 'roiHalfWidthPx', floor(0.4 * min(dmd.nRows, dmd.nCols)));
if isfield(options, 'gridSpacing') && ~isempty(options.gridSpacing)
    gridSpacing = options.gridSpacing;
else
    gridSpacing = 2 * roiHalfWidth / (nGridPoints - 1);
end

% --- build grid of DMD coordinates spanning the active region ---
half   = floor(nGridPoints / 2);
axis1d = (-half:half) * gridSpacing;
[colOff, rowOff] = meshgrid(axis1d, axis1d);
dmdCols = dmd.nCols/2 + colOff(:);
dmdRows = dmd.nRows/2 + rowOff(:);
dmdPts  = [dmdCols, dmdRows];              % nPts × 2
nPts    = size(dmdPts, 1);

% --- build and load pattern sequence ---
patterns = false(dmd.nRows, dmd.nCols, nPts);
for k = 1:nPts
    patterns(:,:,k) = tfp.patterns.singleSpot(dmd, dmdPts(k,:), spotRadius);
end
seqOpts.exposureUs = round(max(exposureS, 1e-3) * 1e6);
seqOpts.darkTimeUs = 0;
dmd.loadPatternSequence(patterns, seqOpts);
dmd.armSequence();

% --- project each spot, snap camera, integrate signal in a window ---
intensity = nan(nPts, 1);
cameraPts = nan(nPts, 2);
found     = false(nPts, 1);
for k = 1:nPts
    dmd.advanceToPattern(k);
    if exposureS > 0
        pause(exposureS);
    end
    frame = double(camera.snap());
    [inten, centroid, ok] = integrateSpot(frame, k, intWindowPx);
    intensity(k) = inten;
    if ok
        cameraPts(k,:) = centroid;
        found(k)       = true;
    end
end

% --- reachable = detected AND signal above detectFrac of the peak ---
% (undetected/near-zero spots fall outside the flat-top footprint).
maxInt    = max(intensity(found));
reachable = found & (intensity >= detectFrac * maxInt);

stats = uniformityStats(intensity, reachable);   % private helper

% --- nominal active-region box (for extent overlay) ---
cx = dmd.nCols/2; cy = dmd.nRows/2;
activeBoxDmd = [cx-roiHalfWidth cy-roiHalfWidth; ...
                cx+roiHalfWidth cy-roiHalfWidth; ...
                cx+roiHalfWidth cy+roiHalfWidth; ...
                cx-roiHalfWidth cy+roiHalfWidth];

if isempty(scanFieldBox) && ~isempty(scanPixels)
    scanFieldBox = [0.5 0.5 scanPixels(1)+0.5 scanPixels(2)+0.5];
end
ext = reachableExtent(dmdPts, reachable, activeBoxDmd, dmdToScan, scanFieldBox);  % private helper

% --- assemble output ---
calib.dmdGridPts        = dmdPts;
calib.cameraPts         = cameraPts;
calib.intensity         = intensity;
calib.intensityNorm     = stats.intensityNorm;
calib.intensitySqrtNorm = sqrt(max(stats.intensityNorm, 0));
calib.reachable         = reachable;
calib.cv                = stats.cv;
calib.minMaxRatio       = stats.minMaxRatio;
calib.nReachable        = stats.nReachable;
calib.nGridPoints       = nGridPoints;
calib.gridSpacingPx     = gridSpacing;
calib.roiHalfWidthPx    = roiHalfWidth;
calib.reachableHullDmd  = ext.reachableHullDmd;
calib.activeBoxDmd      = ext.activeBoxDmd;
calib.reachableHullScan = ext.reachableHullScan;
calib.activeBoxScan     = ext.activeBoxScan;
calib.coverageFraction  = ext.coverageFraction;
calib.scanFieldBox      = ext.scanFieldBox;
calib.umPerPixel        = umPerPixel;
calib.timestamp         = datetime('now');
calib.notes             = notes;

if showFigure
    plotUniformityDiagnostic(calib);
end
end

% =========================================================================
% Local functions
% =========================================================================

function [inten, centroid, ok] = integrateSpot(frame, frameIdx, halfWin)
%integrateSpot Locate the spot and integrate background-subtracted signal.
%   Returns ok=false (and NaN intensity) when no spot is detectable, so the
%   caller can flag that grid point as outside the illuminated footprint.
ok       = true;
centroid = [NaN NaN];
inten    = NaN;

try
    centroid = findSpotCentroid(frame, frameIdx);   % private helper (IPT)
catch
    ok = false;
    return;
end

bg = median(frame(:));
[nR, nC] = size(frame);
cx = round(centroid(1)); cy = round(centroid(2));
x1 = max(1,  cx - halfWin); x2 = min(nC, cx + halfWin);
y1 = max(1,  cy - halfWin); y2 = min(nR, cy + halfWin);

win = frame(y1:y2, x1:x2) - bg;
win(win < 0) = 0;
inten = sum(win(:));
end

function plotUniformityDiagnostic(calib)
figure('Name', 'Illumination Uniformity + Extent', 'NumberTitle', 'off');

% --- flat-field map over the DMD grid ---
subplot(1,2,1);
reach = calib.reachable;
scatter(calib.dmdGridPts(reach,1), calib.dmdGridPts(reach,2), 60, ...
    calib.intensityNorm(reach), 'filled');
hold on;
if any(~reach)
    scatter(calib.dmdGridPts(~reach,1), calib.dmdGridPts(~reach,2), 60, ...
        'x', 'MarkerEdgeColor', [0.5 0.5 0.5]);
end
colorbar; caxis([0 1]);
axis equal; grid on; set(gca, 'YDir', 'reverse');
xlabel('DMD col (px)'); ylabel('DMD row (px)');
title(sprintf('Flat-field (norm.)  —  CV = %.3f, min/max = %.2f', ...
    calib.cv, calib.minMaxRatio));

% --- reachable extent vs. scan field ---
subplot(1,2,2);
if ~isempty(calib.reachableHullScan)
    if ~isempty(calib.scanFieldBox)
        b = calib.scanFieldBox;
        plot([b(1) b(3) b(3) b(1) b(1)], [b(2) b(2) b(4) b(4) b(2)], ...
            'k-', 'LineWidth', 1.5, 'DisplayName', 'Imaging FOV');
        hold on;
    end
    if ~isempty(calib.activeBoxScan)
        box = calib.activeBoxScan([1:end 1], :);
        plot(box(:,1), box(:,2), 'b--', 'DisplayName', 'DMD active region');
        hold on;
    end
    fill(calib.reachableHullScan(:,1), calib.reachableHullScan(:,2), ...
        [1 0.6 0.2], 'FaceAlpha', 0.35, 'DisplayName', 'DMD reach');
    legend('Location', 'best');
    axis equal; grid on;
    xlabel('Scan-field fast (px)'); ylabel('Scan-field slow (px)');
    if isfinite(calib.coverageFraction)
        title(sprintf('DMD reach in scan field  —  coverage = %.0f%%', ...
            100 * calib.coverageFraction));
    else
        title('DMD reach in scan field');
    end
else
    % No affine supplied — show detected spot positions in camera space.
    valid = ~any(isnan(calib.cameraPts), 2);
    scatter(calib.cameraPts(valid,1), calib.cameraPts(valid,2), 40, 'filled');
    axis equal; grid on; set(gca, 'YDir', 'reverse');
    xlabel('Camera X (px)'); ylabel('Camera Y (px)');
    title('Detected spots (no scan-field affine supplied)');
end
end

function value = configField(s, name, default)
if isfield(s, name)
    value = s.(name);
else
    value = default;
end
end
