function mask = singleSpot(dmd, targetCoords, radiusPx)
%singleSpot Logical mask with one circular spot at targetCoords on the DMD.
%
%   mask = singleSpot(dmd, targetCoords, radiusPx)
%
%   Inputs:
%     dmd          - object/struct exposing .nRows and .nCols (DMD geometry).
%     targetCoords - 1x2 numeric [col row] in DMD pixel coords, 1-indexed,
%                    origin top-left (per CLAUDE.md).
%     radiusPx     - scalar positive, spot radius in DMD pixels.
%
%   targetCoords are always DMD-pixel coords. To use sample-um inputs,
%   call tfp.patterns.calibratedAffine first.
%
%   Output:
%     mask         - logical(nRows, nCols). True wherever the Euclidean
%                    distance to targetCoords is <= radiusPx (boundary
%                    inclusive).

try
    nRows = dmd.nRows;
    nCols = dmd.nCols;
catch ME
    error('tfp:patterns:singleSpot:badDmd', ...
        'dmd must expose .nRows and .nCols (got: %s).', ME.message);
end

if ~isnumeric(targetCoords) || numel(targetCoords) ~= 2
    error('tfp:patterns:singleSpot:badTarget', ...
        'targetCoords must be 1x2 numeric [col row]; got size [%s].', ...
        num2str(size(targetCoords)));
end

if ~isnumeric(radiusPx) || ~isscalar(radiusPx) || ~isfinite(radiusPx) || radiusPx <= 0
    error('tfp:patterns:singleSpot:badRadius', ...
        'radiusPx must be a positive finite scalar.');
end

uTarget = targetCoords(1);  % column
vTarget = targetCoords(2);  % row

[cols, rows] = meshgrid(1:nCols, 1:nRows);
mask = (cols - uTarget).^2 + (rows - vTarget).^2 <= radiusPx^2;
end
