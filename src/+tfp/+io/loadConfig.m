function config = loadConfig(yamlPath)
%loadConfig Parse a small YAML config into a struct.
%
%   Phase 1/1.5 hand-parser. Supports:
%     - top-level scalar keys: `name: value`
%     - one level of nested mapping (indented scalar keys):
%         section:
%           child: value
%     - lists of mappings (indented `- key: val` blocks):
%         items:
%           - tag: foo
%             val: 1
%           - tag: bar
%             val: 2
%     - scalar values: numbers, true/false, bare strings, quoted strings
%     - inline arrays: [a, b, c]
%     - '#' line comments
%
%   Not supported: lists of lists; anchors/aliases; flow-style mappings;
%   multi-line strings; nested mappings beyond one level.
%
%   Always validates that config.hardwareKind is 'mock' or 'real'.
%
%   Post-processing guarantees:
%     config.fakeCells — 1×N struct array with fields
%                        {tag, dmdCol, dmdRow, radiusDmd, amplitude, aiChannel}
%                        Empty typed struct array when fakeCells is absent.
%     config.imaging   — struct (empty struct when imaging section is absent).
%
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
    config   = parseLines(rawLines);
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

% --- Post-processing: normalise fakeCells ---
% Ensure fakeCells is always a typed struct array regardless of whether the
% section is absent, empty, or populated.  Callers can use isempty(config.fakeCells)
% without checking isfield first.
EMPTY_FAKE_CELLS = struct('tag', {}, 'dmdCol', {}, 'dmdRow', {}, ...
                          'radiusDmd', {}, 'amplitude', {}, 'aiChannel', {});
if ~isfield(config, 'fakeCells') || ...
        (isstruct(config.fakeCells) && isempty(fieldnames(config.fakeCells)))
    config.fakeCells = EMPTY_FAKE_CELLS;
end

% --- Post-processing: normalise imaging section ---
if ~isfield(config, 'imaging')
    config.imaging = struct();
end
end

% =========================================================================
% Local helpers
% =========================================================================

function config = parseLines(lines)
%parseLines Convert a cell/string array of YAML lines into a struct.
%   Handles flat keys, one-level nested mappings, and lists of mappings.

config        = struct();
currentParent = '';  % key of the currently open mapping section
inListMode    = false;
listParent    = '';  % key under which the list will be stored
currentItem   = struct();
allItems      = {};  % cell array of per-item structs

for i = 1:numel(lines)
    line = char(lines(i));

    % Strip inline '#' comments.
    hashIdx = strfind(line, '#');
    if ~isempty(hashIdx)
        line = line(1:hashIdx(1)-1);
    end
    if isempty(strtrim(line))
        continue;
    end

    trimmedLeft = regexprep(line, '^\s+', '');
    indent      = numel(line) - numel(trimmedLeft);

    % ------------------------------------------------------------------
    % Branch 1: currently inside a list-of-mappings block.
    % ------------------------------------------------------------------
    if inListMode
        if indent == 0
            % A top-level key closes the list.  Save and fall through.
            allItems = appendItem(allItems, currentItem);
            config.(listParent) = cellToStructArray(allItems);
            inListMode  = false;
            listParent  = '';
            currentItem = struct();
            allItems    = {};
            % Fall through to top-level handling of this line.

        elseif strncmp(trimmedLeft, '- ', 2)
            % A new list item at the same indent level.
            allItems    = appendItem(allItems, currentItem);
            currentItem = struct();
            rest = strtrim(trimmedLeft(3:end));
            if ~isempty(rest) && ~isempty(strfind(rest, ':'))
                [k, v]        = parseKeyValue(rest);
                currentItem.(k) = parseValue(v);
            end
            continue;

        else
            % Continuation key-value within the current list item.
            [k, v]        = parseKeyValue(strtrim(line));
            currentItem.(k) = parseValue(v);
            continue;
        end
    end

    % ------------------------------------------------------------------
    % Branch 2: normal (non-list) processing.
    % ------------------------------------------------------------------
    if indent == 0
        [key, value] = parseKeyValue(strtrim(line));
        if isempty(value)
            currentParent = key;
            config.(key)  = struct();
        else
            currentParent = '';
            config.(key)  = parseValue(value);
        end

    elseif strncmp(trimmedLeft, '- ', 2)
        % Start of a list under currentParent.
        if isempty(currentParent)
            error('List item without a parent section on line %d: %s', i, line);
        end
        inListMode  = true;
        listParent  = currentParent;
        currentItem = struct();
        allItems    = {};
        rest = strtrim(trimmedLeft(3:end));
        if ~isempty(rest) && ~isempty(strfind(rest, ':'))
            [k, v]        = parseKeyValue(rest);
            currentItem.(k) = parseValue(v);
        end

    else
        % Indented key-value under currentParent (one-level nested mapping).
        if isempty(currentParent)
            error('Indented line without a parent section on line %d: %s', i, line);
        end
        [key, value] = parseKeyValue(strtrim(line));
        if isempty(value)
            error('Nested mappings beyond one level not supported on line %d: %s', i, line);
        end
        config.(currentParent).(key) = parseValue(value);
    end
end

% Close any list still open at end of file.
if inListMode
    allItems = appendItem(allItems, currentItem);
    config.(listParent) = cellToStructArray(allItems);
end
end

% --------------------------------------------------------------------------

function items = appendItem(items, item)
%appendItem Append item struct to the items cell array (skip if empty).
if ~isempty(fieldnames(item))
    items{end+1} = item;
end
end

function sa = cellToStructArray(items)
%cellToStructArray Convert a cell array of structs to a 1×N struct array.
if isempty(items)
    sa = struct();
    return;
end
sa = items{1};
for i = 2:numel(items)
    sa(i) = items{i};
end
end

% --------------------------------------------------------------------------

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
