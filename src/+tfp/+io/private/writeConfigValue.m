function writeConfigValue(configPath, section, key, formattedValue, callerId)
%writeConfigValue Replace one key's value inside a one-level YAML section.
%
%   writeConfigValue(configPath, section, key, formattedValue, callerId)
%
%   The shared machinery behind tfp.io.updateConfigCalibrationPath (which
%   formats single-quoted paths) and tfp.io.updateConfigScalar (which formats
%   bare scalars). formattedValue arrives ready to paste — this function does
%   not quote, escape or convert it.
%
%   tfp.io.loadConfig supports exactly one nesting level, so "the section block
%   runs from `^section:` to the next unindented line" is guaranteed for any
%   config the repo can actually parse. Error identifiers are namespaced by
%   callerId so the existing
%   tfp:io:updateConfigCalibrationPath:{fileNotFound,sectionNotFound,
%   keyNotFound,writeFailed} identifiers are preserved for that caller.

configPath = char(configPath);
section    = char(section);
key        = char(key);

if exist(configPath, 'file') ~= 2
    error(sprintf('tfp:io:%s:fileNotFound', callerId), ...
        'Config not found: %s', configPath);
end
cfgText = fileread(configPath);

sectionPat = ['(^|\n)(', regexptranslate('escape', section), ':)'];
if isempty(regexp(cfgText, sectionPat, 'once'))
    error(sprintf('tfp:io:%s:sectionNotFound', callerId), ...
        'Section ''%s:'' not found in %s.', section, configPath);
end

% Match up to (and including) the key inside the section, then swallow the old
% value to end-of-line.
pat = ['((?:^|\n)', regexptranslate('escape', section), ...
       ':[ \t]*(?:#[^\n]*)?(?:\n[ \t]+[^\n]*)*?', ...             % indented body
       '\n[ \t]+', regexptranslate('escape', key), ':[ \t]*)', ... % the key
       '(''[^'']*''|"[^"]*"|[^\r\n]*)'];                           % old value

% A literal $ or \ in the replacement would be interpreted by regexprep, so
% escape both before substituting.
safeValue = regexprep(formattedValue, '([\$\\])', '\\$1');
newText   = regexprep(cfgText, pat, ['$1' safeValue], 'once');

if strcmp(newText, cfgText)
    error(sprintf('tfp:io:%s:keyNotFound', callerId), ...
        'Key ''%s'' not found inside section ''%s:'' of %s.', ...
        key, section, configPath);
end

fid = fopen(configPath, 'w');
if fid < 0
    error(sprintf('tfp:io:%s:writeFailed', callerId), ...
        'Could not open %s for writing.', configPath);
end
fprintf(fid, '%s', newText);
fclose(fid);
fprintf('[%s] %s.%s -> %s\n', callerId, section, key, formattedValue);
end
