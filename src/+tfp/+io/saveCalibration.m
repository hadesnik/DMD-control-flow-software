function path = saveCalibration(calib, kind, config)
%saveCalibration Persist a calibration struct under data/calibration/.
%
%   path = tfp.io.saveCalibration(calib, kind, config)
%
%   Writes <dataRoot>/calibration/<kind>_<yyyymmdd_HHMMSS>.mat holding the
%   variable `calib` (v7.3), following the run_powerMeterSweep precedent
%   (timestamped file, latest run wins in the config pointer). dataRoot is
%   config.paths.dataDir when present, else 'data'.
%
%   Update the rig-config pointer with
%   tfp.io.updateConfigCalibrationPath(configPath, section, key, path)
%   so the next session finds it — this function only writes the file.
%
%   kind: short slug used in the filename AND stamped/checked against
%   calib.kind when that field exists ('slm_defocus', 'etl_planes',
%   'z_composed', 'dmd_affine', ...).

if ~isstruct(calib)
    error('tfp:io:saveCalibration:badCalib', 'calib must be a struct.');
end
kind = char(kind);
if isempty(regexp(kind, '^[a-z0-9_]+$', 'once'))
    error('tfp:io:saveCalibration:badKind', ...
        'kind must be a lowercase_slug (got ''%s'').', kind);
end
if isfield(calib, 'kind') && ~strcmp(calib.kind, kind)
    error('tfp:io:saveCalibration:kindMismatch', ...
        'calib.kind ''%s'' does not match requested kind ''%s''.', ...
        calib.kind, kind);
end
if ~isfield(calib, 'kind')
    calib.kind = kind;
end

dataRoot = 'data';
if nargin >= 3 && isstruct(config)
    pathsCfg = tfp.util.configField(config, 'paths', struct());
    dataRoot = char(tfp.util.configField(pathsCfg, 'dataDir', 'data'));
end
calibDir = fullfile(dataRoot, 'calibration');
if ~isfolder(calibDir)
    mkdir(calibDir);
end

stamp = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
path  = fullfile(calibDir, sprintf('%s_%s.mat', kind, stamp));
save(path, 'calib', '-v7.3');
fprintf('[saveCalibration] %s\n', path);
end
