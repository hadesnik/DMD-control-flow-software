function transformedCoords = calibratedAffine(coords, calibration)
%calibratedAffine Apply DMD->sample affine from a calibration struct.
%
%   transformedCoords = calibratedAffine(coords, calibration)
%
%   Inputs:
%     coords      - 1x2 or N x 2 numeric. Each row is [u v] in DMD pixel
%                   space.
%     calibration - struct with .dmdToSample_affine, a 3 x 3 matrix that
%                   acts as: [x y 1]' = A * [u v 1]'.
%
%   Output:
%     transformedCoords - same shape as coords (1x2 or N x 2), each row
%                         transformed by A. Output is in sample-um space.

if ~isnumeric(coords) || ndims(coords) > 2 || size(coords, 2) ~= 2
    error('tfp:patterns:calibratedAffine:badCoords', ...
        'coords must be 1x2 or N x 2 numeric; got size [%s].', ...
        num2str(size(coords)));
end

if ~isstruct(calibration) || ~isfield(calibration, 'dmdToSample_affine')
    error('tfp:patterns:calibratedAffine:badCalibration', ...
        'calibration must be a struct with .dmdToSample_affine.');
end

A = calibration.dmdToSample_affine;
if ~isnumeric(A) || ~isequal(size(A), [3 3])
    error('tfp:patterns:calibratedAffine:badAffine', ...
        'calibration.dmdToSample_affine must be a 3x3 numeric matrix.');
end

N = size(coords, 1);
hom = [coords, ones(N, 1)]';     % 3 x N
out = A * hom;                   % 3 x N
out = out ./ out(3, :);          % defensive normalize (no-op for proper affine)
transformedCoords = out(1:2, :)';
end
