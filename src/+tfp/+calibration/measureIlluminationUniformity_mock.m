function calib = measureIlluminationUniformity_mock(dmd, options)
%measureIlluminationUniformity_mock Synthetic uniformity + extent (no hardware).
%   Evaluates a known analytic illumination profile over the same grid the
%   real routine projects, then runs the identical uniformity/extent math.
%   Because the profile is exact by construction, this lets the pipeline,
%   the CV/normalisation stats, the reachable-footprint logic, and the
%   scan-field extent/coverage be verified headless (no camera, no Image
%   Processing Toolbox). Mirrors tfp.calibration.alignDMDtoCamera_mock.
%
%   calib = measureIlluminationUniformity_mock(dmd)
%   calib = measureIlluminationUniformity_mock(dmd, options)
%
%   Inputs:
%     dmd     - object/struct with .nRows and .nCols.
%     options - optional struct:
%       .profile        — 'flattop' (default), 'gaussian', or 'uniform'
%       .footprintFrac  — flat-top radius as a fraction of roiHalfWidthPx
%                         (default 1.0); grid points beyond it roll off
%       .sigmaFrac      — Gaussian sigma as a fraction of roiHalfWidthPx (default 0.5)
%       .nGridPoints, .gridSpacing, .roiHalfWidthPx — grid geometry (see the
%                         real routine; same defaults)
%       .detectFrac     — reachable threshold as a fraction of peak (default 0.1)
%       .dmdToScan_affine, .scanFieldBox, .scanPixels — extent / coverage inputs
%       .umPerPixel, .notes
%
%   Returns the same struct shape as tfp.calibration.measureIlluminationUniformity
%   (camera-derived fields are set to the model values; cameraPts are NaN).
%
%   See also tfp.calibration.measureIlluminationUniformity.

if nargin < 2
    options = struct();
end

nGridPoints   = configField(options, 'nGridPoints', 9);
profile       = lower(configField(options, 'profile', 'flattop'));
footprintFrac = configField(options, 'footprintFrac', 1.0);
sigmaFrac     = configField(options, 'sigmaFrac', 0.5);
detectFrac    = configField(options, 'detectFrac', 0.1);
umPerPixel    = configField(options, 'umPerPixel', 1.56);
notes         = configField(options, 'notes', 'mock uniformity — synthetic profile');
dmdToScan     = configField(options, 'dmdToScan_affine', []);
scanFieldBox  = configField(options, 'scanFieldBox', []);
scanPixels    = configField(options, 'scanPixels', []);

if ~isnumeric(nGridPoints) || ~isscalar(nGridPoints) || nGridPoints < 3 || mod(nGridPoints,2) == 0
    error('tfp:calibration:measureIlluminationUniformity_mock:badOptions', ...
        'options.nGridPoints must be an odd integer >= 3; got %g.', nGridPoints);
end

nR = dmd.nRows; nC = dmd.nCols;
roiHalfWidth = configField(options, 'roiHalfWidthPx', floor(0.4 * min(nR, nC)));
if isfield(options, 'gridSpacing') && ~isempty(options.gridSpacing)
    gridSpacing = options.gridSpacing;
else
    gridSpacing = 2 * roiHalfWidth / (nGridPoints - 1);
end

% --- same grid the real routine would project ---
half   = floor(nGridPoints / 2);
axis1d = (-half:half) * gridSpacing;
[colOff, rowOff] = meshgrid(axis1d, axis1d);
dmdCols = nC/2 + colOff(:);
dmdRows = nR/2 + rowOff(:);
dmdPts  = [dmdCols, dmdRows];
nPts    = size(dmdPts, 1);

% --- evaluate the analytic illumination profile (radius normalised to the
% active half-width). 'flattop' is a super-Gaussian: ~1 inside the footprint,
% fast roll-off outside — the realistic pi-Shaper / Carbide flat-top shape. ---
r = sqrt(colOff(:).^2 + rowOff(:).^2) / roiHalfWidth;
switch profile
    case 'uniform'
        intensity = ones(nPts, 1);
    case 'gaussian'
        intensity = exp(-(r.^2) / (2 * sigmaFrac^2));
    case 'flattop'
        intensity = exp(-(r / footprintFrac).^8);
    otherwise
        error('tfp:calibration:measureIlluminationUniformity_mock:badProfile', ...
            'options.profile must be ''flattop'', ''gaussian'', or ''uniform''; got %s.', profile);
end

reachable = intensity >= detectFrac * max(intensity);

stats = uniformityStats(intensity, reachable);   % private helper (shared with real)

cx = nC/2; cy = nR/2;
activeBoxDmd = [cx-roiHalfWidth cy-roiHalfWidth; ...
                cx+roiHalfWidth cy-roiHalfWidth; ...
                cx+roiHalfWidth cy+roiHalfWidth; ...
                cx-roiHalfWidth cy+roiHalfWidth];

if isempty(scanFieldBox) && ~isempty(scanPixels)
    scanFieldBox = [0.5 0.5 scanPixels(1)+0.5 scanPixels(2)+0.5];
end
ext = reachableExtent(dmdPts, reachable, activeBoxDmd, dmdToScan, scanFieldBox);  % private helper

% --- assemble the same struct shape as the real routine ---
calib.dmdGridPts        = dmdPts;
calib.cameraPts         = nan(nPts, 2);   % no camera in the mock
calib.intensity         = intensity;
calib.intensityNorm     = stats.intensityNorm;
calib.intensitySqrtNorm = sqrt(max(stats.intensityNorm, 0));
calib.reachable         = reachable;
calib.cv                = stats.cv;
calib.minMaxRatio       = stats.minMaxRatio;
calib.nReachable        = stats.nReachable;
calib.nGridPoints       = nGridPoints;
calib.gridSpacingPx     = gridSpacing;
calib.roiHalfWidthPx    = roiHalfWidth;
calib.reachableHullDmd  = ext.reachableHullDmd;
calib.activeBoxDmd      = ext.activeBoxDmd;
calib.reachableHullScan = ext.reachableHullScan;
calib.activeBoxScan     = ext.activeBoxScan;
calib.coverageFraction  = ext.coverageFraction;
calib.scanFieldBox      = ext.scanFieldBox;
calib.umPerPixel        = umPerPixel;
calib.timestamp         = datetime('now');
calib.notes             = notes;
end

function value = configField(s, name, default)
if isfield(s, name)
    value = s.(name);
else
    value = default;
end
end
