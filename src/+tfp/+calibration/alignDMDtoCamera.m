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
%       .gridSpacing  — spacing in DMD pixels (default 100)
%       .spotRadius   — spot radius in DMD pixels (default 8)
%       .exposureS    — pause after each advanceToPattern before snap (default 0.1)
%       .showFigure   — show diagnostic figure after fit (default true)
%       .umPerPixel   — imaging pixel size at sample plane in µm (default 1.56)
%       .notes        — char note appended to calib.notes
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
%
%   Requires: Image Processing Toolbox (graythresh, bwconncomp, regionprops).

if nargin < 3
    options = struct();
end

nGridPoints = configField(options, 'nGridPoints', 5);
gridSpacing = configField(options, 'gridSpacing', 100);
spotRadius  = configField(options, 'spotRadius',  8);
exposureS   = configField(options, 'exposureS',   0.1);
showFigure  = logical(configField(options, 'showFigure', true));
umPerPixel  = configField(options, 'umPerPixel',  1.56);
notes       = configField(options, 'notes',       'DMD-to-camera calibration');

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
    imgPts(k,:) = findSpotCentroid(frame, k);
end

% --- fit affine: DMD [col,row] → camera [x,y] ---
tform              = fitgeotrans(dmdPts, imgPts, 'affine');
dmdToSample_affine = extractAffineMatrix(tform);

% --- RMS residual ---
homDMD  = [dmdPts, ones(nPts,1)]';
imgPred = (dmdToSample_affine * homDMD)';
imgPred = imgPred(:, 1:2);
residuals   = sqrt(sum((imgPts - imgPred).^2, 2));
residualRMS = sqrt(mean(residuals.^2));

if showFigure
    plotCalibDiagnostic(dmdPts, imgPts, imgPred, residuals);
end

calib.dmdToSample_affine = dmdToSample_affine;
calib.umPerPixel         = umPerPixel;
calib.pixelsPerUm        = 1 / umPerPixel;
calib.powerCurve         = struct();
calib.timestamp          = datetime('now');
calib.notes              = notes;
calib.residualErrorPx    = residualRMS;
calib.nCalibrationPoints = nPts;
end

% =========================================================================
% Local functions
% =========================================================================

function centroid = findSpotCentroid(frame, frameIdx)
lo  = min(frame(:));
hi  = max(frame(:));
if hi <= lo
    error('tfp:calibration:alignDMDtoCamera:blankFrame', ...
        'Frame %d is blank (uniform intensity %.3g).', frameIdx, lo);
end
img = (frame - lo) / (hi - lo);

level = graythresh(img);
bw    = img > level;

cc    = bwconncomp(bw);
if cc.NumObjects == 0
    error('tfp:calibration:alignDMDtoCamera:noSpot', ...
        'No bright region found in frame %d (Otsu threshold %.3f).', ...
        frameIdx, level);
end

props    = regionprops(cc, 'Area', 'Centroid');
[~, idx] = max([props.Area]);
centroid = props(idx).Centroid;   % [x y] = [col row] in image coords
end

function A = extractAffineMatrix(tform)
% Both affinetform2d (R2022b+) and affine2d use row-vector convention:
%   [xo, yo, 1] = [xi, yi, 1] * T
% Ours is column-vector: [xo; yo; 1] = A * [xi; yi; 1]  →  A = T'
if isa(tform, 'affinetform2d')
    A = tform.A';
elseif isa(tform, 'affine2d')
    A = tform.T';
else
    error('tfp:calibration:alignDMDtoCamera:unsupportedTform', ...
        'Unrecognized fitgeotrans output type: %s.', class(tform));
end
end

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
