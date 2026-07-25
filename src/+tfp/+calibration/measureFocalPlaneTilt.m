function calib = measureFocalPlaneTilt(dmd, camera, zstage, options)
%measureFocalPlaneTilt Measure the focal-plane tilt across the FOV.
%   The tilted temporal-focusing grating makes the plane of best 2p focus tilt
%   across the field. This routine tiles single DMD spots across the active
%   region, sweeps the objective in Z (via a tfp.hardware.ZStage), and for each
%   spot finds the Z of best focus. Plane-fitting best-focus Z(x,y) yields the
%   tilt (angle, azimuth, peak-to-valley Z across the FOV).
%
%   Geometry (objective-Z): a fixed thin fluorescent film is imaged by the fixed
%   substage camera from below; moving the objective sweeps the *excitation*
%   focal plane through the film. Each spot's 2p brightness peaks at the
%   objective-Z where the tilted TF plane crosses the film at that spot.
%
%   calib = measureFocalPlaneTilt(dmd, camera, zstage)
%   calib = measureFocalPlaneTilt(dmd, camera, zstage, options)
%
%   Inputs:
%     dmd    - tfp.hardware.DMD-derived object, initialised.
%     camera - tfp.hardware.SubstageCamera-derived object, initialised
%              (ScanImage cannot image DMD spots — substage camera only).
%     zstage - tfp.hardware.ZStage-derived object, initialised.
%     options - optional struct:
%       .nGridPoints    — grid points per axis, odd (default 9)
%       .gridSpacing    — DMD-px spacing (default 2*roiHalfWidthPx/(nGridPoints-1))
%       .roiHalfWidthPx — active-region half-width (default floor(0.4*min(nRows,nCols)))
%       .spotRadius     — spot radius, DMD px (default 15)
%       .zSweepUm       — vector of objective Z positions to visit, µm about the
%                         nominal focus (default -20:4:20)
%       .settleS        — pause after each zstage.moveTo, s (default 0.2)
%       .exposureS      — pause before each snap, s (default 0.1)
%       .nAverages      — frames averaged per capture (default 1)
%       .intWindowPx    — half-window for brightness integration (default 12)
%       .cropHalfWidthPx— crop half-width for the Gaussian sharpness fit (default 30)
%       .umPerPixel     — DMD sample-plane pixel size, µm/DMD-px, for the tilt
%                         angle (default 0.270, the DLP650LNIR value)
%       .showFigure     — show diagnostic figure (default true)
%       .notes          — char appended to calib.notes
%
%   Output calib struct (see also measureFocalPlaneTilt_mock):
%     .dmdGridPts       — nPts×2 projected grid coords [col row]
%     .cameraPts        — nPts×2 spot centroid at best-focus Z (camera px; NaN if none)
%     .zSweepUm         — 1×nZ Z positions visited
%     .brightness       — nPts×nZ integrated 2p signal per spot per Z
%     .sigma            — nPts×nZ spot sigma (px) per spot per Z (sharpness)
%     .zBestBrightUm    — nPts×1 best-focus Z from brightness (primary)
%     .zBestSharpUm     — nPts×1 best-focus Z from sharpness
%     .valid            — nPts×1 logical, spot's brightness peak resolved inside the sweep
%     .planeBright/.planeSharp — fitPlane structs (.coeffs [c0 c1 c2], .residualsRms, ...)
%     .tiltAngleDeg     — focal-plane tilt from brightness fit (deg)
%     .tiltAzimuthDeg   — azimuth of steepest ascent (deg)
%     .tiltAnglesXYDeg  — [theta_x theta_y] (deg)
%     .peakToValleyUm   — Z span of the fitted plane over the measured FOV (µm)
%     .umPerPixel, .nGridPoints, .gridSpacingPx, .roiHalfWidthPx
%     .timestamp, .notes
%
%   Requires: Image Processing Toolbox (via findSpotCentroid).
%
%   See also tfp.calibration.measureIlluminationUniformity, tfp.hardware.ZStage.

if nargin < 4
    options = struct();
end

nGridPoints     = configField(options, 'nGridPoints', 9);
spotRadius      = configField(options, 'spotRadius',  15);
intWindowPx     = configField(options, 'intWindowPx', 12);
cropHalfWidthPx = configField(options, 'cropHalfWidthPx', 30);
exposureS       = configField(options, 'exposureS',   0.1);
nAverages       = configField(options, 'nAverages',   1);
settleS         = configField(options, 'settleS',     0.2);
zSweepUm        = configField(options, 'zSweepUm',    -20:4:20);
umPerPixel      = configField(options, 'umPerPixel',  0.270);
showFigure      = logical(configField(options, 'showFigure', true));
notes           = configField(options, 'notes', 'focal-plane tilt measurement');

% --- validate ---
if ~isnumeric(nGridPoints) || ~isscalar(nGridPoints) || nGridPoints < 3 || mod(nGridPoints,2) == 0
    error('tfp:calibration:measureFocalPlaneTilt:badOptions', ...
        'options.nGridPoints must be an odd integer >= 3; got %g.', nGridPoints);
end
if ~isa(camera, 'tfp.hardware.SubstageCamera')
    error('tfp:calibration:measureFocalPlaneTilt:badCamera', ...
        'camera must be a tfp.hardware.SubstageCamera; got %s.', class(camera));
end
if ~isa(zstage, 'tfp.hardware.ZStage')
    error('tfp:calibration:measureFocalPlaneTilt:badZStage', ...
        'zstage must be a tfp.hardware.ZStage; got %s.', class(zstage));
end
if ~camera.isInitialized
    error('tfp:calibration:measureFocalPlaneTilt:cameraNotInitialized', ...
        'camera must be initialized before calling measureFocalPlaneTilt.');
end
if ~dmd.isInitialized
    error('tfp:calibration:measureFocalPlaneTilt:dmdNotInitialized', ...
        'dmd must be initialized before calling measureFocalPlaneTilt.');
end
if ~zstage.isInitialized
    error('tfp:calibration:measureFocalPlaneTilt:zstageNotInitialized', ...
        'zstage must be initialized before calling measureFocalPlaneTilt.');
end
zSweepUm = zSweepUm(:)';
if numel(zSweepUm) < 3
    error('tfp:calibration:measureFocalPlaneTilt:badSweep', ...
        'options.zSweepUm needs >= 3 positions to localise best focus; got %d.', numel(zSweepUm));
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
dmdPts  = [dmdCols, dmdRows];
nPts    = size(dmdPts, 1);

% --- build and load one spot pattern per grid point ---
patterns = false(dmd.nRows, dmd.nCols, nPts);
for k = 1:nPts
    patterns(:,:,k) = tfp.patterns.singleSpot(dmd, dmdPts(k,:), spotRadius);
end
seqOpts.exposureUs = round(max(exposureS, 1e-3) * 1e6);
seqOpts.darkTimeUs = 0;
dmd.loadPatternSequence(patterns, seqOpts);
dmd.armSequence();

% --- sweep Z (outer, moves are slow), measure every spot at each Z ---
nZ         = numel(zSweepUm);
brightness = nan(nPts, nZ);
sigma      = nan(nPts, nZ);
cameraPts  = nan(nPts, 2);
bestBright = -inf(nPts, 1);   % track the centroid at each spot's brightest Z

for zi = 1:nZ
    zstage.moveTo(zSweepUm(zi));
    if settleS > 0
        pause(settleS);
    end
    for k = 1:nPts
        dmd.advanceToPattern(k);
        frame = grabAveraged(camera, nAverages, exposureS);
        try
            centroid = findSpotCentroid(frame, k);   % private helper (IPT)
        catch
            continue;   % spot not detectable at this Z — leave NaN
        end
        b = integrateSpot(frame, centroid, intWindowPx);
        brightness(k, zi) = b;
        if b > bestBright(k)
            bestBright(k)   = b;
            cameraPts(k, :) = centroid;
        end
        try
            g = fitGaussian2D(frame, centroid, cropHalfWidthPx);   % private helper
            sigma(k, zi) = sqrt(g.sx * g.sy);
        catch
            sigma(k, zi) = NaN;
        end
    end
end

% --- best-focus Z per spot: brightness maximum / sharpness minimum ---
zBestBrightUm = nan(nPts, 1); okB = false(nPts, 1);
zBestSharpUm  = nan(nPts, 1); okS = false(nPts, 1);
for k = 1:nPts
    [zBestBrightUm(k), okB(k)] = peakParabola(zSweepUm, brightness(k,:), true);
    [zBestSharpUm(k),  okS(k)] = peakParabola(zSweepUm, sigma(k,:),      false);
end

nEdge = sum(~okB);
if nEdge > 0
    warning('tfp:calibration:measureFocalPlaneTilt:edgePeaks', ...
        ['%d/%d spots had their brightness peak at a Z-sweep edge (or were ' ...
         'undetected) and were excluded from the plane fit — widen zSweepUm.'], ...
        nEdge, nPts);
end

% --- plane fit + tilt (lateral in DMD px relative to the DMD centre) ---
xr = dmdPts(:,1) - dmd.nCols/2;
yr = dmdPts(:,2) - dmd.nRows/2;
planeBright = fitPlane(xr(okB), yr(okB), zBestBrightUm(okB));   % private helper
planeSharp  = fitPlane(xr(okS), yr(okS), zBestSharpUm(okS));
tilt = planeTilt(planeBright, umPerPixel, xr(okB), yr(okB));    % private helper

% --- assemble ---
calib.dmdGridPts      = dmdPts;
calib.cameraPts       = cameraPts;
calib.zSweepUm        = zSweepUm;
calib.brightness      = brightness;
calib.sigma           = sigma;
calib.zBestBrightUm   = zBestBrightUm;
calib.zBestSharpUm    = zBestSharpUm;
calib.valid           = okB;
calib.planeBright     = planeBright;
calib.planeSharp      = planeSharp;
calib.tiltAngleDeg    = tilt.tiltAngleDeg;
calib.tiltAzimuthDeg  = tilt.tiltAzimuthDeg;
calib.tiltAnglesXYDeg = tilt.tiltAnglesXYDeg;
calib.peakToValleyUm  = tilt.peakToValleyUm;
calib.umPerPixel      = umPerPixel;
calib.nGridPoints     = nGridPoints;
calib.gridSpacingPx   = gridSpacing;
calib.roiHalfWidthPx  = roiHalfWidth;
calib.timestamp       = datetime('now');
calib.notes           = notes;

if showFigure
    plotTiltDiagnostic(calib);
end
end

% =========================================================================
% Local functions
% =========================================================================

function frame = grabAveraged(camera, nAverages, exposureS)
%grabAveraged Average nAverages snaps (settling exposureS before each).
frame = [];
for i = 1:max(1, nAverages)
    if exposureS > 0
        pause(exposureS);
    end
    f = double(camera.snap());
    if isempty(frame)
        frame = f;
    else
        frame = frame + f;
    end
end
frame = frame / max(1, nAverages);
end

function inten = integrateSpot(frame, centroid, halfWin)
%integrateSpot Background-subtracted signal summed in a window around the spot.
bg = median(frame(:));
[nR, nC] = size(frame);
cx = round(centroid(1)); cy = round(centroid(2));
x1 = max(1, cx - halfWin); x2 = min(nC, cx + halfWin);
y1 = max(1, cy - halfWin); y2 = min(nR, cy + halfWin);
win = frame(y1:y2, x1:x2) - bg;
win(win < 0) = 0;
inten = sum(win(:));
end

function [zBest, ok] = peakParabola(zvals, metric, findMax)
%peakParabola Sub-step extremum of metric vs Z by 3-point parabolic interp.
%   ok is false if the extremum lands at a sweep edge (range too small) or
%   fewer than 3 finite samples exist — the caller should exclude that spot.
zvals  = zvals(:);
metric = metric(:);
good   = isfinite(metric);
if nnz(good) < 3
    zBest = NaN; ok = false; return;
end

m = metric;
if ~findMax
    m = -m;                 % turn a minimum into a maximum
end
mm = m; mm(~good) = -inf;
[~, i] = max(mm);

if i == 1 || i == numel(zvals) || ~good(i-1) || ~good(i+1)
    zBest = zvals(i); ok = false; return;   % edge peak / missing neighbour
end

m1 = m(i-1); m2 = m(i); m3 = m(i+1);
denom = m1 - 2*m2 + m3;
if denom >= 0
    zBest = zvals(i); ok = true; return;    % not concave — take the sample
end
delta  = 0.5 * (m1 - m3) / denom;           % fractional index offset of vertex
dzMean = 0.5 * ((zvals(i) - zvals(i-1)) + (zvals(i+1) - zvals(i)));
zBest  = zvals(i) + delta * dzMean;
ok     = true;
end

function plotTiltDiagnostic(calib)
figure('Name', 'Focal-plane tilt', 'NumberTitle', 'off');

% --- best-focus Z map across the DMD grid ---
subplot(1,2,1);
reach = calib.valid;
scatter(calib.dmdGridPts(reach,1), calib.dmdGridPts(reach,2), 70, ...
    calib.zBestBrightUm(reach), 'filled');
hold on;
if any(~reach)
    scatter(calib.dmdGridPts(~reach,1), calib.dmdGridPts(~reach,2), 70, ...
        'x', 'MarkerEdgeColor', [0.5 0.5 0.5]);
end
colorbar; axis equal; grid on; set(gca, 'YDir', 'reverse');
xlabel('DMD col (px)'); ylabel('DMD row (px)');
title(sprintf('Best-focus Z (µm)  —  tilt = %.2f°, P-V = %.1f µm', ...
    calib.tiltAngleDeg, calib.peakToValleyUm));

% --- brightness-vs-Z for a few representative spots ---
subplot(1,2,2);
idx = round(linspace(1, size(calib.brightness,1), min(5, size(calib.brightness,1))));
hold on;
for j = idx
    plot(calib.zSweepUm, calib.brightness(j,:), '-o', 'MarkerSize', 3);
end
grid on;
xlabel('Objective Z (µm)'); ylabel('Spot brightness (a.u.)');
title('Brightness vs Z (sample spots)');
end

function value = configField(s, name, default)
if isfield(s, name)
    value = s.(name);
else
    value = default;
end
end
