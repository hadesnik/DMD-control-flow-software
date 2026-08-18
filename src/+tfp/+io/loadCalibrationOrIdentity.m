function calibration = loadCalibrationOrIdentity(config, callerId)
%loadCalibrationOrIdentity Load the lateral calibration, or identity fallback.
%
%   calibration = tfp.io.loadCalibrationOrIdentity(config)
%   calibration = tfp.io.loadCalibrationOrIdentity(config, callerId)
%
%   Promoted from the per-experiment local helpers, WITH the "Phase 3"
%   throw finally replaced by an actual load: when a calibration file is
%   configured (config.calibration_file, or config.session.calibration_file
%   — both spellings exist in the configs), it is loaded via
%   tfp.io.loadCalibration and sanity-checked for the affine fields the
%   experiments consume. Otherwise the identity fallback is built from
%   config.dmd.umPerPixel exactly as the old locals did.
%
%   callerId only decorates error messages (default 'loadCalibrationOrIdentity').

if nargin < 2 || isempty(callerId)
    callerId = 'loadCalibrationOrIdentity';
end

calibFile = '';
if isfield(config, 'calibration_file') && ~isempty(char(config.calibration_file))
    calibFile = char(config.calibration_file);
elseif isfield(config, 'session') && isstruct(config.session) && ...
        isfield(config.session, 'calibration_file') && ...
        ~isempty(char(config.session.calibration_file))
    calibFile = char(config.session.calibration_file);
end

if ~isempty(calibFile)
    calibration = tfp.io.loadCalibration(calibFile);
    if ~isfield(calibration, 'dmdToScan_affine') && ...
            ~isfield(calibration, 'dmdToSample_affine')
        error(sprintf('tfp:io:%s:badCalibration', callerId), ...
            ['%s carries neither dmdToScan_affine nor dmdToSample_affine ' ...
             '— not a lateral calibration file.'], calibFile);
    end
    if ~isfield(calibration, 'pixelsPerUm') && isfield(calibration, 'umPerPixel')
        calibration.pixelsPerUm = 1 / calibration.umPerPixel;
    end
    return
end

% Identity fallback (byte-compatible with the old per-experiment locals).
umPerPx = 1;
if isfield(config, 'dmd') && isfield(config.dmd, 'umPerPixel')
    umPerPx = double(config.dmd.umPerPixel);
end
calibration.dmdToSample_affine = eye(3);
calibration.dmdToScan_affine   = eye(3);
calibration.pixelsPerUm        = 1 / umPerPx;
calibration.umPerPixel         = umPerPx;
calibration.timestamp          = datetime('now');
calibration.notes              = sprintf( ...
    'pixel-scale only: %.4f um/px (no spatial calibration)', umPerPx);
end
