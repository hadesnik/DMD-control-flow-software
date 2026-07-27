function calib = measureFocalPlaneTilt(dmd, camera, zstage, options)
%measureFocalPlaneTilt Measure the focal-plane tilt across the FOV.
%   The tilted temporal-focusing grating makes the plane of best 2p focus tilt
%   across the field. This routine tiles single DMD spots across the active
%   region, sweeps the objective in Z (via a tfp.hardware.ZStage), and for each
%   spot finds the Z of best focus. Plane-fitting best-focus Z(x,y) yields the
%   tilt, which is then DECOMPOSED ONTO THE OPTICAL AXES and compared against
%   the design expectation of docs/dmd_control_handoff.md §6.
%
%   Geometry (objective-Z): a fixed thin fluorescent film is imaged by the fixed
%   substage camera from below; moving the objective sweeps the *excitation*
%   focal plane through the film. Each spot's 2p brightness peaks at the
%   objective-Z where the tilted TF plane crosses the film at that spot.
%
%   calib = measureFocalPlaneTilt(dmd, camera, zstage)
%   calib = measureFocalPlaneTilt(dmd, camera, zstage, options)
%
%   WHY THE DECOMPOSITION IS THE POINT (T-BU-3b). The chip is mounted clocked
%   45°, so the optical axes are the chip DIAGONALS, and the sample scale is
%   ANISOTROPIC: 1.4162 µm per DMD px along the grating's dispersion axis but
%   1.1250 µm along the grooves (tfp.util.opticalModel). The design tilt comes
%   from the grating, which disperses along one diagonal only, so it is
%   ENTIRELY along the dispersion axis and has NO groove-axis component. A
%   scalar tilt magnitude cannot express that, and a scalar µm/px conversion
%   cannot even compute it correctly — so the lateral→sample conversion here
%   goes through tfp.patterns.dmdToSampleOffset, never a scalar multiply, and
%   the answer is reported as a [dispersion groove] pair. A significant
%   groove-axis component is a RED FLAG (see the warnings below): objective
%   field curvature contributes only ~0.56 µm across the field and cannot
%   explain one.
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
%       .showFigure     — show diagnostic figure (default true)
%       .notes          — char appended to calib.notes
%     Optical model / coordinate map (all optional):
%       .config         — a loaded config (or an opticalModel struct) supplying
%                         the constants. Default: tfp.util.opticalModel defaults.
%       .model          — alias for .config.
%       .dmdToSampleLinear — 2×2/3×3 linear part of a FITTED, µm-valued
%                         DMD→sample affine. Supersedes the design constants
%                         (handoff §9: a fitted map always wins). Do NOT pass
%                         calibration.dmdToSample_affine — that one is
%                         CAMERA-valued; see tfp.patterns.dmdToSampleOffset.
%       .mapUnits, .cameraUmPerPixel — forwarded to that function's units guard.
%     Expectation check:
%       .checkExpectation      — run the design comparison (default true)
%       .warnOnExpectation     — raise the warnings below (default true)
%       .verbose               — print calib.report (default = .showFigure)
%       .grooveWalkToleranceUm — groove-axis depth walk that counts as
%                                significant, µm (default 3× the field-curvature
%                                contribution below, i.e. 1.68 µm)
%       .gradientToleranceFrac — allowed fractional deviation of the measured
%                                dispersion gradient from design (default 0.25)
%       .walkFwhmFraction      — walk/axial-FWHM above which the "field is not
%                                one plane" warning fires (default 0.5)
%       .fieldCurvatureUm      — objective field-curvature depth contribution
%                                across the field, µm (default 0.56, handoff §6)
%     Legacy:
%       .umPerPixel     — scalar µm per DMD px used ONLY for the legacy
%                         isotropic .tiltAngleDeg/.tiltAzimuthDeg fields.
%                         Default is now tfp.util.opticalModel().umPerPixel
%                         (the geometric mean of the two axis scales, ≈1.262),
%                         replacing the retired 0.270 guess. It is an
%                         order-of-magnitude convenience only — read
%                         .sampleTilt for the physically correct answer.
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
%     .sampleTilt       — THE AUTHORITATIVE RESULT: the plane gradient decomposed
%                         onto the optical axes. Fields include
%                         .gradientUmPerUm [dispersion groove], .tiltAngleDeg,
%                         .tiltDispersionDeg/.tiltGrooveDeg, .grooveFraction,
%                         .dispersionDiagonalUmPerPx/.grooveDiagonalUmPerPx,
%                         .dispersionWalkUm/.grooveWalkUm/.depthWalkAcrossPatchUm.
%     .sampleTiltSharp  — same decomposition for the sharpness plane (cross-check)
%     .expected         — design expectation, all derived from tfp.util.opticalModel
%     .expectationCheck — verdicts (.grooveComponentOK, .tiltOK, .signMatchesDesign,
%                         .depthWalkExceedsFwhm, .walkInAxialFwhm, .passed)
%     .report           — experimenter-facing text of the comparison, in words
%     .model            — the optical-model constants actually used
%     .tiltAngleDeg, .tiltAzimuthDeg, .tiltAnglesXYDeg, .peakToValleyUm
%                       — LEGACY isotropic reduction via the scalar .umPerPixel,
%                         retained for backward compatibility. .tiltAngleDeg is
%                         ~12% high on this build because the scalar cannot
%                         express the 1.26× anisotropy; use
%                         .sampleTilt.tiltAngleDeg instead.
%     .umPerPixel, .nGridPoints, .gridSpacingPx, .roiHalfWidthPx
%     .timestamp, .notes
%
%   Errors:   tfp:calibration:measureFocalPlaneTilt:<reason>
%   Warnings: ...:edgePeaks, ...:noPlane, ...:grooveComponent, ...:tiltMismatch,
%             ...:tiltSign, ...:depthWalkExceedsFwhm, ...:inconsistentDesign
%
%   Requires: Image Processing Toolbox (via findSpotCentroid).
%
%   See also tfp.calibration.measureIlluminationUniformity, tfp.hardware.ZStage,
%            tfp.util.opticalModel, tfp.patterns.dmdToSampleOffset.

if nargin < 4
    options = struct();
end

% Optical constants + the DMD→sample map. Everything downstream reads these;
% no µm/px number is written literally in this file.
[model, mapSpec, mapArgs] = resolveTiltMap_(options);

nGridPoints     = configField(options, 'nGridPoints', 9);
spotRadius      = configField(options, 'spotRadius',  15);
intWindowPx     = configField(options, 'intWindowPx', 12);
cropHalfWidthPx = configField(options, 'cropHalfWidthPx', 30);
exposureS       = configField(options, 'exposureS',   0.1);
nAverages       = configField(options, 'nAverages',   1);
settleS         = configField(options, 'settleS',     0.2);
zSweepUm        = configField(options, 'zSweepUm',    -20:4:20);
umPerPixel      = configField(options, 'umPerPixel',  model.umPerPixel);
showFigure      = logical(configField(options, 'showFigure', true));
notes           = configField(options, 'notes', 'focal-plane tilt measurement');

checkExpectation  = logical(configField(options, 'checkExpectation',  true));
warnOnExpectation = logical(configField(options, 'warnOnExpectation', true));
verbose           = logical(configField(options, 'verbose', showFigure));

%ASSUMED 0.56 µm — the objective's field-curvature depth contribution across
% the field, quoted in handoff §6 as "negligible here". It is not an
% opticalModel constant; it enters only as the yardstick for "how much
% groove-axis walk could be innocent".
fieldCurvatureUm = configField(options, 'fieldCurvatureUm', 0.56);

tol.grooveWalkUm      = configField(options, 'grooveWalkToleranceUm', 3 * fieldCurvatureUm);
tol.gradientFraction  = configField(options, 'gradientToleranceFrac', 0.25);
tol.walkFwhmFraction  = configField(options, 'walkFwhmFraction',      0.5);

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
if ~isnumeric(umPerPixel) || ~isscalar(umPerPixel) || ~isfinite(umPerPixel) || umPerPixel <= 0
    error('tfp:calibration:measureFocalPlaneTilt:badUmPerPixel', ...
        'options.umPerPixel must be a positive finite scalar; got %s.', mat2str(umPerPixel));
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

% --- decompose the gradient onto the optical (diagonal) axes ---
% This is the physically meaningful reduction; `tilt` above is the legacy
% isotropic one, kept only for backward compatibility.
sampleTilt      = sampleTiltDecomposition_(planeBright, model, mapSpec, mapArgs);
sampleTiltSharp = sampleTiltDecomposition_(planeSharp,  model, mapSpec, mapArgs);

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
calib.sampleTilt      = sampleTilt;
calib.sampleTiltSharp = sampleTiltSharp;
calib.model           = model;
calib.umPerPixel      = umPerPixel;
calib.nGridPoints     = nGridPoints;
calib.gridSpacingPx   = gridSpacing;
calib.roiHalfWidthPx  = roiHalfWidth;
calib.timestamp       = datetime('now');
calib.notes           = notes;

% --- compare against design expectation and say what it means ---
if checkExpectation
    expected = tiltExpectation_(model, fieldCurvatureUm);
    chk      = evaluateTiltExpectation_(sampleTilt, expected, tol);
    calib.expected         = expected;
    calib.expectationCheck = chk;
    calib.report           = tiltReport_(sampleTilt, expected, chk);
    if warnOnExpectation
        warnTiltExpectation_(sampleTilt, expected, chk);
    end
    if verbose
        fprintf('%s\n', calib.report);
    end
end

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
% Title quotes the anisotropy-correct tilt and its two axis components, since
% the scalar magnitude alone hides the diagnostic that matters.
title(sprintf('Best-focus Z (µm) — tilt %.2f° (disp %.2f°, groove %.2f°), P-V %.1f µm', ...
    calib.sampleTilt.tiltAngleDeg, calib.sampleTilt.tiltDispersionDeg, ...
    calib.sampleTilt.tiltGrooveDeg, calib.peakToValleyUm));

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

% =========================================================================
% SHARED TILT-EXPECTATION BLOCK  (T-BU-3b)
% Everything from here to the closing banner is DUPLICATED VERBATIM in
% measureFocalPlaneTilt.m and measureFocalPlaneTilt_mock.m so each file
% stands alone. MATLAB cannot share local functions across files, and these
% two are not in +private/ (this task owns only the two sources); the repo
% already uses this convention for sampleToDmdOffset/dmdToSampleOffset and
% singleSpot/multiSpot. KEEP THE TWO COPIES BYTE-IDENTICAL — `diff` them
% after editing either one.
%
% The warning identifiers below are deliberately the SAME from both entry
% points, so a test can assert one identifier regardless of whether the real
% routine or the mock produced the plane.
% =========================================================================

function [model, mapSpec, mapArgs] = resolveTiltMap_(options)
%resolveTiltMap_ Optical constants + the DMD->sample map spec from options.
%   options.config / options.model  - a loaded config or an opticalModel struct.
%   options.dmdToSampleLinear       - 2x2/3x3 linear part of a FITTED, um-valued
%                                     DMD->sample affine; supersedes the design
%                                     constants (handoff sec 9).
%   options.mapUnits / .cameraUmPerPixel - forwarded to the units guard in
%                                     tfp.patterns.dmdToSampleOffset.
cfg = configField(options, 'config', configField(options, 'model', struct()));
if ~isstruct(cfg)
    error('tfp:calibration:measureFocalPlaneTilt:badConfig', ...
        ['options.config (or options.model) must be a struct that ' ...
         'tfp.util.opticalModel accepts; got %s.'], class(cfg));
end
model = tfp.util.opticalModel(cfg);

% Design intent unless the caller hands in a fitted map. Note that mapSpec is
% the raw config, not `model`: tfp.patterns.dmdToSampleOffset re-derives the
% constants through tfp.util.opticalModel itself, so both sides of this
% function read the SAME single source of truth.
fitted = configField(options, 'dmdToSampleLinear', []);
if ~isempty(fitted)
    mapSpec = fitted;
else
    mapSpec = cfg;
end

mapArgs = {};
if isfield(options, 'mapUnits') && ~isempty(options.mapUnits)
    mapArgs(end+1:end+2) = {'mapUnits', options.mapUnits};
end
if isfield(options, 'cameraUmPerPixel') && ~isempty(options.cameraUmPerPixel)
    mapArgs(end+1:end+2) = {'cameraUmPerPixel', options.cameraUmPerPixel};
end
end

function Mt = dmdToSampleLinearT_(mapSpec, mapArgs)
%dmdToSampleLinearT_ Transpose of the DMD-px -> sample-um linear map M.
%   Built by pushing the two unit DMD steps through
%   tfp.patterns.dmdToSampleOffset, which is the single implementation of the
%   chip's 45-degree clocking and of the anisotropic axis scales. NEVER build
%   this from a scalar um/px: the sample scale differs by 1.26x between the two
%   chip diagonals and the tilt lives on those diagonals, so a scalar silently
%   mis-states every component of the answer.
%
%   Row k of Mt is the sample offset [x_disp y_groove] (um) produced by a
%   one-pixel step along DMD axis k of [dCol dRow]; i.e. Mt = M'. With depth
%   z = g_s . s and s = M d, the DMD-pixel gradient is g_px = M' * g_s, so
%       forward   g_px = Mt * g_s
%       recover   g_s  = Mt \ g_px
Mt = tfp.patterns.dmdToSampleOffset(eye(2), mapSpec, mapArgs{:});
end

function s = sampleTiltDecomposition_(plane, model, mapSpec, mapArgs)
%sampleTiltDecomposition_ Split a fitted plane into dispersion/groove tilt.
%   THE DIAGNOSTIC THAT MATTERS. The design tilt comes from the temporal-
%   focusing grating, which disperses along ONE chip diagonal, so it is
%   entirely along the dispersion axis and has NO groove-axis component
%   (handoff sec 6). Reporting only a scalar tilt magnitude hides that: a
%   plane tilted the wrong way has the same magnitude as the right one.
s = struct( ...
    'valid',                     false, ...
    'gradientUmPerUm',           [NaN NaN], ...   % [dispersion groove]
    'gradientDispersionUmPerUm', NaN, ...
    'gradientGrooveUmPerUm',     NaN, ...
    'gradientUmPerDmdPx',        [NaN NaN], ...   % [col row], as fitted
    'dispersionDiagonalUmPerPx', NaN, ...
    'grooveDiagonalUmPerPx',     NaN, ...
    'tiltAngleDeg',              NaN, ...
    'tiltDispersionDeg',         NaN, ...
    'tiltGrooveDeg',             NaN, ...
    'azimuthFromDispersionDeg',  NaN, ...
    'grooveFraction',            NaN, ...
    'dispersionWalkUm',          NaN, ...
    'grooveWalkUm',              NaN, ...
    'depthWalkAcrossPatchUm',    NaN);

if ~isstruct(plane) || ~isfield(plane, 'valid') || ~plane.valid ...
        || ~isfield(plane, 'coeffs') || numel(plane.coeffs) < 3 ...
        || ~all(isfinite(plane.coeffs(2:3)))
    return
end

Mt  = dmdToSampleLinearT_(mapSpec, mapArgs);
gPx = double(plane.coeffs(2:3));      % um depth per DMD px, [d/dcol d/drow]
gS  = Mt \ gPx(:);                    % um depth per um sample, [disp groove]

s.valid                     = true;
s.gradientUmPerDmdPx        = gPx(:)';
s.gradientUmPerUm           = gS(:)';
s.gradientDispersionUmPerUm = gS(1);
s.gradientGrooveUmPerUm     = gS(2);

% Depth walk per DMD pixel stepped along each optical diagonal. A one-pixel
% step along (1,1) advances umPerPixelDispersion micrometres at the sample, so
% these are just the sample gradients times the corresponding axis scale.
s.dispersionDiagonalUmPerPx = gS(1) * model.umPerPixelDispersion;
s.grooveDiagonalUmPerPx     = gS(2) * model.umPerPixelGroove;

s.tiltDispersionDeg        = atand(gS(1));
s.tiltGrooveDeg            = atand(gS(2));
s.tiltAngleDeg             = atand(norm(gS));
s.azimuthFromDispersionDeg = atan2d(gS(2), gS(1));
if norm(gS) > 0
    s.grooveFraction = abs(gS(2)) / norm(gS);
else
    s.grooveFraction = 0;
end

% Depth walk over the addressable ellipse: semi-axes patchRadiusPx times each
% axis scale. Over an ellipse the plane's peak-to-valley is
% 2*sqrt((g_d*a_d)^2 + (g_g*a_g)^2), which reduces to the handoff's
% "0.02174 um/um x 787 um = 17.1 um" for the design (groove-free) case.
aDisp   = model.patchRadiusPx * model.umPerPixelDispersion;
aGroove = model.patchRadiusPx * model.umPerPixelGroove;
s.dispersionWalkUm       = 2 * abs(gS(1)) * aDisp;
s.grooveWalkUm           = 2 * abs(gS(2)) * aGroove;
s.depthWalkAcrossPatchUm = 2 * sqrt((gS(1)*aDisp)^2 + (gS(2)*aGroove)^2);
end

function e = tiltExpectation_(model, fieldCurvatureUm)
%tiltExpectation_ Design expectation for the tilt (handoff sec 6).
%   Every number is DERIVED from tfp.util.opticalModel — nothing here is a
%   literal, so a config edit propagates into the comparison automatically.
e.depthGradientUmPerUm     = model.depthGradientUmPerUm;         % 0.02174
e.depthGradientSign        = model.depthGradientSign;            % %VERIFY
e.grooveGradientUmPerUm    = 0;                                  % by design: NONE
e.tiltAngleDeg             = model.focalPlaneTiltDeg;            % 1.245 deg
e.tiltAngleFromGradientDeg = atand(model.depthGradientUmPerUm);
e.diagonalUmPerDmdPx       = model.depthGradientUmPerUm * model.umPerPixelDispersion;
e.dispersionExtentUm       = 2 * model.patchRadiusPx * model.umPerPixelDispersion;
e.grooveExtentUm           = 2 * model.patchRadiusPx * model.umPerPixelGroove;
e.depthWalkAcrossPatchUm   = model.depthGradientUmPerUm * e.dispersionExtentUm;
e.axialFwhmUm              = model.axialFwhmUm;                  % 17.7 um
e.walkInAxialFwhm          = e.depthWalkAcrossPatchUm / model.axialFwhmUm;
e.fieldCurvatureUm         = fieldCurvatureUm;

% The config carries the gradient and the angle separately; they are redundant
% (angle = atand(gradient)). Disagreement means one of them was edited and the
% other left stale, which would make this whole comparison meaningless.
if abs(e.tiltAngleDeg - e.tiltAngleFromGradientDeg) > 0.05
    warning('tfp:calibration:measureFocalPlaneTilt:inconsistentDesign', ...
        ['Design constants disagree: dmd.focalPlaneTiltDeg = %.4f deg but ' ...
         'atand(dmd.depthGradientUmPerUm = %.5g) = %.4f deg. These are ' ...
         'redundant descriptions of the same surface — fix whichever is ' ...
         'stale in the config before trusting the comparison below.'], ...
        e.tiltAngleDeg, e.depthGradientUmPerUm, e.tiltAngleFromGradientDeg);
end
end

function chk = evaluateTiltExpectation_(s, e, tol)
%evaluateTiltExpectation_ Measured-vs-design verdicts (no I/O, all assertable).
chk.valid                    = s.valid;
chk.grooveWalkUm             = s.grooveWalkUm;
chk.grooveWalkToleranceUm    = tol.grooveWalkUm;
chk.grooveComponentOK        = s.valid && abs(s.grooveWalkUm) <= tol.grooveWalkUm;
chk.gradientRatio            = abs(s.gradientDispersionUmPerUm) / e.depthGradientUmPerUm;
chk.gradientToleranceFrac    = tol.gradientFraction;
chk.tiltOK                   = s.valid && abs(chk.gradientRatio - 1) <= tol.gradientFraction;
chk.signMatchesDesign        = s.valid && ...
                               sign(s.gradientDispersionUmPerUm) == e.depthGradientSign;
chk.walkInAxialFwhm          = s.depthWalkAcrossPatchUm / e.axialFwhmUm;
chk.walkFwhmFraction         = tol.walkFwhmFraction;
chk.depthWalkExceedsFwhm     = s.valid && chk.walkInAxialFwhm >= tol.walkFwhmFraction;
chk.passed                   = chk.valid && chk.grooveComponentOK && chk.tiltOK;
end

function warnTiltExpectation_(s, e, chk)
%warnTiltExpectation_ Stable-identifier warnings for every failed verdict.
%   Identifiers (same from the real routine and the mock):
%     ...:noPlane               plane fit failed, nothing to compare
%     ...:grooveComponent       tilt has a groove-axis component (RED FLAG)
%     ...:tiltMismatch          dispersion tilt far from design magnitude
%     ...:tiltSign              tilt runs the other way (usually benign, %VERIFY)
%     ...:depthWalkExceedsFwhm  field is not one focal plane (expected here)
if ~chk.valid
    warning('tfp:calibration:measureFocalPlaneTilt:noPlane', ...
        ['The best-focus plane fit is not valid, so the focal-plane tilt could ' ...
         'not be compared against the design expectation. Check that enough ' ...
         'spots resolved a brightness peak inside the Z sweep.']);
    return
end

if ~chk.grooveComponentOK
    warning('tfp:calibration:measureFocalPlaneTilt:grooveComponent', ...
        ['GROOVE-AXIS TILT COMPONENT — check the mounting. Measured %.5g um ' ...
         'depth per um along the GROOVE axis (%.2f um of depth walk across the ' ...
         '%.0f um groove extent; tolerance %.2f um), which is %.0f%% of the ' ...
         'total gradient.\n' ...
         'The design tilt is ENTIRELY along the DISPERSION axis and has NO ' ...
         'groove-axis component: the temporal-focusing grating disperses along ' ...
         'one chip diagonal only, so it cannot produce a groove-axis tilt. ' ...
         'Objective field curvature contributes only ~%.2g um across the field ' ...
         'and does not explain it either.\n' ...
         'Suspect a mis-clocked DMD, a mis-mounted or mis-oriented grating, or ' ...
         'a tilted sample/film. Do not build depth targeting on this ' ...
         'measurement until it is understood.'], ...
        s.gradientGrooveUmPerUm, s.grooveWalkUm, e.grooveExtentUm, ...
        chk.grooveWalkToleranceUm, 100 * s.grooveFraction, e.fieldCurvatureUm);
end

if ~chk.tiltOK
    warning('tfp:calibration:measureFocalPlaneTilt:tiltMismatch', ...
        ['Measured DISPERSION-axis depth gradient is %.5g um/um (tilt %.3f deg), ' ...
         '%.2fx the design %.5g um/um (%.3f deg) — outside the +/-%.0f%% band. ' ...
         'The design numbers are intent, not calibration (handoff sec 9), so a ' ...
         'few percent is fine; a factor like this usually means the optics are ' ...
         'installed differently from the document (the periscope lens order is ' ...
         'the known unconfirmed item) or the Z sweep did not bracket best focus.'], ...
        s.gradientDispersionUmPerUm, s.tiltDispersionDeg, chk.gradientRatio, ...
        e.depthGradientUmPerUm, e.tiltAngleFromGradientDeg, ...
        100 * chk.gradientToleranceFrac);
end

if ~chk.signMatchesDesign && chk.tiltOK
    warning('tfp:calibration:measureFocalPlaneTilt:tiltSign', ...
        ['Depth increases along %+d on the dispersion axis, the design config ' ...
         'says %+d (dmd.depthGradientSign). That key is an unresolved bench ' ...
         'convention (%%VERIFY), so this is most likely just the sign being ' ...
         'settled by measurement — set dmd.depthGradientSign = %+d in the rig ' ...
         'config so downstream depth compensation runs the right way.'], ...
        sign(s.gradientDispersionUmPerUm), e.depthGradientSign, ...
        sign(s.gradientDispersionUmPerUm));
end

if chk.depthWalkExceedsFwhm
    warning('tfp:calibration:measureFocalPlaneTilt:depthWalkExceedsFwhm', ...
        ['THE FIELD IS NOT ONE FOCAL PLANE. Best focus walks %.1f um in depth ' ...
         'across the patch, which is %.2f of the %.1f um axial FWHM. Two ' ...
         'targets at opposite edges of the field are therefore NOT in the same ' ...
         'plane, and a single objective Z cannot put both in focus.\n' ...
         'On this build that is expected, not a fault: there is no PLM, so the ' ...
         'tilt cannot be corrected optically. Apply a per-target depth offset ' ...
         'z_um = x_disp * %.5g, or keep an ensemble inside one axial FWHM ' ...
         '(about %.0f um along the dispersion axis).'], ...
        s.depthWalkAcrossPatchUm, chk.walkInAxialFwhm, e.axialFwhmUm, ...
        s.gradientDispersionUmPerUm, ...
        e.axialFwhmUm / max(abs(s.gradientDispersionUmPerUm), eps));
end
end

function report = tiltReport_(s, e, chk)
%tiltReport_ Experimenter-facing text: the comparison, and what it MEANS.
%   Returned as a field (calib.report) rather than printed, so it is
%   assertable; the callers print it only when asked to.
L = {};
L{end+1} = 'Focal-plane tilt vs design expectation (docs/dmd_control_handoff.md sec 6)';
L{end+1} = '-----------------------------------------------------------------------';
if ~s.valid
    L{end+1} = '  Plane fit invalid — no comparison possible.';
    report = strjoin(L, newline);
    return
end
L{end+1} = sprintf('  %-34s %12s %12s', '', 'measured', 'design');
L{end+1} = sprintf('  %-34s %12.5f %12.5f   um depth per um', ...
    'gradient, DISPERSION axis', s.gradientDispersionUmPerUm, ...
    e.depthGradientSign * e.depthGradientUmPerUm);
L{end+1} = sprintf('  %-34s %12.5f %12.5f   um depth per um', ...
    'gradient, GROOVE axis', s.gradientGrooveUmPerUm, e.grooveGradientUmPerUm);
L{end+1} = sprintf('  %-34s %12.3f %12.3f   deg', ...
    'surface tilt', s.tiltAngleDeg, e.tiltAngleDeg);
L{end+1} = sprintf('  %-34s %12.5f %12.5f   um per DMD px', ...
    'along the (1,1) dispersion diagonal', s.dispersionDiagonalUmPerPx, ...
    e.depthGradientSign * e.diagonalUmPerDmdPx);
L{end+1} = sprintf('  %-34s %12.5f %12.5f   um per DMD px', ...
    'along the (1,-1) groove diagonal', s.grooveDiagonalUmPerPx, 0);
L{end+1} = sprintf('  %-34s %12.1f %12.1f   um', ...
    'depth walk across the patch', s.depthWalkAcrossPatchUm, e.depthWalkAcrossPatchUm);
L{end+1} = sprintf('  %-34s %12.1f %12.1f   um', ...
    'axial FWHM', e.axialFwhmUm, e.axialFwhmUm);
L{end+1} = sprintf('  %-34s %12.2f %12.2f', ...
    'walk / axial FWHM', chk.walkInAxialFwhm, e.walkInAxialFwhm);
L{end+1} = '';

% --- in words -----------------------------------------------------------
L{end+1} = '  IN WORDS:';
if chk.depthWalkExceedsFwhm
    L{end+1} = sprintf(['    The field is NOT one focal plane. Best focus walks %.1f um ' ...
        'in depth across'], s.depthWalkAcrossPatchUm);
    L{end+1} = sprintf(['    the patch, comparable to the %.1f um axial FWHM (%.2f of ' ...
        'it). A target at one'], e.axialFwhmUm, chk.walkInAxialFwhm);
    L{end+1} =         '    edge of the field and a target at the other are genuinely NOT in the same';
    L{end+1} =         '    plane, and no single objective Z brings both into focus. There is no PLM';
    L{end+1} =         '    on this build, so this cannot be corrected optically — apply a per-target';
    L{end+1} = sprintf(['    depth offset z_um = x_disp * %.5g, or keep an ensemble within about ' ...
        '%.0f um'], s.gradientDispersionUmPerUm, ...
        e.axialFwhmUm / max(abs(s.gradientDispersionUmPerUm), eps));
    L{end+1} =         '    along the dispersion axis.';
else
    L{end+1} = sprintf(['    Depth walk across the patch is %.1f um, only %.2f of the %.1f um axial ' ...
        'FWHM,'], s.depthWalkAcrossPatchUm, chk.walkInAxialFwhm, e.axialFwhmUm);
    L{end+1} =         '    so the whole field can be treated as one focal plane.';
end
L{end+1} = '';
if chk.grooveComponentOK
    L{end+1} =         '    The tilt is along the dispersion axis, as designed: the groove-axis';
    L{end+1} = sprintf(['    walk is %.2f um (tolerance %.2f um), consistent with the ~%.2g um the ' ...
        'objective''s field'], s.grooveWalkUm, chk.grooveWalkToleranceUm, e.fieldCurvatureUm);
    L{end+1} =         '    curvature contributes.';
else
    L{end+1} =         '    RED FLAG — the tilt has a GROOVE-AXIS COMPONENT, which the design has none';
    L{end+1} = sprintf(['    of. It walks %.2f um along the groove axis (%.0f%% of the total ' ...
        'gradient),'], s.grooveWalkUm, 100 * s.grooveFraction);
    L{end+1} = sprintf(['    far beyond the ~%.2g um objective field curvature can explain. The ' ...
        'grating'], e.fieldCurvatureUm);
    L{end+1} =         '    disperses along ONE chip diagonal, so it cannot produce this: suspect a';
    L{end+1} =         '    mis-clocked DMD, a mis-mounted grating, or a tilted sample/film.';
end
if ~chk.tiltOK
    L{end+1} = '';
    L{end+1} = sprintf(['    The dispersion-axis gradient is %.2fx the design value — outside the ' ...
        '+/-%.0f%%'], chk.gradientRatio, 100 * chk.gradientToleranceFrac);
    L{end+1} =         '    band. The design numbers are intent, not calibration; check the optics';
    L{end+1} =         '    against the handoff (the periscope lens order is the known unknown).';
end
report = strjoin(L, newline);
end

function value = configField(s, name, default)
%configField Repo-standard config/options read with a fallback.
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    value = s.(name);
else
    value = default;
end
end
% =========================================================================
% END SHARED TILT-EXPECTATION BLOCK
% =========================================================================
