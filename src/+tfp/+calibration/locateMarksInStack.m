function found = locateMarksInStack(stack, ledger, calibration, options)
%locateMarksInStack Find burn/bleach marks in an ETL z-stack, per plane.
%
%   found = tfp.calibration.locateMarksInStack(stack, ledger, calibration)
%   found = tfp.calibration.locateMarksInStack(..., options)
%
%   Second half of the DIRECT z-calibration: after markFluorescentSlab,
%   the operator acquires an ETL multi-plane stack in ScanImage; each mark
%   appears as a DARK spot against the fluorescent slab, darkest in the
%   imaging plane closest to the depth where its defocused stimulation
%   focus burned/bleached. Mapping mark -> darkest plane gives the direct
%   dzCmd <-> ETL-plane correspondence, cross-checking the indirect
%   composition (tfp.calibration.verifyZCalibration).
%
%   stack:   EITHER a numeric array (nRows x nCols x nFrames, plane-
%            interleaved frames as ScanImage writes volumes) OR a char
%            path to a .tif/.mat readable by tfp.io.readScanImageTiff
%            (pixel data must then be loadable; for the sidecar path pass
%            the array directly).
%   ledger:  struct array from markFluorescentSlab (.dzCmdUm, .dmdCoords).
%   calibration: lateral calibration struct with .dmdToScan_affine — maps
%            each ledger mark's DMD coords to scan-field px so the search
%            window lands on the right image location.
%   options:
%     .nPlanes        — planes per volume (default config-free: 3)
%     .windowPx       — half-size of the search window around the
%                       predicted mark position (default 25)
%     .scanImageSize  — [nRows nCols] of a scan frame when `stack` path
%                       metadata can't provide it
%
%   found: struct array, one per ledger mark:
%     .dzCmdUm, .dmdCoords, .predictedScanPx [x y], .planeIdx (darkest),
%     .contrastByPlane (1 x nPlanes; mark darkness contrast per plane),
%     .depthUmFromPlanes (NaN unless a z-composed calibration is given in
%      options.zcal, then etlPlaneZUm(planeIdx))
%
%   Darkness contrast per plane = (annulus median - window centre mean),
%   normalised by the annulus median: positive when the mark is darker
%   than its surround.

if nargin < 4 || isempty(options)
    options = struct();
end
nPlanes  = double(tfp.util.configField(options, 'nPlanes', 3));
windowPx = double(tfp.util.configField(options, 'windowPx', 25));

if ischar(stack) || (isstring(stack) && isscalar(stack))
    error('tfp:calibration:locateMarksInStack:pathNotSupportedYet', ...
        ['Pass the stack as a numeric array (nRows x nCols x nFrames). ' ...
         'Reading pixel data straight from ScanImage TIFFs lands with ' ...
         'the rig verification pass — tfp.io.readScanImageTiff currently ' ...
         'reads metadata only.']);
end
if ~isnumeric(stack) || ndims(stack) ~= 3
    error('tfp:calibration:locateMarksInStack:badStack', ...
        'stack must be nRows x nCols x nFrames numeric.');
end
if ~isstruct(calibration) || ~isfield(calibration, 'dmdToScan_affine')
    error('tfp:calibration:locateMarksInStack:badCalibration', ...
        'calibration must carry dmdToScan_affine (composeCalibration output).');
end

nFrames = size(stack, 3);
if mod(nFrames, nPlanes) ~= 0
    warning('tfp:calibration:locateMarksInStack:partialVolume', ...
        '%d frames is not a whole number of %d-plane volumes; trailing frames ignored.', ...
        nFrames, nPlanes);
end

% Average all frames of each plane (frame k belongs to plane
% mod(k-1, nPlanes)+1 — the tfp.io.assignFramePlanes convention).
planeImgs = zeros(size(stack, 1), size(stack, 2), nPlanes);
for p = 1:nPlanes
    idx = p:nPlanes:nFrames;
    planeImgs(:, :, p) = mean(double(stack(:, :, idx)), 3);
end

A = calibration.dmdToScan_affine;
found = struct('dzCmdUm', {}, 'dmdCoords', {}, 'predictedScanPx', {}, ...
    'planeIdx', {}, 'contrastByPlane', {}, 'depthUmFromPlanes', {});

zcal = tfp.util.configField(options, 'zcal', []);

for m = 1:numel(ledger)
    dmdXY  = double(ledger(m).dmdCoords);
    pred   = A * [dmdXY(1); dmdXY(2); 1];
    px     = pred(1:2)';   % [x y] scan px

    contrast = nan(1, nPlanes);
    for p = 1:nPlanes
        contrast(p) = darknessContrast(planeImgs(:, :, p), px, windowPx);
    end
    [~, darkest] = max(contrast);

    rec.dzCmdUm         = ledger(m).dzCmdUm;
    rec.dmdCoords       = dmdXY;
    rec.predictedScanPx = px;
    rec.planeIdx        = darkest;
    rec.contrastByPlane = contrast;
    if ~isempty(zcal) && isfield(zcal, 'etlPlaneZUm')
        rec.depthUmFromPlanes = zcal.etlPlaneZUm(darkest);
    else
        rec.depthUmFromPlanes = NaN;
    end
    found(end+1) = rec; %#ok<AGROW>
end
end

% --- Local helper ---

function c = darknessContrast(img, centerXY, halfWin)
%darknessContrast (annulus median - centre mean) / annulus median.
[nR, nC] = size(img);
cx = round(centerXY(1)); cy = round(centerXY(2));
x1 = max(1, cx - halfWin);  x2 = min(nC, cx + halfWin);
y1 = max(1, cy - halfWin);  y2 = min(nR, cy + halfWin);
if x2 <= x1 || y2 <= y1
    c = NaN;   % predicted position off-frame
    return
end
inner = img(y1:y2, x1:x2);

ax1 = max(1, cx - 3 * halfWin);  ax2 = min(nC, cx + 3 * halfWin);
ay1 = max(1, cy - 3 * halfWin);  ay2 = min(nR, cy + 3 * halfWin);
outer = img(ay1:ay2, ax1:ax2);
annulusMask = true(size(outer));
annulusMask((y1 - ay1 + 1):(y2 - ay1 + 1), (x1 - ax1 + 1):(x2 - ax1 + 1)) = false;
bg = median(outer(annulusMask));

if bg <= 0
    c = NaN;
    return
end
c = (bg - mean(inner(:))) / bg;
end
