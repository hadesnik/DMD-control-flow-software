function slm_xyz = mapScanToSLM(siCentroids, calib)
%mapScanToSLM Apply a homogeneous affine to map ScanImage centroids to SLM coords.
%
%   slm_xyz = tfp.patterns.threeDShot.mapScanToSLM(siCentroids, calib)
%
%   Applies the 3×3 homogeneous affine stored in calib.affine to each row of
%   siCentroids, then appends a constant z column equal to calib.zDefault.
%   This converts ScanImage scan-field coordinates (µm, N×2) into SLM
%   sample-plane coordinates (µm, N×3) ready for composeHologram.
%
%   Inputs:
%     siCentroids - N×2 double [x, y] in ScanImage scan-field µm.
%                  If N×3 is supplied the third column is silently ignored
%                  and replaced by calib.zDefault (allows identity round-trip
%                  when targets are already in SLM coords).
%     calib       - struct from loadSLMScanCalibration (must have .affine 3×3
%                   and .zDefault scalar).
%
%   Output:
%     slm_xyz - N×3 double [x, y, z] in SLM sample-plane µm.
%
%   Pure: no hardware, no file I/O, no side effects.

N = size(siCentroids, 1);

% Extract xy columns; ignore any extra columns (e.g. z already present).
xy = double(siCentroids(:, 1:2));

% Homogeneous coordinates: augment with a column of ones.
homog = [xy, ones(N, 1)]';          % 3×N

% Apply affine: result is 3×N, each column [x'; y'; w'].
mapped = calib.affine * homog;      % 3×N

% In a proper affine the bottom row is [0 0 1] so w'==1 always, but divide
% for generality (e.g. projective extension).
w = mapped(3, :);
x_slm = (mapped(1, :) ./ w)';      % N×1
y_slm = (mapped(2, :) ./ w)';      % N×1

z_slm = repmat(calib.zDefault, N, 1);

slm_xyz = [x_slm, y_slm, z_slm];
end
