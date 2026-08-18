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
%     - lists of scalars (block sequences), under a top-level OR a
%       one-level-nested key — so per-item '#' comments survive, which is
%       how the DAQ line assignments document themselves:
%         daq:
%           digitalOutChannels:
%             - 'port0/line10'   # ScanImage acquisition trigger
%             - 'port0/line8'    # SLM sequence-advance TTL
%       Yields the same shape as the inline form: a numeric row vector when
%       every item is numeric, otherwise a cell array.
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
    fid      = fopen(yamlPath, 'r');
    raw      = fread(fid, '*char')';
    fclose(fid);
    raw      = raw(raw ~= char(13));        % strip \r so CRLF files parse on Windows
    rawLines = string(strsplit(raw, char(10)));
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
%   Handles flat keys, one-level nested mappings, and block sequences whose
%   items are either mappings (- key: val) or scalars (- val).

config        = struct();
currentParent = '';  % key of the currently open mapping section
inListMode    = false;
listPath      = {};  % {key} or {parent, key} — where the sequence is stored
listIndent    = 0;   % indent of the key that opened the sequence
listKind      = '';  % 'map' | 'scalar', decided by the first item
listOpenLine  = 0;   % remembered so an item-less key reports the old error
listOpenText  = '';
currentItem   = struct();
allItems      = {};  % cell array of per-item structs   (map kind)
scalarItems   = {};  % cell array of parsed scalars     (scalar kind)

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
    isItem      = strncmp(trimmedLeft, '- ', 2) || strcmp(trimmedLeft, '-');

    % ------------------------------------------------------------------
    % Branch 1: currently inside a block sequence.
    % ------------------------------------------------------------------
    if inListMode
        if isItem && indent > listIndent
            rest = strtrim(trimmedLeft(2:end));
            if isMappingItem(rest)
                listKind    = requireKind(listKind, 'map', i, line);
                allItems    = appendItem(allItems, currentItem);
                currentItem = struct();
                [k, v]      = parseKeyValue(rest);
                currentItem.(k) = parseValue(v);
            else
                listKind = requireKind(listKind, 'scalar', i, line);
                scalarItems{end+1} = parseValue(rest); %#ok<AGROW>
            end
            continue;

        elseif ~isItem && indent > listIndent && strcmp(listKind, 'map')
            % Continuation key-value within the current mapping item.
            [k, v]          = parseKeyValue(strtrim(line));
            currentItem.(k) = parseValue(v);
            continue;
        end

        % Anything else closes the sequence; fall through and reprocess
        % this line as ordinary content.
        [config, opened] = closeList(config, listPath, listKind, ...
            allItems, currentItem, scalarItems);
        if ~opened
            % The key opened nothing at all — it was a deeper mapping.
            error('Nested mappings beyond one level not supported on line %d: %s', ...
                listOpenLine, listOpenText);
        end
        inListMode  = false;
        listPath    = {};
        listKind    = '';
        currentItem = struct();
        allItems    = {};
        scalarItems = {};
    end

    % ------------------------------------------------------------------
    % Branch 2: normal (non-sequence) processing.
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

    elseif isItem
        % Block sequence directly under a top-level section key.
        if isempty(currentParent)
            error('List item without a parent section on line %d: %s', i, line);
        end
        inListMode   = true;
        listPath     = {currentParent};
        listIndent   = 0;
        listKind     = '';
        listOpenLine = i;
        listOpenText = line;
        currentItem  = struct();
        allItems     = {};
        scalarItems  = {};
        rest = strtrim(trimmedLeft(2:end));
        if isMappingItem(rest)
            listKind        = 'map';
            [k, v]          = parseKeyValue(rest);
            currentItem.(k) = parseValue(v);
        elseif ~isempty(rest)
            listKind           = 'scalar';
            scalarItems{end+1} = parseValue(rest); %#ok<AGROW>
        end

    else
        % Indented key under currentParent.
        if isempty(currentParent)
            error('Indented line without a parent section on line %d: %s', i, line);
        end
        [key, value] = parseKeyValue(strtrim(line));
        if isempty(value)
            % The only legal continuation is a block sequence on the lines
            % below; if none arrives this is a >1-level nested mapping and
            % closeList reports it as such.
            inListMode   = true;
            listPath     = {currentParent, key};
            listIndent   = indent;
            listKind     = '';
            listOpenLine = i;
            listOpenText = line;
            currentItem  = struct();
            allItems     = {};
            scalarItems  = {};
        else
            config.(currentParent).(key) = parseValue(value);
        end
    end
end

% Close any sequence still open at end of file.
if inListMode
    [config, opened] = closeList(config, listPath, listKind, ...
        allItems, currentItem, scalarItems);
    if ~opened
        error('Nested mappings beyond one level not supported on line %d: %s', ...
            listOpenLine, listOpenText);
    end
end
end

% --------------------------------------------------------------------------

function items = appendItem(items, item)
%appendItem Append item struct to the items cell array (skip if empty).
if ~isempty(fieldnames(item))
    items{end+1} = item;
end
end

function tf = isMappingItem(rest)
%isMappingItem True when a sequence item reads as `key: value`.
%   Matched on a leading identifier + colon rather than "contains a colon",
%   so quoted scalars ('- ''a: b''') and paths ('- port0/line10') are not
%   mistaken for mappings.
tf = ~isempty(regexp(rest, '^[A-Za-z_]\w*\s*:', 'once'));
end

function kind = requireKind(kind, want, i, line)
%requireKind Lock a sequence to its first item's kind; reject mixtures.
if isempty(kind)
    kind = want;
elseif ~strcmp(kind, want)
    error('Mixed scalar and mapping items in one list on line %d: %s', i, line);
end
end

function [config, opened] = closeList(config, listPath, listKind, ...
                                      allItems, currentItem, scalarItems)
%closeList Store a finished block sequence at listPath.
%   opened is false when the key that opened this sequence never received
%   an item — meaning it was not a sequence at all, and the caller reports
%   the unsupported-nesting error against the opening line.
opened = true;
switch listKind
    case 'map'
        allItems = appendItem(allItems, currentItem);
        value    = cellToStructArray(allItems);
    case 'scalar'
        value    = scalarsToArray(scalarItems);
    otherwise
        opened = false;
        return;
end
if numel(listPath) == 1
    config.(listPath{1}) = value;
else
    config.(listPath{1}).(listPath{2}) = value;
end
end

function v = scalarsToArray(items)
%scalarsToArray Numeric row vector when every item is numeric, else a cell
%   array — the same shapes parseValue produces for the inline form.
if isempty(items)
    v = {};
    return;
end
isNum = cellfun(@(x) isnumeric(x) && isscalar(x), items);
if all(isNum)
    v = [items{:}];
else
    v = items;
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
