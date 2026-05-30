function calib = crossRegisterScanImage(camera, dmdCalib, options)
%crossRegisterScanImage  Substage-camera → ScanImage scan-field cross-registration.
%   Part 2 of the two-step spatial calibration. Part 1 (alignDMDtoCamera)
%   maps DMD pixels → substage-camera pixels. This function maps ScanImage
%   scan-field pixel coordinates → substage-camera pixels, enabling the
%   full DMD → ScanImage scan-field affine by composition.
%
%   dmdCalib is optional. Omit it (or pass []) to run Step B alone — useful
%   when the DMD is not yet aligned. The output will contain scanToCam_affine
%   but dmdToScan_affine will be identity (placeholder). Re-run
%   composeDmdToScan(calib, dmdCalib) later to fill in the full affine once
%   alignDMDtoCamera has been completed.
%
%   OPERATOR PREREQUISITE:
%     Before calling this function the operator must:
%       1. Place a thin fluorescent film on the sample stage.
%       2. Start ScanImage in Focus mode with a NON-SQUARE pixel count
%          matching options.scanPixels, e.g. 512 pixels × 256 lines.
%          The resonant (fast) axis must have MORE pixels than the galvo
%          (slow) axis so the camera sees a non-square bright rectangle;
%          the longer camera dimension = fast (resonant) axis.
%       3. Confirm the scan rectangle is bright and in focus on the camera.
%
%   AXIS SIGN NOTE:
%     The rectangle on the camera does not reveal which end of each scan
%     axis is "positive" in ScanImage scan-field convention. After running
%     this function, perform the verify step described in CLAUDE.md:
%       1. Project a DMD spot at a known coordinate.
%       2. Predict its scan-field position using dmdToScan_affine.
%       3. Command a small ScanImage mROI there; confirm visually.
%       4. If off, flip scan_fast_axis_sign and/or scan_slow_axis_sign.
%       5. Write confirmed signs into the rig config YAML.
%
%   calib = crossRegisterScanImage(camera)
%   calib = crossRegisterScanImage(camera, dmdCalib)
%   calib = crossRegisterScanImage(camera, dmdCalib, options)
%   calib = crossRegisterScanImage(camera, [], options)
%
%   Inputs:
%     camera    - tfp.hardware.SubstageCamera-derived, already initialized.
%     dmdCalib  - calibration struct from alignDMDtoCamera containing
%                 .dmdToSample_affine (3x3). Pass [] to skip composition.
%     options   - optional struct:
%       .scanPixels  — [nFast nSlow] matching ScanImage pixel count;
%                      nFast must be > nSlow (default [512 256])
%       .threshFrac  — threshold as fraction of frame peak for rectangle
%                      detection (default 0.3); decrease for dim signal
%       .showFigure  — display diagnostic figure (default true)
%       .notes       — char string appended to calib.notes
%
%   Output calib:
%     .scanToCam_affine      3x3: [x;y;1] = A * [fast;slow;1].
%     .dmdToScan_affine      3x3: composed from dmdCalib (eye(3) if omitted).
%     .scanPixels            [nFast nSlow] echo.
%     .scan_fast_axis_sign   NaN — set empirically after verify step.
%     .scan_slow_axis_sign   NaN — set empirically after verify step.
%     .rectBboxPx            [xmin ymin width height] detected bounding box.
%     .fastAxisIsHorizontal  logical; true when fast axis is wider on cam.
%     .timestamp             datetime('now').
%     .notes                 updated note string.
%
%   Requires: Image Processing Toolbox (bwconncomp, regionprops, imclose,
%   imopen).

if nargin < 2, dmdCalib = []; end
if nargin < 3, options  = struct(); end

scanPixels = configField(options, 'scanPixels', [512, 256]);
threshFrac = configField(options, 'threshFrac', 0.3);
showFigure = logical(configField(options, 'showFigure', true));
notes      = configField(options, 'notes', 'ScanImage cross-registration');

% --- validate ---
if ~isnumeric(scanPixels) || numel(scanPixels) ~= 2 || any(scanPixels < 1)
    error('tfp:calibration:crossRegisterScanImage:badOptions', ...
        'options.scanPixels must be [nFast nSlow], both positive integers.');
end
nFast = scanPixels(1);
nSlow = scanPixels(2);
if nFast <= nSlow
    error('tfp:calibration:crossRegisterScanImage:badPixelCount', ...
        ['options.scanPixels(1) (nFast=%d) must exceed scanPixels(2) (nSlow=%d). ' ...
         'Set ScanImage with more pixels per line than lines, e.g. 512x256.'], ...
        nFast, nSlow);
end
hasDmdCalib = ~isempty(dmdCalib);
if hasDmdCalib && ~isfield(dmdCalib, 'dmdToSample_affine')
    error('tfp:calibration:crossRegisterScanImage:missingDmdCalib', ...
        'dmdCalib must contain .dmdToSample_affine (run alignDMDtoCamera first).');
end
if ~isa(camera, 'tfp.hardware.SubstageCamera')
    error('tfp:calibration:crossRegisterScanImage:badCamera', ...
        'camera must be a tfp.hardware.SubstageCamera; got %s.', class(camera));
end
if ~camera.isInitialized
    error('tfp:calibration:crossRegisterScanImage:cameraNotInit', ...
        'camera must be initialized before calling crossRegisterScanImage.');
end

% --- snap and detect rectangle ---
fprintf('[crossRegisterScanImage] Snapping substage camera...\n');
frame = camera.snap();

[bbox, fastIsHoriz] = detectScanRectangle(frame, nFast, nSlow, threshFrac);
fprintf('[crossRegisterScanImage] Bounding box [xmin ymin w h]: %.1f %.1f %.1f %.1f px\n', ...
    bbox(1), bbox(2), bbox(3), bbox(4));
fprintf('[crossRegisterScanImage] Fast axis orientation: %s\n', ...
    ternary(fastIsHoriz, 'horizontal', 'vertical'));

% --- build corner correspondences and fit affine ---
[scanPts, camPts] = buildCornerCorrespondences(bbox, nFast, nSlow, fastIsHoriz);
calib_fit = fitAffineCalib(scanPts, camPts, []);

scanToCam = calib_fit.dmdToSample_affine;   % reuses helper; 'dmd' = scan here
if hasDmdCalib
    dmdToCam  = dmdCalib.dmdToSample_affine;
    dmdToScan = inv(scanToCam) * dmdToCam;  %#ok<MINV> small 3x3, explicit ok
else
    dmdToScan = eye(3);  % placeholder — recompose after alignDMDtoCamera
    fprintf('[crossRegisterScanImage] dmdCalib omitted: dmdToScan_affine is identity.\n');
    fprintf('  Run composeDmdToScan(calib, dmdCalib) after alignDMDtoCamera.\n');
end

% --- assemble output ---
if hasDmdCalib
    calib = dmdCalib;
else
    calib = struct();
end
calib.scanToCam_affine    = scanToCam;
calib.dmdToScan_affine    = dmdToScan;
calib.scanPixels          = [nFast, nSlow];
calib.scan_fast_axis_sign = NaN;
calib.scan_slow_axis_sign = NaN;
calib.rectBboxPx          = bbox;
calib.fastAxisIsHorizontal = fastIsHoriz;
calib.timestamp           = datetime('now');
if isfield(calib, 'notes') && ~isempty(calib.notes)
    calib.notes = [calib.notes '; ' notes];
else
    calib.notes = notes;
end

if showFigure
    plotCrossRegDiagnostic(frame, bbox, scanPts, camPts, ...
        calib_fit.imgPtsPredicted, fastIsHoriz, nFast, nSlow);
end

printVerifyInstructions(dmdToScan);
end

% =========================================================================
% Local functions
% =========================================================================

function [bbox, fastIsHoriz] = detectScanRectangle(frame, nFast, nSlow, threshFrac)
%detectScanRectangle  Threshold, find largest blob, return axis-aligned bbox.
%   bbox = [xmin ymin width height] in MATLAB BoundingBox units (where
%   pixel (c,r) has its left edge at x = c-0.5 in BoundingBox notation).
%   fastIsHoriz: true when bbox width >= bbox height (fast axis horizontal).

thresh = threshFrac * max(frame(:));
if thresh <= 0
    error('tfp:calibration:crossRegisterScanImage:darkFrame', ...
        ['Camera frame is uniformly dark. Check that ScanImage is running ' ...
         'in Focus mode and the fluorescent film is illuminated.']);
end
mask = frame > thresh;

% Morphological cleanup: close small gaps, remove noise speckle.
mask = imclose(mask, strel('disk', 3));
mask = imopen(mask,  strel('disk', 1));

cc = bwconncomp(mask);
if cc.NumObjects == 0
    error('tfp:calibration:crossRegisterScanImage:noBlob', ...
        ['No bright region found at threshold %.2f * peak. ' ...
         'Check ScanImage Focus mode and film focus. ' ...
         'Try lowering options.threshFrac (current: %.2f).'], threshFrac, threshFrac);
end

nPx       = cellfun(@numel, cc.PixelIdxList);
[~, iMax] = max(nPx);
singleCC  = false(size(mask));
singleCC(cc.PixelIdxList{iMax}) = true;

props = regionprops(singleCC, 'BoundingBox');
bbox  = props.BoundingBox;   % [xmin ymin width height]

detectedAspect = max(bbox(3), bbox(4)) / min(bbox(3), bbox(4));
expectedAspect = nFast / nSlow;
if abs(detectedAspect - expectedAspect) / expectedAspect > 0.5
    warning('tfp:calibration:crossRegisterScanImage:aspectMismatch', ...
        ['Detected rectangle aspect ratio %.2f does not match scan pixel ' ...
         'ratio nFast/nSlow = %.2f. Verify ScanImage is running with ' ...
         '%d pixels x %d lines and options.scanPixels matches.'], ...
        detectedAspect, expectedAspect, nFast, nSlow);
end

% Fast axis = longer camera dimension (more scan pixels → wider sweep).
fastIsHoriz = (bbox(3) >= bbox(4));
end

function [scanPts, camPts] = buildCornerCorrespondences(bbox, nFast, nSlow, fastIsHoriz)
%buildCornerCorrespondences  Map scan-field pixel corners to camera bbox corners.
%   Nominal convention: scan (1,1) → camera bbox top-left, increasing
%   fast index → increasing x (if horizontal) or increasing y (if vertical).
%   This is the nominal assumption; the verify step confirms actual signs.
%
%   BoundingBox corner convention: (xmin,ymin) is the top-left corner of
%   the bounding box (left edge of leftmost pixel, top edge of topmost row).

xmin = bbox(1);   ymin = bbox(2);
w    = bbox(3);   h    = bbox(4);

if fastIsHoriz
    % fast → camera x, slow → camera y
    scanPts = [1      nFast  nFast  1;
               1      1      nSlow  nSlow]';
    camPts  = [xmin    xmin+w  xmin+w  xmin;
               ymin    ymin    ymin+h  ymin+h]';
else
    % fast → camera y, slow → camera x
    scanPts = [1      nFast  nFast  1;
               1      1      nSlow  nSlow]';
    camPts  = [xmin    xmin    xmin+w  xmin+w;
               ymin    ymin+h  ymin+h  ymin]';
end
end

function plotCrossRegDiagnostic(frame, bbox, scanPts, camPts, camPred, ...
                                fastIsHoriz, nFast, nSlow)
figure('Name', 'ScanImage Cross-Registration', 'NumberTitle', 'off', ...
    'Position', [80 80 1100 480]);

subplot(1,2,1);
imshow(frame, []);
hold on;
rectangle('Position', bbox, 'EdgeColor', 'r', 'LineWidth', 2);
scatter(camPts(:,1), camPts(:,2), 60, 'y', 'filled', 'DisplayName', 'Detected corners');
scatter(camPred(:,1), camPred(:,2), 60, 'g', '+', 'LineWidth', 2, ...
    'DisplayName', 'Affine-predicted');
legend('Location', 'southeast', 'TextColor', 'w');
title(sprintf('Camera frame (fast axis %s)', ternary(fastIsHoriz, '↔ horiz', '↕ vert')));

subplot(1,2,2);
hold on;
scatter(scanPts(:,1), scanPts(:,2), 80, 'b', 'filled');
for k = 1:size(scanPts, 1)
    text(scanPts(k,1) + nFast*0.01, scanPts(k,2) + nSlow*0.02, ...
        sprintf('(%d,%d)', scanPts(k,1), scanPts(k,2)), 'Color', 'b', 'FontSize', 9);
end
xlim([0 nFast + 1]); ylim([0 nSlow + 1]);
xlabel('Fast axis (px)'); ylabel('Slow axis (px)');
title(sprintf('Scan-field corners  (%d × %d px)', nFast, nSlow));
set(gca, 'YDir', 'reverse');
axis equal; grid on;
end

function printVerifyInstructions(dmdToScan)
fprintf('\n[crossRegisterScanImage] ======= VERIFY STEP REQUIRED =======\n');
fprintf('scan_fast_axis_sign and scan_slow_axis_sign are NaN (unknown).\n');
fprintf('Determine axis signs empirically (≤4 attempts):\n');
fprintf('  1. Project a single DMD spot at a known coordinate [u, v].\n');
fprintf('  2. Compute predicted scan-field coordinate:\n');
fprintf('       dmdToScan_affine =\n');
fprintf('         [%.5f  %.5f  %.5f\n',  dmdToScan(1,:));
fprintf('          %.5f  %.5f  %.5f\n',  dmdToScan(2,:));
fprintf('          %.5f  %.5f  %.5f ]\n', dmdToScan(3,:));
fprintf('       p = dmdToScan_affine * [u; v; 1];\n');
fprintf('       predicted_fast = p(1),  predicted_slow = p(2)\n');
fprintf('  3. Command a small ScanImage mROI at that predicted coordinate.\n');
fprintf('  4. Confirm visually the spot is centred in the mROI live image.\n');
fprintf('  5. If not, flip scan_fast_axis_sign and/or scan_slow_axis_sign.\n');
fprintf('  6. Write confirmed signs into the rig config YAML:\n');
fprintf('       scan_fast_axis_sign: +1   # or -1\n');
fprintf('       scan_slow_axis_sign: +1   # or -1\n');
fprintf('[crossRegisterScanImage] =====================================\n\n');
end

function s = ternary(cond, a, b)
if cond, s = a; else, s = b; end
end

function value = configField(s, name, default)
if isfield(s, name)
    value = s.(name);
else
    value = default;
end
end
