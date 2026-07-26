function [pattern, info] = fillFactorEnsemble(dmd, centroids, radiusPx, fillFractions, options)
%fillFactorEnsemble Build a DMD frame where per-neuron power is set by fill factor.
%
%   Each neuron is represented by a circular disk of radius radiusPx pixels
%   centered at its DMD centroid. For each neuron a random subset of
%   round(fillFractions(k) * nPatchPixels(k)) pixels in that disk is turned
%   ON. The laser AO voltage stays fixed across trials; effective power per
%   neuron is set by the fraction of pixels in its disk that are ON.
%
%   HOW BIG IS THE DISK, REALLY. `radiusPx` is a count of mirrors, and the
%   mirrors are much bigger at the sample than the pilot assumed. The chip is
%   clocked 45 deg, so an isotropic pixel circle lands at the sample as an
%   ELLIPSE whose axes are the chip diagonals (docs/dmd_control_handoff.md
%   §5): 2*r*1.1250 um along the grooves and 2*r*1.4162 um along the
%   dispersion axis. At the design constants (in-bounds, no clipping):
%
%     radiusPx | sample ellipse (groove x disp) | disk pixels = power levels
%     ---------+-------------------------------+---------------------------
%         4    |   9.0 x 11.3 um               |    49
%         5    |  11.2 x 14.2 um   <- SOMA     |    81
%         6    |  13.5 x 17.0 um               |   113
%        14    |  31.5 x 39.7 um               |   613
%        15    |  33.8 x 42.5 um               |   709
%        17    |  38.2 x 48.2 um               |   901
%
%   Only the top three rows are cells. The bottom three are the repo's
%   pre-optics defaults (`radiusPx = 14`/`15`, and the `17` that hit the
%   ~900-px pilot target): the pixel arithmetic was right, but a 34 x 42 um
%   patch covers several neurons, which would destroy the single-cell
%   resolution the hero figure claims. Do not pick a radius by hand — call
%   tfp.patterns.somaSpotGeometry(diameterUm) and use its .radiusPx.
%
%   CONSEQUENCE FOR POWER RESOLUTION. Fill-factor control turns on n of the
%   K pixels in a neuron's disk, so K IS the number of power levels. A soma
%   is ~80 pixels, i.e. ~80 levels in 1.25% steps — ample, but >10x coarser
%   than the ~900 levels the pilot assumed. `info.nPowerLevels` reports it,
%   and a fill-fraction ladder spaced finer than 1/K (whose neighbouring
%   levels would produce identical patterns) raises
%   tfp:patterns:fillFactorEnsemble:fillQuantization.
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
%       .requestedFillLevels - numeric vector, the FULL fill-fraction ladder
%                       the caller intends to sweep across trials (e.g.
%                       0.1:0.1:1.0). This call only ever sees one fraction
%                       per neuron, so declare the ladder here to have the
%                       quantization check cover the whole sweep rather than
%                       just this frame. Default [] — the distinct values in
%                       `fillFractions` are used instead.
%       .warnOnQuantization - logical, default true. Set false to silence the
%                       fillQuantization warning (e.g. when the caller has
%                       already reported it once for the session).
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
%       .requestedFractions- N x 1, the fill fractions asked for (compare
%                            against .achievedFractions to see the
%                            quantization error on this frame).
%       .nPowerLevels      - N x 1, == .nPatchPixels. The number of distinct
%                            non-zero power levels reachable for that neuron.
%                            ~80 for a soma-sized spot.
%       .powerStepPct      - N x 1, 100 ./ .nPowerLevels, the finest power
%                            step in percent (~1.25% for a soma).
%       .permutations      - cell{N,1}, the permutations used. Pass this back
%                            in options.permutations for the next fill level
%                            to get nested subsets.
%       .patchBounds       - N x 4, [c0 c1 r0 r1] clipped bounding box of the
%                            disk on the DMD grid.
%
%   See also tfp.patterns.somaSpotGeometry, tfp.util.opticalModel,
%            tfp.experiments.exp_ensemble_fill_factor_power,
%            tfp.patterns.multiSpot.

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
perms_     = configField(options, 'permutations',        {});
rngSeed    = configField(options, 'rngSeed',             'shuffle');
fillLevels = configField(options, 'requestedFillLevels', []);
warnQuant  = configField(options, 'warnOnQuantization',  true);

if ~isempty(fillLevels) && (~isnumeric(fillLevels) || ~isvector(fillLevels) ...
        || any(~isfinite(fillLevels)) || any(fillLevels < 0) || any(fillLevels > 1))
    error('tfp:patterns:fillFactorEnsemble:badFillLevels', ...
        'options.requestedFillLevels must be empty or a finite numeric vector in [0, 1].');
end

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

    % Select an EXACT pixel count from the rasterized patch rather than
    % trusting the analytic disk area: at soma size K is only ~80 and the
    % rasterized count differs from pi*r^2 by several pixels.
    nOn = round(fillFractions(k) * K);
    nOn = max(0, min(K, nOn));
    % perms_{k} is a fixed random ordering of this patch's pixels, so taking
    % the first nOn of it makes every lower fill level a strict SUBSET of
    % every higher one (nested subsets, no pattern variance across a power
    % sweep). That matters more now that 10% fill is ~8 pixels, not ~90.
    onLin = patchLin(perms_{k}(1:nOn));

    m = false(nRows, nCols);
    m(onLin) = true;
    neuronMasks{k} = m;
    pattern = pattern | m;
    nOnPixels(k) = nOn;
end

% --- Output info -------------------------------------------------------------
info.neuronMasks        = neuronMasks;
info.nPatchPixels       = nPatchPixels;
info.nOnPixels          = nOnPixels;
info.achievedFractions  = nOnPixels ./ max(1, nPatchPixels);
info.requestedFractions = fillFractions;
% The patch pixel count IS the power resolution: n of K pixels ON gives K
% distinct non-zero levels. ~80 for a soma-sized spot, not the ~900 the pilot
% assumed. See tfp.patterns.somaSpotGeometry.
info.nPowerLevels       = nPatchPixels;
info.powerStepPct       = 100 ./ max(1, nPatchPixels);
info.permutations       = perms_;
info.patchBounds        = patchBounds;

% --- Quantization advisory ---------------------------------------------------
if warnQuant
    warnIfLevelsCollide(fillLevels, fillFractions, nPatchPixels);
end
end

% =========================================================================

function warnIfLevelsCollide(fillLevels, fillFractions, nPatchPixels)
%warnIfLevelsCollide Warn when requested fill levels quantize to one pattern.
%   Two fill fractions closer together than 1/K round to the same ON-pixel
%   count and therefore produce the IDENTICAL frame — the caller believes it
%   swept two power levels but delivered one. Checked against the coarsest
%   (smallest) neuron patch, which collides first.

% Prefer the caller's declared sweep ladder; a single call only ever carries
% one fraction per neuron, so without it we can only see this frame.
if isempty(fillLevels)
    fillLevels = fillFractions;
end
levels = unique(double(fillLevels(:)));
levels = levels(isfinite(levels));
if numel(levels) < 2
    return;
end

valid = nPatchPixels(nPatchPixels > 0);
if isempty(valid)
    return;
end
K = min(valid);   % coarsest patch — collides at the widest spacing

nOn = round(levels * K);
if numel(unique(nOn)) == numel(nOn)
    return;
end

% Report the tightest offending pair so the message is actionable.
collide  = find(diff(nOn) == 0, 1, 'first');
minStep  = min(diff(levels));
warning('tfp:patterns:fillFactorEnsemble:fillQuantization', ...
    ['Requested fill levels are finer than this spot can resolve: the ' ...
     'smallest neuron patch has %d pixels, so only %d power levels exist ' ...
     '(%.2f%% steps, minimum fill-fraction step %.4f). Requested levels ' ...
     '%.4f and %.4f both quantize to %d ON pixels and will produce the ' ...
     'IDENTICAL pattern (%d distinct levels requested, tightest spacing ' ...
     '%.4f). Ask for at most %d levels, or use a larger spot ' ...
     '(tfp.patterns.somaSpotGeometry).'], ...
    K, K, 100 / K, 1 / K, ...
    levels(collide), levels(collide + 1), nOn(collide), ...
    numel(levels), minStep, K);
end

% =========================================================================

function value = configField(s, name, default)
if isfield(s, name)
    value = s.(name);
else
    value = default;
end
end
