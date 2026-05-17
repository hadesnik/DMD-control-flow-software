function patterns = ppsfPattern(dmd, centerTarget, offsetsUm, radiusPx, calibration)
%ppsfPattern Stack of masks for PPSF — one spot at each offset from centerTarget.
%
%   patterns = ppsfPattern(dmd, centerTarget, offsetsUm, radiusPx, calibration)
%
%   Inputs:
%     dmd          - object/struct with .nRows and .nCols.
%     centerTarget - 1x2 numeric [col row] in DMD pixel coords.
%     offsetsUm    - N x 2 numeric [dx_um dy_um] sample-plane offsets.
%                    Converted to DMD-pixel offsets via calibration.pixelsPerUm.
%     radiusPx     - scalar positive, spot radius in DMD pixels.
%     calibration  - struct; must contain a positive scalar .pixelsPerUm.
%
%   Output:
%     patterns     - logical(nRows, nCols, N). Slice k has one spot at
%                    centerTarget + (offsetsUm(k,:) .* pixelsPerUm).

try
    nRows = dmd.nRows;
    nCols = dmd.nCols;
catch ME
    error('tfp:patterns:ppsfPattern:badDmd', ...
        'dmd must expose .nRows and .nCols (got: %s).', ME.message);
end

if ~isnumeric(centerTarget) || numel(centerTarget) ~= 2
    error('tfp:patterns:ppsfPattern:badCenter', ...
        'centerTarget must be 1x2 numeric [col row].');
end

if ~isnumeric(offsetsUm) || ndims(offsetsUm) > 2 || size(offsetsUm, 2) ~= 2
    error('tfp:patterns:ppsfPattern:badOffsets', ...
        'offsetsUm must be N x 2 numeric [dx_um dy_um]; got size [%s].', ...
        num2str(size(offsetsUm)));
end

if ~isnumeric(radiusPx) || ~isscalar(radiusPx) || ~isfinite(radiusPx) || radiusPx <= 0
    error('tfp:patterns:ppsfPattern:badRadius', ...
        'radiusPx must be a positive finite scalar.');
end

if ~isstruct(calibration) || ~isfield(calibration, 'pixelsPerUm') ...
        || ~isnumeric(calibration.pixelsPerUm) || ~isscalar(calibration.pixelsPerUm) ...
        || ~isfinite(calibration.pixelsPerUm) || calibration.pixelsPerUm <= 0
    error('tfp:patterns:ppsfPattern:badCalibration', ...
        'calibration must be a struct with a positive scalar .pixelsPerUm.');
end

scale = calibration.pixelsPerUm;
nOffsets = size(offsetsUm, 1);
patterns = false(nRows, nCols, nOffsets);

for k = 1:nOffsets
    target = centerTarget + offsetsUm(k, :) * scale;
    patterns(:, :, k) = tfp.patterns.singleSpot(dmd, target, radiusPx);
end
end
