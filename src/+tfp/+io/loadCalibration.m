function calib = loadCalibration(path, expectedKind)
%loadCalibration Load a calibration .mat written by tfp.io.saveCalibration.
%
%   calib = tfp.io.loadCalibration(path)
%   calib = tfp.io.loadCalibration(path, expectedKind)
%
%   Accepts any single-struct .mat (the variable may be named `calib`,
%   `curve`, or anything else — the GUI's uiputfile save and the
%   power-curve script predate the saveCalibration convention; the
%   run_ensemble scripts' "first field wins" idiom is preserved here).
%
%   When expectedKind is given, calib.kind must match — a z-composed file
%   accidentally pointed at by slm.calibration_file should fail loudly,
%   not calibrate silently.

path = char(path);
if exist(path, 'file') ~= 2
    error('tfp:io:loadCalibration:fileNotFound', ...
        'Calibration file not found: %s', path);
end
tmp = load(path);
fn  = fieldnames(tmp);
if isempty(fn)
    error('tfp:io:loadCalibration:emptyFile', ...
        'Calibration file %s holds no variables.', path);
end
if any(strcmp(fn, 'calib'))
    calib = tmp.calib;
else
    calib = tmp.(fn{1});
end
if ~isstruct(calib)
    error('tfp:io:loadCalibration:badContents', ...
        '%s: expected a struct, found %s.', path, class(calib));
end

if nargin >= 2 && ~isempty(expectedKind)
    actual = '';
    if isfield(calib, 'kind')
        actual = char(calib.kind);
    end
    if ~strcmp(actual, char(expectedKind))
        error('tfp:io:loadCalibration:kindMismatch', ...
            '%s: kind ''%s'' does not match expected ''%s''.', ...
            path, actual, char(expectedKind));
    end
end
end
