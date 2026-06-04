function lut = loadPhaseLUT(lutFile)
%loadPhaseLUT Load a per-drive-level phase calibration vector from disk.
%
%   lut = tfp.patterns.threeDShot.loadPhaseLUT(lutFile)
%
%   lutFile is a path to a LUT file containing 256 measured phase values (one
%   per drive level 0..255, in radians).  Returns lut as a 256-element double
%   column vector.
%
%   Empty input, empty string, or a missing argument → returns [] (caller
%   interprets as "no LUT / use linear mapping").
%   .mat files: first numeric field is taken and reshaped to a column.
%   All other extensions: read with readmatrix and reshaped to a column.
%   Throws tfp:patterns:threeDShot:loadPhaseLUT:fileNotFound if a non-empty
%   path is given but the file does not exist. Read-only: no hardware, no I/O
%   side-effects.

if nargin < 1 || isempty(lutFile) || (ischar(lutFile) && numel(strtrim(lutFile)) == 0)
    lut = [];
    return
end

if ~isfile(lutFile)
    error('tfp:patterns:threeDShot:loadPhaseLUT:fileNotFound', ...
        'LUT file not found: %s', lutFile);
end

[~, ~, ext] = fileparts(lutFile);

if strcmpi(ext, '.mat')
    S = load(lutFile);
    fields = fieldnames(S);
    % Find first numeric field
    found = false;
    for k = 1:numel(fields)
        v = S.(fields{k});
        if isnumeric(v)
            lut = double(v(:));
            found = true;
            break
        end
    end
    if ~found
        error('tfp:patterns:threeDShot:loadPhaseLUT:fileNotFound', ...
            'No numeric field found in MAT file: %s', lutFile);
    end
else
    data = readmatrix(lutFile);
    lut = double(data(:));
end
end
