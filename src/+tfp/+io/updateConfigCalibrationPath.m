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

configPath = char(configPath);
section    = char(section);
key        = char(key);
newPath    = strrep(char(newPath), '\', '/');   % YAML-safe

if exist(configPath, 'file') ~= 2
    error('tfp:io:updateConfigCalibrationPath:fileNotFound', ...
        'Config not found: %s', configPath);
end
cfgText = fileread(configPath);

% The section block: from `^section:` to the next unindented line.
% loadConfig only supports one nesting level, so this structure is
% guaranteed for any parseable config.
sectionPat = ['(^|\n)(', regexptranslate('escape', section), ':)'];
if isempty(regexp(cfgText, sectionPat, 'once'))
    error('tfp:io:updateConfigCalibrationPath:sectionNotFound', ...
        'Section ''%s:'' not found in %s.', section, configPath);
end

% Within that block, replace the key's value. Pattern mirrors
% run_powerMeterSweep.m: match up to (and including) the key inside the
% section, then swallow the old value to end-of-line.
pat = ['((?:^|\n)', regexptranslate('escape', section), ...
       ':[ \t]*(?:#[^\n]*)?(?:\n[ \t]+[^\n]*)*?', ...          % section body (indented lines)
       '\n[ \t]+', regexptranslate('escape', key), ':[ \t]*)', ... % the key
       '(''[^'']*''|"[^"]*"|[^\r\n]*)'];                        % old value
newText = regexprep(cfgText, pat, ['$1''' newPath ''''], 'once');

if strcmp(newText, cfgText)
    error('tfp:io:updateConfigCalibrationPath:keyNotFound', ...
        'Key ''%s'' not found inside section ''%s:'' of %s.', ...
        key, section, configPath);
end

fid = fopen(configPath, 'w');
if fid < 0
    error('tfp:io:updateConfigCalibrationPath:writeFailed', ...
        'Could not open %s for writing.', configPath);
end
fprintf(fid, '%s', newText);
fclose(fid);
fprintf('[updateConfigCalibrationPath] %s.%s -> %s\n', section, key, newPath);
end
