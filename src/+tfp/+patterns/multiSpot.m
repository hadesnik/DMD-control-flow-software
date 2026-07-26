function mask = multiSpot(dmd, targetList, radiusPx, options)
%multiSpot Logical mask with multiple spots from targetList.
%
%   mask = multiSpot(dmd, targetList, radiusPx)
%   mask = multiSpot(dmd, targetList, radiusPx, options)
%
%   Inputs:
%     dmd         - object/struct with .nRows and .nCols.
%     targetList  - N x 2 numeric, one [col row] per row, DMD pixel coords.
%     radiusPx    - scalar positive, common radius for all spots. In the
%                   default isotropic mode this is the circle radius; in
%                   anisotropic mode it is the GROOVE-axis (long) semi-axis.
%     options     - optional scalar struct, identical in meaning to the
%                   tfp.patterns.singleSpot options:
%                     .anisotropic - logical, default false (historical
%                                    isotropic pixel circles).
%                     .model       - struct from tfp.util.opticalModel.
%                     .config      - config struct for tfp.util.opticalModel.
%
%   targetList rows are always DMD-pixel coords. To use sample-um inputs,
%   call tfp.patterns.calibratedAffine first.
%
%   Output:
%     mask        - logical(nRows, nCols). Union of N spots. Isotropic spots
%                   are circles; anisotropic spots are ellipses compressed by
%                   model.anisotropy along the (1,1) dispersion diagonal so
%                   that each SAMPLE spot is round.
%
%   The anisotropic geometry, the direction of the compression, and the
%   treatment of model.dispersionAxisSign are documented in full in
%   tfp.patterns.singleSpot; this function is the multi-target version of the
%   same mask and is verified against it in tests/test_patterns.m.
%
%   Errors: tfp:patterns:multiSpot:<reason>
%
%   See also tfp.patterns.singleSpot, tfp.util.opticalModel,
%            tfp.patterns.dmdToSampleOffset.

if nargin < 4
    options = struct();
end

try
    nRows = dmd.nRows;
    nCols = dmd.nCols;
catch ME
    error('tfp:patterns:multiSpot:badDmd', ...
        'dmd must expose .nRows and .nCols (got: %s).', ME.message);
end

if ~isnumeric(targetList) || ndims(targetList) > 2 || size(targetList, 2) ~= 2
    error('tfp:patterns:multiSpot:badTargetList', ...
        'targetList must be N x 2 numeric [col row]; got size [%s].', ...
        num2str(size(targetList)));
end

if ~isnumeric(radiusPx) || ~isscalar(radiusPx) || ~isfinite(radiusPx) || radiusPx <= 0
    error('tfp:patterns:multiSpot:badRadius', ...
        'radiusPx must be a positive finite scalar.');
end

[anisotropic, model, semiGroove] = resolveSpotOptions(options, 'multiSpot');
if anisotropic && isempty(semiGroove)
    semiGroove = radiusPx;
end

mask = false(nRows, nCols);
nTargets = size(targetList, 1);
if nTargets == 0
    return;
end

[cols, rows] = meshgrid(1:nCols, 1:nRows);

if ~anisotropic
    % Historical path, byte-for-byte unchanged.
    r2 = radiusPx^2;
    for k = 1:nTargets
        u = targetList(k, 1);
        v = targetList(k, 2);
        mask = mask | ((cols - u).^2 + (rows - v).^2 <= r2);
    end
    return;
end

for k = 1:nTargets
    u = targetList(k, 1);
    v = targetList(k, 2);
    % Per-target, so a sub-pixel ellipse still commands one mirror per cell
    % rather than silently dropping that cell from the ensemble.
    spot = diagonalEllipse(cols, rows, u, v, semiGroove, model);
    mask = mask | ensureOnPixel(spot, u, v);
end
end

% =========================================================================
% The three helpers below are verbatim copies of the ones in
% tfp.patterns.singleSpot (MATLAB local functions are not shareable across
% files, and TASK T-BU-1b may only touch these two sources). The
% multiSpot-equals-union-of-singleSpot test in tests/test_patterns.m fails if
% they ever drift apart.
% =========================================================================

function mask = diagonalEllipse(cols, rows, u, v, radiusPx, model)
%diagonalEllipse Ellipse with semi-axes on the chip diagonals.
%   Semi-axis radiusPx along the (1,-1) groove diagonal, radiusPx/anisotropy
%   along the (1,1) dispersion diagonal, so the sample spot is round. A DMD
%   pixel step along dispersion buys MORE sample um (1.4162 vs 1.1250), so
%   fewer pixels are needed there - hence the compression is along (1,1).
dc = cols - u;
dr = rows - v;

dDisp   = model.dispersionAxisSign * (dc + dr) / sqrt(2);
dGroove =                            (dc - dr) / sqrt(2);

semiGroove = radiusPx;                      % long  semi-axis, px
semiDisp   = radiusPx / model.anisotropy;   % short semi-axis, px

mask = (dDisp ./ semiDisp).^2 + (dGroove ./ semiGroove).^2 <= 1;
end

function mask = ensureOnPixel(mask, u, v)
%ensureOnPixel Guarantee a sub-pixel ellipse still commands at least one mirror.
if any(mask(:))
    return;
end
uu = round(u);
vv = round(v);
if uu >= 1 && uu <= size(mask, 2) && vv >= 1 && vv <= size(mask, 1)
    mask(vv, uu) = true;
end
end

function [anisotropic, model, semiGroove] = resolveSpotOptions(options, fname)
%resolveSpotOptions Validate the options struct and resolve optical constants.
%   semiGroove is [] unless the caller supplied an explicit groove-axis
%   semi-axis, in which case it OVERRIDES the positional radiusPx. This is what
%   makes tfp.patterns.somaSpotGeometry's .spotOptions hand-off work: that
%   struct carries .semiAxisGroovePx alongside an area-matched .radiusPx meant
%   for isotropic call sites, and silently using the latter here would paint a
%   spot ~17% short on pixels (67 rather than 81 for a soma) with no error.
%   Kept textually identical to the copy in tfp.patterns.singleSpot.
if isempty(options) && (isnumeric(options) || isstruct(options))
    options = struct();
end
if ~isstruct(options) || ~isscalar(options)
    error(sprintf('tfp:patterns:%s:badOptions', fname), ...
        'options must be a scalar struct (or empty); got %s of size [%s].', ...
        class(options), num2str(size(options)));
end

anisotropic = configField(options, 'anisotropic', false);
if ~(islogical(anisotropic) || isnumeric(anisotropic)) || ~isscalar(anisotropic) ...
        || ~ismember(double(anisotropic), [0 1])
    error(sprintf('tfp:patterns:%s:badAnisotropic', fname), ...
        'options.anisotropic must be a logical scalar (true/false).');
end
anisotropic = logical(anisotropic);

if ~anisotropic
    model = [];
    semiGroove = [];
    return;
end

semiGroove = configField(options, 'semiAxisGroovePx', []);
if ~isempty(semiGroove)
    if ~isnumeric(semiGroove) || ~isscalar(semiGroove) ...
            || ~isfinite(semiGroove) || semiGroove <= 0
        error(sprintf('tfp:patterns:%s:badSemiAxis', fname), ...
            'options.semiAxisGroovePx must be a positive finite scalar.');
    end
    semiGroove = double(semiGroove);
end

% tfp.util.opticalModel is the single source of truth for 1.1250/1.4162; a
% model struct fed back through it is a no-op, so both inputs land here.
model = configField(options, 'model', []);
if isempty(model)
    model = tfp.util.opticalModel(configField(options, 'config', struct()));
end
if ~isstruct(model) || ~isscalar(model) ...
        || ~all(isfield(model, {'anisotropy', 'dispersionAxisSign'}))
    error(sprintf('tfp:patterns:%s:badModel', fname), ...
        ['options.model must be a scalar struct from tfp.util.opticalModel ' ...
         '(needs .anisotropy and .dispersionAxisSign); got %s.'], class(model));
end
if ~isnumeric(model.anisotropy) || ~isscalar(model.anisotropy) ...
        || ~isfinite(model.anisotropy) || model.anisotropy <= 0
    error(sprintf('tfp:patterns:%s:badModel', fname), ...
        'options.model.anisotropy must be a positive finite scalar.');
end
end

function value = configField(s, name, default)
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    value = s.(name);
else
    value = default;
end
end
