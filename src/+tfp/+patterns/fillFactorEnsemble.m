function [pattern, info] = fillFactorEnsemble(dmd, centroids, radiusPx, fillFractions, options)
%fillFactorEnsemble Build a DMD frame where per-neuron power is set by fill factor.
%
%   Each neuron is represented by a circular disk of radius radiusPx pixels
%   centered at its DMD centroid. For each neuron a random subset of
%   round(fillFractions(k) * nPatchPixels(k)) pixels in that disk is turned
%   ON. The laser AO voltage stays fixed across trials; effective power per
%   neuron is set by the fraction of pixels in its disk that are ON.
%
%   Disk pixel counts for typical radii (in-bounds, no clipping):
%     radiusPx = 15  ->  ~709 pixels  (diameter ~ 30 px)
%     radiusPx = 17  ->  ~925 pixels  (closest to the 900-px pilot target)
%     radiusPx = 20  ->  ~1257 pixels
%
%   [pattern, info] = fillFactorEnsemble(dmd, centroids, radiusPx, fillFractions)
%   [pattern, info] = fillFactorEnsemble(dmd, centroids, radiusPx, fillFractions, options)
%
%   Inputs:
%     dmd            - object with .nRows and .nCols (e.g. tfp.hardware.DMD).
%     centroids      - N x 2 numeric, [col row] DMD pixel coords (1-indexed,
%                      origin top-left per CLAUDE.md).
%     radiusPx       - scalar positive, disk radius in DMD pixels.
%     fillFractions  - N x 1 or 1 x N in [0, 1], one fill fraction per neuron.
%                      A scalar is broadcast to all N neurons.
%     options - struct (all fields optional):
%       .permutations - cell{N,1}. Each cell is a 1 x nPatchPixels(k) random
%                       permutation of that neuron's in-bounds patch-pixel
%                       indices. Pass back the .permutations field from a prior
%                       call to keep the random pixel ordering stable across
%                       successive fill-fraction levels — this guarantees the
%                       10% ON pixels are a strict subset of the 20% ON pixels
%                       and so on (nested subsets, no pattern variance across
%                       the power sweep). If empty, fresh permutations are
%                       drawn (default {}).
%       .rngSeed      - Seed for fresh permutations (default 'shuffle'). Only
%                       used when .permutations is empty. Pass [] to leave
%                       the global RNG state untouched — useful when the
%                       caller seeds once at session start and wants every
%                       independent call to advance the same RNG sequence.
%
%   Outputs:
%     pattern - logical(nRows, nCols), the union of all per-neuron ON pixels.
%     info - struct:
%       .neuronMasks       - cell{N,1} of logical(nRows, nCols), one per neuron.
%       .nPatchPixels      - N x 1, in-bounds patch size per neuron (size of
%                            the disk, reduced if the disk extends past a DMD
%                            edge).
%       .nOnPixels         - N x 1, number of pixels actually turned ON.
%       .achievedFractions - N x 1, nOnPixels ./ nPatchPixels.
%       .permutations      - cell{N,1}, the permutations used. Pass this back
%                            in options.permutations for the next fill level
%                            to get nested subsets.
%       .patchBounds       - N x 4, [c0 c1 r0 r1] clipped bounding box of the
%                            disk on the DMD grid.
%
%   See also tfp.experiments.exp_ensemble_fill_factor_power, tfp.patterns.multiSpot.

% --- Validate inputs ---------------------------------------------------------
try
    nRows = dmd.nRows;
    nCols = dmd.nCols;
catch ME
    error('tfp:patterns:fillFactorEnsemble:badDmd', ...
        'dmd must expose .nRows and .nCols (got: %s).', ME.message);
end

if ~isnumeric(centroids) || ndims(centroids) ~= 2 || size(centroids, 2) ~= 2
    error('tfp:patterns:fillFactorEnsemble:badCentroids', ...
        'centroids must be N x 2 numeric [col row]; got size [%s].', ...
        num2str(size(centroids)));
end
N = size(centroids, 1);

if ~isnumeric(radiusPx) || ~isscalar(radiusPx) ...
        || ~isfinite(radiusPx) || radiusPx <= 0
    error('tfp:patterns:fillFactorEnsemble:badRadius', ...
        'radiusPx must be a positive finite scalar.');
end

if isscalar(fillFractions)
    fillFractions = repmat(fillFractions, N, 1);
end
fillFractions = fillFractions(:);
if numel(fillFractions) ~= N
    error('tfp:patterns:fillFactorEnsemble:badFractions', ...
        'fillFractions must be scalar or length-N; got %d for N=%d.', ...
        numel(fillFractions), N);
end
if any(~isfinite(fillFractions)) || any(fillFractions < 0) || any(fillFractions > 1)
    error('tfp:patterns:fillFactorEnsemble:badFractions', ...
        'fillFractions entries must be finite values in [0, 1].');
end

if nargin < 5 || isempty(options)
    options = struct();
end
perms_  = configField(options, 'permutations', {});
rngSeed = configField(options, 'rngSeed',      'shuffle');

if ~iscell(perms_) || (~isempty(perms_) && numel(perms_) ~= N)
    error('tfp:patterns:fillFactorEnsemble:badPerms', ...
        'options.permutations must be empty or a cell array of length N.');
end

freshPerms = isempty(perms_);
if freshPerms
    if ~isempty(rngSeed)
        rng(rngSeed);
    end
    perms_ = cell(N, 1);
end

% --- Build per-neuron masks --------------------------------------------------
pattern       = false(nRows, nCols);
neuronMasks   = cell(N, 1);
nPatchPixels  = zeros(N, 1);
nOnPixels     = zeros(N, 1);
patchBounds   = zeros(N, 4);

rCeil = ceil(radiusPx);
r2    = radiusPx^2;

for k = 1:N
    c = centroids(k, 1);
    r = centroids(k, 2);
    % Bounding box around the disk, clipped to DMD bounds.
    cc0 = max(1, floor(c - rCeil));  cc1 = min(nCols, ceil(c + rCeil));
    rr0 = max(1, floor(r - rCeil));  rr1 = min(nRows, ceil(r + rCeil));
    patchBounds(k, :) = [cc0, cc1, rr0, rr1];

    if cc0 > cc1 || rr0 > rr1
        neuronMasks{k} = false(nRows, nCols);
        warning('tfp:patterns:fillFactorEnsemble:patchOutOfBounds', ...
            'Neuron %d at [%g %g] has no in-bounds pixels on a %dx%d DMD.', ...
            k, c, r, nCols, nRows);
        continue;
    end

    % Keep only pixels inside the disk (Euclidean distance to centroid <= radius).
    [colsGrid, rowsGrid] = meshgrid(cc0:cc1, rr0:rr1);
    inDisk = (colsGrid - c).^2 + (rowsGrid - r).^2 <= r2;
    patchLin = sub2ind([nRows, nCols], rowsGrid(inDisk), colsGrid(inDisk));
    K = numel(patchLin);
    nPatchPixels(k) = K;

    if K == 0
        neuronMasks{k} = false(nRows, nCols);
        continue;
    end

    if freshPerms || isempty(perms_{k})
        perms_{k} = randperm(K);
    elseif numel(perms_{k}) ~= K
        error('tfp:patterns:fillFactorEnsemble:permSizeMismatch', ...
            ['options.permutations{%d} has length %d but neuron %d has %d ' ...
             'in-bounds patch pixels. Re-run without permutations to refresh.'], ...
            k, numel(perms_{k}), k, K);
    end

    nOn = round(fillFractions(k) * K);
    nOn = max(0, min(K, nOn));
    onLin = patchLin(perms_{k}(1:nOn));

    m = false(nRows, nCols);
    m(onLin) = true;
    neuronMasks{k} = m;
    pattern = pattern | m;
    nOnPixels(k) = nOn;
end

% --- Output info -------------------------------------------------------------
info.neuronMasks       = neuronMasks;
info.nPatchPixels      = nPatchPixels;
info.nOnPixels         = nOnPixels;
info.achievedFractions = nOnPixels ./ max(1, nPatchPixels);
info.permutations      = perms_;
info.patchBounds       = patchBounds;
end

% =========================================================================

function value = configField(s, name, default)
if isfield(s, name)
    value = s.(name);
else
    value = default;
end
end
