function updateConfigCalibrationPath(configPath, section, key, newPath)
%updateConfigCalibrationPath Point a rig-config key at a calibration file.
%
%   tfp.io.updateConfigCalibrationPath(configPath, section, key, newPath)
%
%   Generalises the regex write-back born in run_powerMeterSweep (which
%   rewrote laser.calibration_file): finds `key:` inside the one-level
%   `section:` block of the YAML at configPath and replaces its value with
%   newPath (single-quoted, forward slashes). Errors if the section or key
%   is absent — a silent no-op would leave the rig on a stale calibration.
%
%   Examples:
%     tfp.io.updateConfigCalibrationPath('configs/real.yaml', ...
%         'slm', 'calibration_file', path)
%     tfp.io.updateConfigCalibrationPath('configs/real.yaml', ...
%         'etl', 'plane_calibration_file', path)
%
%   See also tfp.io.updateConfigScalar (for numeric values such as the +/-1
%   axis signs), tfp.io.loadConfig.

newPath = strrep(char(newPath), '\', '/');   % YAML-safe

% Delegate to the shared machinery; this function is the quoted-path formatter,
% tfp.io.updateConfigScalar is the bare-scalar one.
writeConfigValue(configPath, section, key, ['''' newPath ''''], ...
    'updateConfigCalibrationPath');
end
