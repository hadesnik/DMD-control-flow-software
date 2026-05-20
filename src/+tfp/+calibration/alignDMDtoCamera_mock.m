function calib = alignDMDtoCamera_mock(dmd, options)
%alignDMDtoCamera_mock Synthetic calibration for pipeline testing (no hardware).
%
%   calib = alignDMDtoCamera_mock(dmd)
%   calib = alignDMDtoCamera_mock(dmd, options)
%
%   Returns a calibration struct with a known closed-form affine transform
%   (isotropic scale + translation) so round-trip accuracy can be verified
%   analytically. The transform is exact by construction, so residualErrorPx
%   is 0 and nCalibrationPoints is 0 (no real image data was processed).
%
%   Default transform: x = scaleX*u + offsetX,  y = scaleY*v + offsetY
%   Defaults: scaleX = 0.5, scaleY = 0.5, offsetX = 10, offsetY = 15.
%   These are plausible when the imaging pixel is ~2× larger than the DMD
%   pixel at the sample plane.
%
%   Inputs:
%     dmd     - object/struct with .nRows and .nCols (used only for notes).
%     options - optional struct:
%       .umPerPixel  — imaging pixel size at sample plane in µm (default 1.56)
%       .notes       — char note string
%       .scaleX      — x scale factor (default 0.5)
%       .scaleY      — y scale factor (default 0.5)
%       .offsetX     — x translation in imaging pixels (default 10)
%       .offsetY     — y translation in imaging pixels (default 15)
%
%   See also tfp.calibration.alignDMDtoCamera.

if nargin < 2
    options = struct();
end

umPerPixel = configField(options, 'umPerPixel', 1.56);
notes      = configField(options, 'notes', ...
    'mock calibration — known affine, not from real hardware');
scaleX     = configField(options, 'scaleX',   0.5);
scaleY     = configField(options, 'scaleY',   0.5);
offsetX    = configField(options, 'offsetX',  10);
offsetY    = configField(options, 'offsetY',  15);

% Column-vector convention: [x; y; 1] = A * [u; v; 1]
%   x = scaleX*u + offsetX
%   y = scaleY*v + offsetY
dmdToSample_affine = [scaleX  0       offsetX; ...
                      0       scaleY  offsetY; ...
                      0       0       1      ];

calib.dmdToSample_affine = dmdToSample_affine;
calib.umPerPixel         = umPerPixel;
calib.pixelsPerUm        = 1 / umPerPixel;
calib.powerCurve         = struct();
calib.timestamp          = datetime('now');
calib.notes              = notes;
calib.residualErrorPx    = 0;
calib.nCalibrationPoints = 0;
end

function value = configField(s, name, default)
if isfield(s, name)
    value = s.(name);
else
    value = default;
end
end
