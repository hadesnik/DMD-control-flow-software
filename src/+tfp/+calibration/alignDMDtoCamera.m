function calib = alignDMDtoCamera(dmd, camera, options)
%alignDMDtoCamera Live DMD-to-substage-camera spatial calibration.
%   Projects a grid of single spots on the DMD, captures each on the
%   substage widefield camera, detects spot centroids, and fits a 2D
%   affine transform: DMD pixel [col,row] → camera pixel [x,y].
%
%   calib = alignDMDtoCamera(dmd, camera)
%   calib = alignDMDtoCamera(dmd, camera, options)
%
%   IMPORTANT — imaging constraint:
%     ScanImage uses a PMT point detector and cannot image DMD spots.
%     The 'camera' argument must be a tfp.hardware.SubstageCamera (real or
%     mock), not ScanImage. This function produces a DMD → substage-camera
%     affine. A separate cross-registration step (substage camera ↔
%     ScanImage scan coordinates) is needed to complete the DMD → sample
%     mapping; that step is not yet implemented.
%
%   Inputs:
%     dmd    - tfp.hardware.DMD-derived object. Must already be initialised.
%     camera - tfp.hardware.SubstageCamera-derived object. Must already be
%              initialised.
%     options - optional struct:
%       .nGridPoints     — grid points per axis, must be odd (default 5)
%       .gridSpacing     — spacing in DMD pixels (default 100)
%       .spotDiameterUm  — calibration-spot DIAMETER at the SAMPLE plane, µm
%                          (default 20). See "spot sizing" below.
%       .spotRadius      — DEPRECATED. Spot radius in DMD pixels. When given it
%                          overrides .spotDiameterUm and draws the historical
%                          isotropic pixel circle, so old callers are
%                          unchanged. Prefer .spotDiameterUm.
%       .exposureS       — pause after each advanceToPattern before snap (default 0.1)
%       .showFigure      — show diagnostic figure after fit (default true)
%       .cameraUmPerPixel — camera pixel size at the sample plane in µm
%                          (default 1.56). Legacy alias: .umPerPixel.
%       .notes           — char note appended to calib.notes
%
%   SPOT SIZING. The old default was a bare `spotRadius = 8` DMD pixels,
%   picked against a pre-optics guess of 0.270 µm/px. At the real bring-up
%   scale (1.1250 µm/px along the grooves, 1.4162 µm/px along dispersion, chip
%   clocked 45°) that is a ~18 × 23 µm ellipse at the sample, not the ~4 µm
%   dot it reads as. Calibration spots do NOT have to be soma-sized — they
%   want to be bright and cleanly centroidable — but they DO have to state
%   what size they are, so the size is now given in sample µm and converted by
%   tfp.patterns.somaSpotGeometry. The default 20 µm keeps the historical
%   ~8 px pixel budget while making the intent explicit, and the spot is drawn
%   anisotropically so the camera sees a ROUND spot.
%
%   Output calibration struct:
%     .dmdToSample_affine  — 3×3: [x;y;1] = A * [u;v;1], DMD→camera px.
%                            NOTE the name is a misnomer: the right-hand side
%                            is CAMERA pixels, not sample µm. Renaming it is
%                            deferred to the first calibration run
%                            (TASKS.md T-BU-M0); do not feed it to
%                            tfp.patterns.sampleToDmdOffset.
%     .cameraUmPerPixel    — passed through from options
%     .cameraPixelsPerUm   — 1/cameraUmPerPixel, in CAMERA pixels per µm
%     .umPerPixel          — DEPRECATED alias of .cameraUmPerPixel
%     .pixelsPerUm         — DEPRECATED alias of .cameraPixelsPerUm. It was
%                            read elsewhere in the repo as DMD px per µm
%                            (a ~5.8× error); the camera-prefixed names exist
%                            so the two can never be confused again. See
%                            tfp.patterns.ppsfPattern.
%     .spotDiameterUm      — sample-plane diameter actually used, or NaN when a
%                            deprecated .spotRadius was supplied
%     .spotGeometry        — the tfp.patterns.somaSpotGeometry struct, or []
%     .powerCurve          — empty struct (filled by powerMeterSweep)
%     .timestamp           — datetime('now')
%     .notes               — string
%     .residualErrorPx     — RMS residual in camera pixels
%     .nCalibrationPoints  — nGridPoints^2
%
%   Requires: Image Processing Toolbox (graythresh, bwconncomp, regionprops).

if nargin < 3
    options = struct();
end

nGridPoints = configField(options, 'nGridPoints', 5);
gridSpacing = configField(options, 'gridSpacing', 100);
exposureS   = configField(options, 'exposureS',   0.1);
showFigure  = logical(configField(options, 'showFigure', true));
% Camera pixel size at the sample plane. `umPerPixel` is the legacy key name;
% the camera-prefixed one says which plane it belongs to.
cameraUmPerPixel = configField(options, 'cameraUmPerPixel', ...
                       configField(options, 'umPerPixel', 1.56));
notes       = configField(options, 'notes',       'DMD-to-camera calibration');

% Spot sizing: ask in sample µm (see the header). A supplied .spotRadius is the
% deprecated pixel-count form and still wins, so existing callers/tests are
% byte-identical.
spotDiameterUm = configField(options, 'spotDiameterUm', 20);   %ASSUMED bright, easily centroidable
legacyRadiusPx = configField(options, 'spotRadius', []);
% Optics constants for the µm -> DMD-px conversion. Anything
% tfp.util.opticalModel accepts (a full config, or a bare dmd sub-struct);
% omit for the documented design defaults.
opticalConfig  = configField(options, 'opticalConfig', struct());

% --- validate ---
if ~isnumeric(nGridPoints) || ~isscalar(nGridPoints) || nGridPoints < 3 || mod(nGridPoints,2) == 0
    error('tfp:calibration:alignDMDtoCamera:badOptions', ...
        'options.nGridPoints must be an odd integer >= 3; got %g.', nGridPoints);
end
if ~isa(camera, 'tfp.hardware.SubstageCamera')
    error('tfp:calibration:alignDMDtoCamera:badCamera', ...
        'camera must be a tfp.hardware.SubstageCamera; got %s.', class(camera));
end
if ~camera.isInitialized
    error('tfp:calibration:alignDMDtoCamera:cameraNotInitialized', ...
        'camera must be initialized before calling alignDMDtoCamera.');
end
if ~dmd.isInitialized
    error('tfp:calibration:alignDMDtoCamera:dmdNotInitialized', ...
        'dmd must be initialized before calling alignDMDtoCamera.');
end

nPts = nGridPoints^2;

% --- build grid of DMD coordinates (row-major, col varies fastest) ---
half   = floor(nGridPoints / 2);
axis1d = (-half:half) * gridSpacing;
[colOff, rowOff] = meshgrid(axis1d, axis1d);
dmdCols = dmd.nCols/2 + colOff(:);
dmdRows = dmd.nRows/2 + rowOff(:);
dmdPts  = [dmdCols, dmdRows];              % nPts × 2

% --- spot geometry ---
% Preferred path: a stated sample-plane diameter -> anisotropic DMD ellipse, so
% the spot the camera sees is round. Per T-BU-1f the positional radius must be
% the GROOVE-axis (long) semi-axis and geom.spotOptions carries it explicitly;
% geom.radiusPx is the area-matched ISOTROPIC fallback and must not be mixed in
% here (it would paint ~17% fewer mirrors).
if isempty(legacyRadiusPx)
    spotGeom   = tfp.patterns.somaSpotGeometry(spotDiameterUm, opticalConfig);
    spotRadius = spotGeom.semiAxisGroovePx;
    spotOpts   = spotGeom.spotOptions;
else
    if ~isnumeric(legacyRadiusPx) || ~isscalar(legacyRadiusPx) ...
            || ~isfinite(legacyRadiusPx) || legacyRadiusPx <= 0
        error('tfp:calibration:alignDMDtoCamera:badOptions', ...
            'options.spotRadius must be a positive finite scalar.');
    end
    spotGeom       = [];
    spotRadius     = double(legacyRadiusPx);
    spotOpts       = struct();       % historical isotropic pixel circle
    spotDiameterUm = NaN;
end

% --- build and load pattern sequence ---
patterns = false(dmd.nRows, dmd.nCols, nPts);
for k = 1:nPts
    patterns(:,:,k) = tfp.patterns.singleSpot(dmd, dmdPts(k,:), spotRadius, spotOpts);
end
seqOpts.exposureUs  = round(exposureS * 1e6);
seqOpts.darkTimeUs  = 0;
dmd.loadPatternSequence(patterns, seqOpts);
dmd.armSequence();

% --- project each spot, snap camera, find centroid ---
imgPts = zeros(nPts, 2);
for k = 1:nPts
    dmd.advanceToPattern(k);
    if exposureS > 0
        pause(exposureS);
    end
    frame       = camera.snap();
    imgPts(k,:) = findSpotCentroid(frame, k);   % private helper
end

% --- fit affine and compute residuals ---
calib_fit = fitAffineCalib(dmdPts, imgPts, []);  % private helper

if showFigure
    plotCalibDiagnostic(dmdPts, imgPts, calib_fit.imgPtsPredicted, calib_fit.residualsPerPt);
end

calib.dmdToSample_affine = calib_fit.dmdToSample_affine;
% Canonical, plane-tagged names. Both quantities are CAMERA-plane.
calib.cameraUmPerPixel   = cameraUmPerPixel;
calib.cameraPixelsPerUm  = 1 / cameraUmPerPixel;
% DEPRECATED aliases, kept so existing rig configs and saved calibrations keep
% loading. `pixelsPerUm` in particular was read as DMD px/µm by ppsfPattern —
% a ~5.8x error. New code must use the camera-prefixed names above.
calib.umPerPixel         = cameraUmPerPixel;
calib.pixelsPerUm        = 1 / cameraUmPerPixel;
calib.spotDiameterUm     = spotDiameterUm;
calib.spotGeometry       = spotGeom;
calib.powerCurve         = struct();
calib.timestamp          = datetime('now');
calib.notes              = notes;
calib.residualErrorPx    = calib_fit.residualErrorPx;
calib.nCalibrationPoints = nPts;
end

% =========================================================================
% Local functions
% =========================================================================

function plotCalibDiagnostic(dmdPts, imgPts, imgPred, residuals)
figure('Name', 'DMD-to-Camera Calibration', 'NumberTitle', 'off');

subplot(1,2,1);
scatter(imgPts(:,1),  imgPts(:,2),  40, 'b', 'filled', 'DisplayName', 'Measured');
hold on;
scatter(imgPred(:,1), imgPred(:,2), 40, 'r', '+', 'LineWidth', 1.5, ...
    'DisplayName', 'Predicted');
legend('Location', 'best');
xlabel('Camera X (px)'); ylabel('Camera Y (px)');
title('Calibration points: measured vs predicted');
axis equal; grid on;

subplot(1,2,2);
scatter(dmdPts(:,1), dmdPts(:,2), 50, residuals, 'filled');
colorbar;
xlabel('DMD col (px)'); ylabel('DMD row (px)');
title(sprintf('Residuals (px)  —  RMS = %.3f', sqrt(mean(residuals.^2))));
axis equal; grid on;
end

function value = configField(s, name, default)
if isfield(s, name)
    value = s.(name);
else
    value = default;
end
end
