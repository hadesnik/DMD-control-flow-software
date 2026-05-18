function config = loadConfig(yamlPath)
%loadConfig Parse a small YAML config into a struct.
%
%   Phase 1 hand-parser. Supports:
%     - top-level scalar keys: `name: value`
%     - one level of nested mapping (2-space indent):
%         section:
%           child: value
%     - scalar values: numbers, true/false, bare strings, quoted strings
%     - inline arrays: [a, b, c]
%     - '#' line comments
%
%   Not supported: nested mappings beyond one level; lists of mappings;
%   multi-line strings; anchors/aliases; flow-style mappings.
%
%   Validates that config.hardwareKind is 'mock' or 'real'.
%   Errors with tfp:io:loadConfig:badYaml on parse failure.

if ~(ischar(yamlPath) || (isstring(yamlPath) && isscalar(yamlPath)))
    error('tfp:io:loadConfig:badPath', 'yamlPath must be a char or string scalar.');
end
yamlPath = char(yamlPath);
if ~isfile(yamlPath)
    error('tfp:io:loadConfig:fileNotFound', 'Config file not found: %s.', yamlPath);
end

try
    rawLines = readlines(yamlPath);
    config = parseLines(rawLines);
catch ME
    error('tfp:io:loadConfig:badYaml', ...
        'Failed to parse %s: %s', yamlPath, ME.message);
end

if ~isfield(config, 'hardwareKind')
    error('tfp:io:loadConfig:badYaml', 'config must define hardwareKind.');
end
if ~ismember(lower(char(config.hardwareKind)), {'mock', 'real'})
    error('tfp:io:loadConfig:badYaml', ...
        'hardwareKind must be ''mock'' or ''real''; got ''%s''.', ...
        char(config.hardwareKind));
end
end

% --- Local helpers ---

function config = parseLines(lines)
config = struct();
currentParent = '';
for i = 1:numel(lines)
    line = char(lines(i));
    % strip comments
    hashIdx = strfind(line, '#');
    if ~isempty(hashIdx)
        line = line(1:hashIdx(1)-1);
    end
    if isempty(strtrim(line))
        continue;
    end
    trimmedLeft = regexprep(line, '^\s+', '');
    indent = numel(line) - numel(trimmedLeft);
    [key, value] = parseKeyValue(strtrim(line));

    if indent == 0
        if isempty(value)
            currentParent = key;
            config.(key) = struct();
        else
            currentParent = '';
            config.(key) = parseValue(value);
        end
    else
        if isempty(currentParent)
            error('Indented line without a parent section: %s', line);
        end
        if isempty(value)
            error('Nested mappings beyond one level not supported: %s', line);
        end
        config.(currentParent).(key) = parseValue(value);
    end
end
end

function [key, value] = parseKeyValue(s)
colonIdx = strfind(s, ':');
if isempty(colonIdx)
    error('Line missing colon: %s', s);
end
key   = strtrim(s(1:colonIdx(1)-1));
value = strtrim(s(colonIdx(1)+1:end));
end

function v = parseValue(s)
if isempty(s)
    v = [];
    return;
end
% Inline array
if startsWith(s, '[') && endsWith(s, ']')
    inner = s(2:end-1);
    parts = strtrim(strsplit(inner, ','));
    parts = parts(~cellfun(@isempty, parts));
    if isempty(parts)
        v = [];
        return;
    end
    nums = str2double(parts);
    if all(~isnan(nums))
        v = nums;
    else
        v = parts;
    end
    return;
end
% Booleans
if strcmp(s, 'true'),  v = true;  return; end
if strcmp(s, 'false'), v = false; return; end
% Numeric
num = str2double(s);
if ~isnan(num)
    v = num;
    return;
end
% Quoted string
if (startsWith(s, '"')  && endsWith(s, '"'))  || ...
   (startsWith(s, '''') && endsWith(s, ''''))
    v = s(2:end-1);
else
    v = s;
end
end
