function calib = measureFocalPlaneTilt_mock(dmd, options)
%measureFocalPlaneTilt_mock Synthetic focal-plane tilt (no hardware).
%   Evaluates a known analytic tilt plane over the same grid the real routine
%   projects, then runs the identical plane-fit + tilt-reduction math and
%   returns the same struct shape. Because the plane is exact by construction,
%   this verifies the fit/angle pipeline headless (no camera, no ZStage, no
%   Image Processing Toolbox). Mirrors tfp.calibration.measureIlluminationUniformity_mock.
%
%   calib = measureFocalPlaneTilt_mock(dmd)
%   calib = measureFocalPlaneTilt_mock(dmd, options)
%
%   Inputs:
%     dmd     - object/struct with .nRows and .nCols.
%     options - optional struct:
%       .truthTiltPlane — [a b z0]: best-focus Z (µm) = z0 + a*(col-cx) + b*(row-cy),
%                         with a,b in µm-Z per DMD-px (default [0.02 -0.01 0]).
%       .nGridPoints, .gridSpacing, .roiHalfWidthPx — grid geometry (see the real routine)
%       .umPerPixel     — DMD sample-plane pixel size for the tilt angle (default 0.270)
%       .notes
%
%   See also tfp.calibration.measureFocalPlaneTilt.

if nargin < 2
    options = struct();
end

nGridPoints    = configField(options, 'nGridPoints', 9);
truthTiltPlane = configField(options, 'truthTiltPlane', [0.02, -0.01, 0]);
umPerPixel     = configField(options, 'umPerPixel', 0.270);
notes          = configField(options, 'notes', 'mock focal-plane tilt — synthetic plane');

if ~isnumeric(nGridPoints) || ~isscalar(nGridPoints) || nGridPoints < 3 || mod(nGridPoints,2) == 0
    error('tfp:calibration:measureFocalPlaneTilt_mock:badOptions', ...
        'options.nGridPoints must be an odd integer >= 3; got %g.', nGridPoints);
end
if numel(truthTiltPlane) ~= 3
    error('tfp:calibration:measureFocalPlaneTilt_mock:badPlane', ...
        'options.truthTiltPlane must be [a b z0].');
end

nR = dmd.nRows; nC = dmd.nCols;
roiHalfWidth = configField(options, 'roiHalfWidthPx', floor(0.4 * min(nR, nC)));
if isfield(options, 'gridSpacing') && ~isempty(options.gridSpacing)
    gridSpacing = options.gridSpacing;
else
    gridSpacing = 2 * roiHalfWidth / (nGridPoints - 1);
end

half   = floor(nGridPoints / 2);
axis1d = (-half:half) * gridSpacing;
[colOff, rowOff] = meshgrid(axis1d, axis1d);
dmdCols = nC/2 + colOff(:);
dmdRows = nR/2 + rowOff(:);
dmdPts  = [dmdCols, dmdRows];
nPts    = size(dmdPts, 1);

% --- analytic best-focus Z per spot (col/row relative to the DMD centre) ---
a = truthTiltPlane(1); b = truthTiltPlane(2); z0 = truthTiltPlane(3);
xr = colOff(:);   % = dmdCols - nC/2
yr = rowOff(:);   % = dmdRows - nR/2
zBest = z0 + a*xr + b*yr;

plane = fitPlane(xr, yr, zBest);                    % private helper
tilt  = planeTilt(plane, umPerPixel, xr, yr);       % private helper

% --- assemble the same struct shape as the real routine ---
calib.dmdGridPts      = dmdPts;
calib.cameraPts       = nan(nPts, 2);   % no camera in the mock
calib.zSweepUm        = [];
calib.brightness      = [];
calib.sigma           = [];
calib.zBestBrightUm   = zBest;
calib.zBestSharpUm    = zBest;
calib.valid           = true(nPts, 1);
calib.planeBright     = plane;
calib.planeSharp      = plane;
calib.tiltAngleDeg    = tilt.tiltAngleDeg;
calib.tiltAzimuthDeg  = tilt.tiltAzimuthDeg;
calib.tiltAnglesXYDeg = tilt.tiltAnglesXYDeg;
calib.peakToValleyUm  = tilt.peakToValleyUm;
calib.umPerPixel      = umPerPixel;
calib.nGridPoints     = nGridPoints;
calib.gridSpacingPx   = gridSpacing;
calib.roiHalfWidthPx  = roiHalfWidth;
calib.timestamp       = datetime('now');
calib.notes           = notes;
end

function value = configField(s, name, default)
if isfield(s, name)
    value = s.(name);
else
    value = default;
end
end
