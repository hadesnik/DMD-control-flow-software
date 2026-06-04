function calib = loadSLMScanCalibration(file)
%loadSLMScanCalibration Load the ScanImage-to-SLM spatial calibration.
%
%   calib = tfp.patterns.threeDShot.loadSLMScanCalibration(file)
%
%   Parses a .mat calibration file that maps ScanImage scan-field coordinates
%   (µm) to SLM sample-plane coordinates (µm) via a 3×3 homogeneous affine.
%   Returns an identity calibration struct when the file argument is empty or
%   missing, allowing code paths that have not yet been calibrated to run
%   without modification.
%
%   Inputs:
%     file - char | string. Path to a .mat calibration file.  Pass '' or
%            omit to request the identity fallback.
%
%   Output: struct with fields
%     .affine   - 3×3 double homogeneous affine (maps [x;y;1] SI → SLM).
%     .type     - 'identity' | 'affine'
%     .zDefault - scalar double, default axial coordinate (µm) for all
%                 mapped points (0 if not stored in the file).
%     .source   - char, the resolved file path or 'identity'.
%
%   Errors:
%     tfp:patterns:threeDShot:loadSLMScanCalibration:fileNotFound
%     tfp:patterns:threeDShot:loadSLMScanCalibration:badSchema
%
%   %VERIFY: Real .mat schema to be confirmed when the calibration procedure
%   is run on the rig.  Expected required field: scanToSlm_affine (3×3
%   double).  Optional field: zDefault (scalar double, µm).

ERR_BASE = 'tfp:patterns:threeDShot:loadSLMScanCalibration';

% --- Identity fallback ---
if nargin < 1 || isempty(file)
    calib = identityCalib();
    return;
end

file = char(file);

if isempty(strtrim(file))
    calib = identityCalib();
    return;
end

% --- File must exist ---
if ~isfile(file)
    error([ERR_BASE ':fileNotFound'], ...
        'Calibration file not found: %s', file);
end

% --- Load and validate ---
%VERIFY: schema confirmed once first calibration is collected on rig.
try
    S = load(file, '-mat');
catch ME
    error([ERR_BASE ':badSchema'], ...
        'Could not load calibration file "%s": %s', file, ME.message);
end

if ~isfield(S, 'scanToSlm_affine')
    error([ERR_BASE ':badSchema'], ...
        ['Calibration file "%s" is missing required field ' ...
         '"scanToSlm_affine" (expected 3×3 double).'], file);
end

A = double(S.scanToSlm_affine);
if ~isequal(size(A), [3 3])
    error([ERR_BASE ':badSchema'], ...
        ['Field "scanToSlm_affine" in "%s" must be 3×3; got %dx%d.'], ...
        file, size(A,1), size(A,2));
end

zDefault = 0;
if isfield(S, 'zDefault') && ~isempty(S.zDefault)
    zDefault = double(S.zDefault(1));
end

calib = struct( ...
    'affine',   A, ...
    'type',     'affine', ...
    'zDefault', zDefault, ...
    'source',   file);
end

% --- Local helpers ---
function calib = identityCalib()
calib = struct( ...
    'affine',   eye(3), ...
    'type',     'identity', ...
    'zDefault', 0, ...
    'source',   'identity');
end
