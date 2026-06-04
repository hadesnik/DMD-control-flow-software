function effMap = loadEfficiencyMap(file)
%loadEfficiencyMap Load a spatially-varying photostimulation efficiency map.
%
%   effMap = tfp.patterns.threeDShot.loadEfficiencyMap(file)
%
%   Parses a .mat file containing a 2-D efficiency map (values in (0,1])
%   sampled on a regular grid.  When the file argument is empty or omitted,
%   returns a uniform-efficiency struct, which causes efficiencyAtTargets to
%   return ones for all targets.
%
%   Inputs:
%     file - char | string. Path to a .mat efficiency map file.  Pass '' or
%            omit to request the uniform fallback.
%
%   Output: struct with fields
%     .type   - 'uniform' | 'grid'
%     .source - char, resolved file path or 'uniform'
%     --- grid only ---
%     .eff    - Ny_map × Nx_map double matrix, efficiency values in (0,1].
%     .x_um   - 1×Nx_map (or column) double vector, x grid coordinates (µm).
%     .y_um   - 1×Ny_map (or column) double vector, y grid coordinates (µm).
%
%   Errors:
%     tfp:patterns:threeDShot:loadEfficiencyMap:fileNotFound
%     tfp:patterns:threeDShot:loadEfficiencyMap:badSchema
%
%   %VERIFY: Real .mat schema to be confirmed once the efficiency calibration
%   sweep is performed on the rig.  Expected required fields: eff (matrix),
%   x_um (vector), y_um (vector).

ERR_BASE = 'tfp:patterns:threeDShot:loadEfficiencyMap';

% --- Uniform fallback ---
if nargin < 1 || isempty(file)
    effMap = uniformEffMap();
    return;
end

file = char(file);

if isempty(strtrim(file))
    effMap = uniformEffMap();
    return;
end

% --- File must exist ---
if ~isfile(file)
    error([ERR_BASE ':fileNotFound'], ...
        'Efficiency map file not found: %s', file);
end

% --- Load and validate ---
%VERIFY: schema confirmed once efficiency calibration sweep is collected.
try
    S = load(file, '-mat');
catch ME
    error([ERR_BASE ':badSchema'], ...
        'Could not load efficiency map file "%s": %s', file, ME.message);
end

required = {'eff', 'x_um', 'y_um'};
for k = 1:numel(required)
    if ~isfield(S, required{k})
        error([ERR_BASE ':badSchema'], ...
            ['Efficiency map file "%s" is missing required field "%s". ' ...
             'Expected fields: eff (matrix), x_um (vector), y_um (vector).'], ...
            file, required{k});
    end
end

eff  = double(S.eff);
x_um = double(S.x_um(:)');   % ensure row vector for interp2
y_um = double(S.y_um(:)');

% Basic dimensional consistency check.
if ~isequal(size(eff), [numel(y_um), numel(x_um)])
    error([ERR_BASE ':badSchema'], ...
        ['Efficiency map size mismatch in "%s": eff is %dx%d but ' ...
         'numel(y_um)=%d, numel(x_um)=%d.'], ...
        file, size(eff,1), size(eff,2), numel(y_um), numel(x_um));
end

effMap = struct( ...
    'type',   'grid', ...
    'eff',    eff, ...
    'x_um',   x_um, ...
    'y_um',   y_um, ...
    'source', file);
end

% --- Local helpers ---
function effMap = uniformEffMap()
effMap = struct('type', 'uniform', 'source', 'uniform');
end
