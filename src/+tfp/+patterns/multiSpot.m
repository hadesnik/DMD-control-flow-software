function mask = multiSpot(dmd, targetList, radiusPx)
%multiSpot Logical mask with multiple circular spots from targetList.
%
%   mask = multiSpot(dmd, targetList, radiusPx)
%
%   Inputs:
%     dmd         - object/struct with .nRows and .nCols.
%     targetList  - N x 2 numeric, one [col row] per row, DMD pixel coords.
%     radiusPx    - scalar positive, common radius for all spots.
%
%   targetList rows are always DMD-pixel coords. To use sample-um inputs,
%   call tfp.patterns.calibratedAffine first.
%
%   Output:
%     mask        - logical(nRows, nCols). Union of N circular spots.

try
    nRows = dmd.nRows;
    nCols = dmd.nCols;
catch ME
    error('tfp:patterns:multiSpot:badDmd', ...
        'dmd must expose .nRows and .nCols (got: %s).', ME.message);
end

if ~isnumeric(targetList) || ndims(targetList) > 2 || size(targetList, 2) ~= 2
    error('tfp:patterns:multiSpot:badTargetList', ...
        'targetList must be N x 2 numeric [col row]; got size [%s].', ...
        num2str(size(targetList)));
end

if ~isnumeric(radiusPx) || ~isscalar(radiusPx) || ~isfinite(radiusPx) || radiusPx <= 0
    error('tfp:patterns:multiSpot:badRadius', ...
        'radiusPx must be a positive finite scalar.');
end

mask = false(nRows, nCols);
nTargets = size(targetList, 1);
if nTargets == 0
    return;
end

[cols, rows] = meshgrid(1:nCols, 1:nRows);
r2 = radiusPx^2;
for k = 1:nTargets
    u = targetList(k, 1);
    v = targetList(k, 2);
    mask = mask | ((cols - u).^2 + (rows - v).^2 <= r2);
end
end
