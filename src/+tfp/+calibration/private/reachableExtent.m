function ext = reachableExtent(dmdPts, reachable, activeBoxDmd, dmdToScan_affine, scanFieldBox)
%reachableExtent Describe the illuminated DMD extent, optionally in scan-field coords.
%   Shared private helper for measureIlluminationUniformity and its _mock.
%
%   dmdPts           : nPts×2 grid points [col row] in DMD pixels.
%   reachable        : nPts×1 logical (true inside the illuminated footprint).
%   activeBoxDmd     : 4×2 corners of the nominal active region [col row].
%   dmdToScan_affine : 3×3 DMD→scan-field affine, or [] to skip scan-field mapping.
%   scanFieldBox     : [xmin ymin xmax ymax] imaging FOV in scan-field coords,
%                      or [] to skip the coverage fraction.
%
%   Returns:
%     .reachableHullDmd   - K×2 convex hull (closed loop) of reachable spots (DMD px)
%     .activeBoxDmd       - passthrough of the nominal active box
%     .reachableHullScan  - hull mapped to scan-field coords ([] if no affine)
%     .activeBoxScan      - active box mapped to scan-field coords ([] if no affine)
%     .coverageFraction   - area(hull ∩ FOV) / area(FOV) in scan-field coords,
%                           or NaN if not computable
%     .scanFieldBox       - passthrough (or [])
%
%   The scan-field coordinate convention is whatever dmdToScan_affine outputs.
%   With the two-step calibration, dmdToScan maps DMD px → ScanImage scan-field
%   *pixel* coords, so scanFieldBox is naturally [0.5 0.5 nFast+0.5 nSlow+0.5].
%   %VERIFY on the rig that the calibration scan-field pixel grid matches the
%   imaging FOV used during experiments before trusting coverageFraction.

if nargin < 4, dmdToScan_affine = []; end
if nargin < 5, scanFieldBox = []; end

reachable = logical(reachable(:));
pts = dmdPts(reachable, :);

ext.reachableHullDmd  = [];
ext.activeBoxDmd      = activeBoxDmd;
ext.reachableHullScan = [];
ext.activeBoxScan     = [];
ext.coverageFraction  = NaN;
ext.scanFieldBox      = scanFieldBox;

% Convex hull of the reachable spots (needs >= 3 non-collinear points).
if size(pts, 1) >= 3
    try
        k = convhull(pts(:,1), pts(:,2));   % closed loop of vertex indices
        ext.reachableHullDmd = pts(k, :);
    catch
        ext.reachableHullDmd = [];          % collinear / degenerate
    end
end

% Map the extent into scan-field coordinates when an affine is supplied.
if ~isempty(dmdToScan_affine)
    ext.activeBoxScan = applyAffine(dmdToScan_affine, activeBoxDmd);
    if ~isempty(ext.reachableHullDmd)
        ext.reachableHullScan = applyAffine(dmdToScan_affine, ext.reachableHullDmd);
    end
end

% Coverage fraction: area(reachable hull ∩ FOV) / area(FOV), in scan-field coords.
if ~isempty(ext.reachableHullScan) && ~isempty(scanFieldBox)
    fovCorners = [scanFieldBox(1) scanFieldBox(2); ...
                  scanFieldBox(3) scanFieldBox(2); ...
                  scanFieldBox(3) scanFieldBox(4); ...
                  scanFieldBox(1) scanFieldBox(4)];
    ws      = warning('off', 'MATLAB:polyshape:repairedBySimplify');
    cleaner = onCleanup(@() warning(ws)); %#ok<NASGU>
    hullPoly  = polyshape(ext.reachableHullScan(:,1), ext.reachableHullScan(:,2));
    fovPoly   = polyshape(fovCorners(:,1), fovCorners(:,2));
    interPoly = intersect(hullPoly, fovPoly);
    fovArea   = area(fovPoly);
    if fovArea > 0
        ext.coverageFraction = area(interPoly) / fovArea;
    end
end
end

% =========================================================================
function xy = applyAffine(A, pts)
%applyAffine Apply a 3×3 affine to N×2 points using the column-vector convention.
n   = size(pts, 1);
hom = A * [pts, ones(n,1)]';   % 3×N
xy  = hom(1:2, :)';            % N×2
end
