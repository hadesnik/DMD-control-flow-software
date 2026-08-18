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
%       .nGridPoints  — grid points per axis, must be odd (default 5)
%       .gridSpacing  — spacing in DMD pixels. Default is DERIVED so the
%                       grid's CORNER spots stay inside the illuminated
%                       patch (see below); ~77 px for a O463 px patch.
%       .spotRadius   — spot radius in DMD pixels (default 8)
%       .exposureS    — pause after each advanceToPattern before snap (default 0.1)
%       .showFigure   — show diagnostic figure after fit (default true)
%       .umPerPixel   — imaging pixel size at sample plane in µm (default 1.56)
%       .notes        — char note appended to calib.notes
%       .stagePositionUm — 1×3 [x y z] position of the sample-mount stage
%                      (tfp.hardware.MP285ZStage.getPositionXYZUm) at
%                      calibration time; default [] (no stage / objective
%                      mount). Any XY move after this stamp translates the
%                      affine — composeCalibration warns when the DMD and
%                      scan fits carry different stamps.
%
%   Output calibration struct:
%     .dmdToSample_affine  — 3×3: [x;y;1] = A * [u;v;1], DMD→camera px
%     .umPerPixel          — passed through from options
%     .pixelsPerUm         — 1/umPerPixel
%     .powerCurve          — empty struct (filled by powerMeterSweep)
%     .timestamp           — datetime('now')
%     .notes               — string
%     .residualErrorPx     — RMS residual in camera pixels
%     .nCalibrationPoints  — nGridPoints^2
%     .stagePositionUm     — echo of the option ([] when not provided)
%
%   Requires: Image Processing Toolbox (graythresh, bwconncomp, regionprops).

if nargin < 3
    options = struct();
end

nGridPoints = configField(options, 'nGridPoints', 5);
spotRadius  = configField(options, 'spotRadius',  8);

% Grid spacing is DERIVED from the illuminated patch, not a fixed 100 px.
% The grid is square but the patch is a disc, so the CORNER points set the
% limit: they sit at half*spacing*sqrt(2) from centre. With the old fixed
% 100 px default and a O463 px patch, the four corners landed 59 px outside
% it -- in the Gaussian tail or unlit -- so the affine was being fitted
% against spots that were dim, distorted, or missing at exactly the field
% edge where the fit needs them most. Deriving it means the next handoff
% regeneration cannot silently reintroduce that.
half = floor(nGridPoints / 2);
defaultSpacing = 100;
if half > 0
    try
        hc = tfp.util.readHandoffConstants();
        patchR = double(hc.patch_diameter_px) / 2;
        % Keep the whole spot inside, with a few px of margin for centroiding.
        defaultSpacing = floor((patchR - spotRadius - 5) / (half * sqrt(2)));
        defaultSpacing = max(10, defaultSpacing);
    catch
        % No handoff (bare checkout / mock test): keep the historical value.
        defaultSpacing = 100;
    end
end
gridSpacing = configField(options, 'gridSpacing', defaultSpacing);
exposureS   = configField(options, 'exposureS',   0.1);
showFigure  = logical(configField(options, 'showFigure', true));
umPerPixel  = configField(options, 'umPerPixel',  1.56);
notes       = configField(options, 'notes',       'DMD-to-camera calibration');
stagePosUm  = configField(options, 'stagePositionUm', []);

% --- validate ---
if ~isnumeric(nGridPoints) || ~isscalar(nGridPoints) || nGridPoints < 3 || mod(nGridPoints,2) == 0
    error('tfp:calibration:alignDMDtoCamera:badOptions', ...
        'options.nGridPoints must be an odd integer >= 3; got %g.', nGridPoints);
end
if ~isempty(stagePosUm)
    if ~isnumeric(stagePosUm) || numel(stagePosUm) ~= 3 || ~all(isfinite(stagePosUm))
        error('tfp:calibration:alignDMDtoCamera:badStagePosition', ...
            'options.stagePositionUm must be a 1x3 finite [x y z] in um (or []).');
    end
    stagePosUm = double(stagePosUm(:)');
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

% --- build and load pattern sequence ---
patterns = false(dmd.nRows, dmd.nCols, nPts);
for k = 1:nPts
    patterns(:,:,k) = tfp.patterns.singleSpot(dmd, dmdPts(k,:), spotRadius);
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
calib.umPerPixel         = umPerPixel;
calib.pixelsPerUm        = 1 / umPerPixel;
calib.powerCurve         = struct();
calib.timestamp          = datetime('now');
calib.notes              = notes;
calib.residualErrorPx    = calib_fit.residualErrorPx;
calib.nCalibrationPoints = nPts;
calib.stagePositionUm    = stagePosUm;   % [] unless a sample-mount stage is in use
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
