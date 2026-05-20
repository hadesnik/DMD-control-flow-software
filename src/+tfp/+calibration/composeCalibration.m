function composed = composeCalibration(dmdCalib, scanReg)
%composeCalibration Compose DMD→camera and scan-field→camera into DMD→scan-field.
%
%   composed = composeCalibration(dmdCalib, scanReg)
%
%   Combines two separately-measured affines to produce the full
%   DMD-pixel → ScanImage scan-field coordinate mapping required to aim
%   photostimulation targets using scan-field coordinates.
%
%   Composition:
%     dmdToScan_affine = inv(scanToCam_affine) * dmdToSample_affine
%
%   Inputs:
%     dmdCalib - struct from alignDMDtoCamera (or alignDMDtoCamera_mock).
%                Required field: .dmdToSample_affine (3×3).
%     scanReg  - struct from crossRegisterScanImage (or its mock).
%                Required fields:
%                  .scanToCam_affine    (3×3)
%                  .scan_fast_axis_sign (±1 scalar)
%                  .scan_slow_axis_sign (±1 scalar)
%
%   Output — all dmdCalib fields are preserved and the following are added
%   (or overwritten if already present):
%     .scanToCam_affine    — 3×3: scan-field → camera pixels (from scanReg)
%     .dmdToScan_affine    — 3×3: DMD pixels → scan-field coords (composed)
%     .scan_fast_axis_sign — ±1 from scanReg; update to ±1 after verify step
%     .scan_slow_axis_sign — ±1 from scanReg; update to ±1 after verify step
%     .composedAt          — datetime of this composition
%
%   Axis signs default to +1 in crossRegisterScanImage because the sign
%   cannot be resolved from a single passive camera image.  Run
%   verifyDMDtoScan after composition to confirm or flip the signs.
%
%   See also tfp.calibration.alignDMDtoCamera,
%            tfp.calibration.crossRegisterScanImage,
%            tfp.patterns.calibratedAffine.

validateDmdCalib(dmdCalib);
validateScanReg(scanReg);

dmdToCam    = dmdCalib.dmdToSample_affine;   % 3×3
scanToCam   = scanReg.scanToCam_affine;       % 3×3

condNum = cond(scanToCam);
if condNum > 1e6
    warning('tfp:calibration:composeCalibration:illConditioned', ...
        'scanToCam_affine condition number is %.2e; composition may be inaccurate.', ...
        condNum);
end

dmdToScan = scanToCam \ dmdToCam;   % inv(scanToCam) * dmdToCam, numerically preferred

% Enforce exact projective bottom row — floating-point errors from the
% matrix solve can leave it as [~0 ~0 ~1] rather than [0 0 1].
dmdToScan(3,:) = [0 0 1];

composed = dmdCalib;
composed.scanToCam_affine    = scanToCam;
composed.dmdToScan_affine    = dmdToScan;
composed.scan_fast_axis_sign = scanReg.scan_fast_axis_sign;
composed.scan_slow_axis_sign = scanReg.scan_slow_axis_sign;
composed.composedAt          = datetime('now');
end

% =========================================================================
% Local validation helpers
% =========================================================================

function validateDmdCalib(s)
if ~isstruct(s)
    error('tfp:calibration:composeCalibration:badDmdCalib', ...
        'dmdCalib must be a struct.');
end
if ~isfield(s, 'dmdToSample_affine')
    error('tfp:calibration:composeCalibration:missingDmdAffine', ...
        'dmdCalib must have field .dmdToSample_affine (run alignDMDtoCamera first).');
end
validateAffine(s.dmdToSample_affine, 'dmdCalib.dmdToSample_affine');
end

function validateScanReg(s)
if ~isstruct(s)
    error('tfp:calibration:composeCalibration:badScanReg', ...
        'scanReg must be a struct.');
end
requiredFields = {'scanToCam_affine', 'scan_fast_axis_sign', 'scan_slow_axis_sign'};
for k = 1:numel(requiredFields)
    f = requiredFields{k};
    if ~isfield(s, f)
        error('tfp:calibration:composeCalibration:missingScanRegField', ...
            'scanReg is missing required field .%s (run crossRegisterScanImage first).', f);
    end
end
validateAffine(s.scanToCam_affine, 'scanReg.scanToCam_affine');
validateAxisSign(s.scan_fast_axis_sign, 'scan_fast_axis_sign');
validateAxisSign(s.scan_slow_axis_sign, 'scan_slow_axis_sign');
end

function validateAffine(A, name)
if ~isnumeric(A) || ~isequal(size(A), [3 3])
    error('tfp:calibration:composeCalibration:badAffine', ...
        '%s must be a 3×3 numeric matrix.', name);
end
if any(~isfinite(A(:)))
    error('tfp:calibration:composeCalibration:nonFiniteAffine', ...
        '%s contains non-finite values.', name);
end
if abs(det(A)) < 1e-10
    error('tfp:calibration:composeCalibration:singularAffine', ...
        '%s is singular (det ≈ 0); cannot invert.', name);
end
end

function validateAxisSign(v, name)
% NaN is accepted here — axis signs are unknown until verifyDMDtoScan is run.
if ~isnumeric(v) || ~isscalar(v) || (~isnan(v) && ~ismember(v, [1 -1]))
    error('tfp:calibration:composeCalibration:badAxisSign', ...
        '%s must be +1, -1, or NaN; got %s.', name, mat2str(v));
end
end
