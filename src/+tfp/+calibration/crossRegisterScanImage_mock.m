function calib = crossRegisterScanImage_mock(dmdCalib, options)
%crossRegisterScanImage_mock  Synthetic scan-field cross-registration (no hardware).
%   Returns a plausible calibration struct using a known closed-form
%   scanToCam affine, for pipeline testing without a substage camera or
%   running ScanImage. No Image Processing Toolbox required.
%
%   calib = crossRegisterScanImage_mock(dmdCalib)
%   calib = crossRegisterScanImage_mock(dmdCalib, options)
%
%   The default scanToCam affine is a pure scale + translation:
%     [x; y; 1] = [scaleF  0       offsetX] * [fast; slow; 1]
%                 [0       scaleS  offsetY]
%                 [0       0       1      ]
%   Default values (scaleF=1.5, scaleS=1.5, offsetX=30, offsetY=20)
%   represent a scan FOV where each scan pixel maps to 1.5 camera pixels,
%   with the scan rectangle starting ~30 px from the camera left edge.
%
%   Inputs:
%     dmdCalib  - struct with .dmdToSample_affine (3x3); from
%                 alignDMDtoCamera or alignDMDtoCamera_mock.
%     options   - optional struct:
%       .scaleF     — fast-axis scale (cam px / scan px, default 1.5)
%       .scaleS     — slow-axis scale (cam px / scan px, default 1.5)
%       .offsetX    — camera x offset in px (default 30)
%       .offsetY    — camera y offset in px (default 20)
%       .scanPixels — [nFast nSlow] (default [512 256])
%       .notes      — appended note string
%
%   See also tfp.calibration.crossRegisterScanImage.

if nargin < 2
    options = struct();
end

scaleF     = configField(options, 'scaleF',     1.5);
scaleS     = configField(options, 'scaleS',     1.5);
offsetX    = configField(options, 'offsetX',    30);
offsetY    = configField(options, 'offsetY',    20);
scanPixels = configField(options, 'scanPixels', [512, 256]);
notes      = configField(options, 'notes',      'mock scan cross-registration');

if ~isfield(dmdCalib, 'dmdToSample_affine')
    error('tfp:calibration:crossRegisterScanImage_mock:missingDmdCalib', ...
        'dmdCalib must contain .dmdToSample_affine (run alignDMDtoCamera_mock first).');
end

% Column-vector convention: [x;y;1] = A * [fast;slow;1]
scanToCam = [scaleF  0       offsetX; ...
             0       scaleS  offsetY; ...
             0       0       1      ];

dmdToScan = inv(scanToCam) * dmdCalib.dmdToSample_affine;  %#ok<MINV>

nFast = scanPixels(1);
nSlow = scanPixels(2);

calib = dmdCalib;
calib.scanToCam_affine     = scanToCam;
calib.dmdToScan_affine     = dmdToScan;
calib.scanPixels           = scanPixels;
calib.scan_fast_axis_sign  = NaN;
calib.scan_slow_axis_sign  = NaN;
% bbox: approximate bounding box that would be detected on camera
tl = scanToCam * [1; 1; 1];
br = scanToCam * [nFast; nSlow; 1];
calib.rectBboxPx           = [tl(1), tl(2), br(1)-tl(1), br(2)-tl(2)];
calib.fastAxisIsHorizontal = true;
calib.timestamp            = datetime('now');
if isfield(calib, 'notes') && ~isempty(calib.notes)
    calib.notes = [calib.notes '; ' notes];
else
    calib.notes = notes;
end
end

function value = configField(s, name, default)
if isfield(s, name)
    value = s.(name);
else
    value = default;
end
end
