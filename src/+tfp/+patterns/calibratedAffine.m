function transformedCoords = calibratedAffine(coords, calibration, targetSpace)
%calibratedAffine Apply a DMD->target-space affine from a calibration struct.
%
%   transformedCoords = calibratedAffine(coords, calibration)
%   transformedCoords = calibratedAffine(coords, calibration, targetSpace)
%
%   Inputs:
%     coords      - 1x2 or N x 2 numeric. Each row is [u v] in DMD pixel
%                   space.
%     calibration - struct containing the requested affine field.
%     targetSpace - char (default 'camera'). Selects which affine to apply:
%                     'camera'    -> calibration.dmdToSample_affine (DMD->camera px)
%                     'scanfield' -> calibration.dmdToScan_affine (DMD->scan-field)
%
%   Output:
%     transformedCoords - same shape as coords (1x2 or N x 2).

if nargin < 3
    targetSpace = 'camera';
end

if ~isnumeric(coords) || ndims(coords) > 2 || size(coords, 2) ~= 2
    error('tfp:patterns:calibratedAffine:badCoords', ...
        'coords must be 1x2 or N x 2 numeric; got size [%s].', ...
        num2str(size(coords)));
end

if ~isstruct(calibration)
    error('tfp:patterns:calibratedAffine:badCalibration', ...
        'calibration must be a struct.');
end

switch targetSpace
    case 'camera'
        fieldName = 'dmdToSample_affine';
    case 'scanfield'
        fieldName = 'dmdToScan_affine';
    otherwise
        error('tfp:patterns:calibratedAffine:unknownTargetSpace', ...
            'Unknown targetSpace ''%s''; must be ''camera'' or ''scanfield''.', ...
            targetSpace);
end

if ~isfield(calibration, fieldName)
    error('tfp:patterns:calibratedAffine:missingAffine', ...
        'calibration.%s is not present; run the appropriate calibration step first.', ...
        fieldName);
end

A = calibration.(fieldName);
if ~isnumeric(A) || ~isequal(size(A), [3 3])
    error('tfp:patterns:calibratedAffine:badAffine', ...
        'calibration.%s must be a 3x3 numeric matrix.', fieldName);
end

N = size(coords, 1);
hom = [coords, ones(N, 1)]';     % 3 x N
out = A * hom;                   % 3 x N
out = out ./ out(3, :);          % defensive normalize (no-op for proper affine)
transformedCoords = out(1:2, :)';
end
