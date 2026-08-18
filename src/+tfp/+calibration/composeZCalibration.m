function zcal = composeZCalibration(slmCalib, etlCalib)
%composeZCalibration Cross-register SLM defocus commands with ETL planes.
%
%   zcal = tfp.calibration.composeZCalibration(slmCalib, etlCalib)
%
%   Both inputs were measured against the SAME objective-z ruler
%   (calibrateSlmDefocus and calibrateEtlPlanes), so the composition is a
%   direct substitution: the SLM command that focuses the stimulation at
%   imaging plane p is
%
%       dzCmdForPlane(p) = (planeZUm(p) - interceptUm) / slopeUmPerCmd
%
%   This struct IS the cross-calibrated ETL-plane <-> SLM-defocus tag:
%   ROIs received from ScanImage with a plane index are stamped with
%   dzCmdForPlane(planeIdx), and tfp.trial.TrialSequence.generate3DEnsemble
%   consumes etlPlaneZUm for target depths.
%
%   Mirrors composeCalibration (the lateral analogue): validates both
%   inputs, preserves provenance, stamps .composedAt.

validateKind(slmCalib, 'slm_defocus', 'slmCalib');
validateKind(etlCalib, 'etl_planes',  'etlCalib');

slope     = slmCalib.fit.slopeUmPerCmd;
intercept = slmCalib.fit.interceptUm;
if ~isfinite(slope) || abs(slope) < 1e-6
    error('tfp:calibration:composeZCalibration:degenerateSlope', ...
        'SLM calibration slope %.3g is degenerate — refit before composing.', ...
        slope);
end
if ~strcmp(slmCalib.zRuler, etlCalib.zRuler)
    warning('tfp:calibration:composeZCalibration:rulerMismatch', ...
        ['SLM calibration used %s but ETL calibration used %s — the ' ...
         'composition assumes ONE common z axis. Re-measure on the same ' ...
         'ruler unless you know these axes are identical.'], ...
        slmCalib.zRuler, etlCalib.zRuler);
end

planeZ = etlCalib.planeZUm(:)';

zcal.kind           = 'z_composed';
zcal.slmUmPerCmd    = slope;
zcal.slmInterceptUm = intercept;
zcal.etlPlaneZUm    = planeZ;
zcal.nPlanes        = etlCalib.nPlanes;
zcal.dzCmdForPlane  = (planeZ - intercept) / slope;
zcal.zRuler         = slmCalib.zRuler;
zcal.provenance     = struct( ...
    'slmTimestamp', slmCalib.timestamp, 'slmNotes', slmCalib.notes, ...
    'slmObjective', slmCalib.objective, ...
    'etlTimestamp', etlCalib.timestamp, 'etlNotes', etlCalib.notes);
zcal.composedAt     = datetime('now');
end

% --- Local helper ---

function validateKind(calib, kind, argName)
if ~isstruct(calib) || ~isfield(calib, 'kind') || ~strcmp(calib.kind, kind)
    error('tfp:calibration:composeZCalibration:badInput', ...
        '%s must be a ''%s'' calibration struct (tfp.calibration.%s).', ...
        argName, kind, kindToFn(kind));
end
end

function fn = kindToFn(kind)
switch kind
    case 'slm_defocus', fn = 'calibrateSlmDefocus';
    case 'etl_planes',  fn = 'calibrateEtlPlanes';
    otherwise,          fn = '?';
end
end
