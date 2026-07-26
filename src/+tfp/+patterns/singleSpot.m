function mask = singleSpot(dmd, targetCoords, radiusPx, options)
%singleSpot Logical mask with one spot at targetCoords on the DMD.
%
%   mask = singleSpot(dmd, targetCoords, radiusPx)
%   mask = singleSpot(dmd, targetCoords, radiusPx, options)
%
%   Inputs:
%     dmd          - object/struct exposing .nRows and .nCols (DMD geometry).
%     targetCoords - 1x2 numeric [col row] in DMD pixel coords, 1-indexed,
%                    origin top-left (per CLAUDE.md).
%     radiusPx     - scalar positive, spot radius in DMD pixels. In the default
%                    isotropic mode this is the circle radius. In anisotropic
%                    mode it is the GROOVE-axis (long) semi-axis; see below.
%     options      - optional scalar struct. Fields (all optional):
%                      .anisotropic - logical, default false. When false the
%                                     behaviour is exactly the historical
%                                     isotropic pixel circle.
%                      .model       - a struct from tfp.util.opticalModel. If
%                                     absent it is built from .config.
%                      .config      - config struct passed to
%                                     tfp.util.opticalModel; default all
%                                     defaults. Ignored when .model is given.
%
%   targetCoords are always DMD-pixel coords. To use sample-um inputs,
%   call tfp.patterns.calibratedAffine first.
%
%   Output:
%     mask         - logical(nRows, nCols).
%                    Isotropic (default): true wherever the Euclidean distance
%                    to targetCoords is <= radiusPx (boundary inclusive).
%                    Anisotropic: true inside an ellipse whose semi-axes lie
%                    along the chip DIAGONALS, compressed by model.anisotropy
%                    along the (1,1) dispersion diagonal, so that the spot is
%                    ROUND at the sample (radius radiusPx*umPerPixelGroove um).
%
%   ANISOTROPIC MODE — why the compression goes the way it does.
%   The chip is clocked 45 degrees, so the optical axes are the chip diagonals
%   (docs/dmd_control_handoff.md §5):
%       d_disp   = (dc + dr)/sqrt(2)   px, along the grating's dispersion axis
%       d_groove = (dc - dr)/sqrt(2)   px, along the grooves
%       x_disp   = d_disp   * umPerPixelDispersion   (1.4162 um/px)
%       y_groove = d_groove * umPerPixelGroove       (1.1250 um/px)
%   A DMD pixel step along the DISPERSION diagonal buys MORE sample um than a
%   step along the groove diagonal (1.4162 > 1.1250). So to span the same
%   physical um you need FEWER pixels along dispersion -> the pixel-space
%   ellipse is SHORTER along (1,1). Equivalently, imposing roundness at the
%   sample, x_disp^2 + y_groove^2 <= R_um^2, and substituting gives
%       (d_disp/(R_um/1.4162))^2 + (d_groove/(R_um/1.1250))^2 <= 1
%   i.e. semi-axes R_um/1.4162 px (dispersion) and R_um/1.1250 px (groove).
%   The groove semi-axis is the LARGER one, by exactly model.anisotropy
%   (= 1.2588). Getting this backwards yields a spot wrong in aspect ratio by
%   anisotropy^2 = 1.58, which is why it is spelled out here.
%   Sanity check in the other direction: drawing a pixel CIRCLE (the default)
%   gives a sample ellipse 1.26x longer along dispersion, exactly as §5 warns.
%
%   model.dispersionAxisSign is consulted for consistency with
%   tfp.patterns.dmdToSampleOffset, which writes d_disp = s*(dc + dr)/sqrt(2).
%   The mask is provably invariant to it: the ellipse is centrosymmetric and s
%   enters only squared. Flipping the sign therefore cannot change a spot, only
%   the direction a target is displaced in - that lives in the coordinate map,
%   not here.
%
%   These ellipses are COARSE. A soma-sized (~12.7 um diameter) target is only
%   ~80 DMD pixels, semi-axes ~5.7 x 4.5 px. At that size the mask is
%   guaranteed to contain at least one ON pixel (the rounded target pixel) even
%   if the ellipse falls entirely between sample points.
%
%   Errors: tfp:patterns:singleSpot:<reason>
%
%   See also tfp.patterns.multiSpot, tfp.util.opticalModel,
%            tfp.patterns.dmdToSampleOffset.

if nargin < 4
    options = struct();
end

try
    nRows = dmd.nRows;
    nCols = dmd.nCols;
catch ME
    error('tfp:patterns:singleSpot:badDmd', ...
        'dmd must expose .nRows and .nCols (got: %s).', ME.message);
end

if ~isnumeric(targetCoords) || numel(targetCoords) ~= 2
    error('tfp:patterns:singleSpot:badTarget', ...
        'targetCoords must be 1x2 numeric [col row]; got size [%s].', ...
        num2str(size(targetCoords)));
end

if ~isnumeric(radiusPx) || ~isscalar(radiusPx) || ~isfinite(radiusPx) || radiusPx <= 0
    error('tfp:patterns:singleSpot:badRadius', ...
        'radiusPx must be a positive finite scalar.');
end

[anisotropic, model, semiGroove] = resolveSpotOptions(options, 'singleSpot');

uTarget = targetCoords(1);  % column
vTarget = targetCoords(2);  % row

[cols, rows] = meshgrid(1:nCols, 1:nRows);

if ~anisotropic
    % Historical path, byte-for-byte unchanged.
    mask = (cols - uTarget).^2 + (rows - vTarget).^2 <= radiusPx^2;
    return;
end

if isempty(semiGroove)
    semiGroove = radiusPx;
end

mask = diagonalEllipse(cols, rows, uTarget, vTarget, semiGroove, model);
mask = ensureOnPixel(mask, uTarget, vTarget);
end

% =========================================================================

function mask = diagonalEllipse(cols, rows, u, v, radiusPx, model)
%diagonalEllipse Ellipse with semi-axes on the chip diagonals.
%   Semi-axis radiusPx along the (1,-1) groove diagonal, radiusPx/anisotropy
%   along the (1,1) dispersion diagonal, so the sample spot is round. See the
%   direction argument in the header of this file.
dc = cols - u;
dr = rows - v;

% 1/sqrt(2) makes these unit-vector projections, so both stay in DMD pixels.
% dispersionAxisSign enters only through a square below, so it cannot flip
% which diagonal is compressed; it is applied anyway to keep this expression
% textually identical to tfp.patterns.dmdToSampleOffset.
dDisp   = model.dispersionAxisSign * (dc + dr) / sqrt(2);
dGroove =                            (dc - dr) / sqrt(2);

semiGroove = radiusPx;                      % long  semi-axis, px
semiDisp   = radiusPx / model.anisotropy;   % short semi-axis, px

mask = (dDisp ./ semiDisp).^2 + (dGroove ./ semiGroove).^2 <= 1;
end

function mask = ensureOnPixel(mask, u, v)
%ensureOnPixel Guarantee a sub-pixel ellipse still commands at least one mirror.
%   Only reachable in anisotropic mode. A soma-sized spot is a few px across,
%   so a target sitting between sample points can otherwise rasterise to an
%   all-OFF pattern - a silently skipped stimulus. Off-chip targets are left
%   alone: nothing sensible can be turned on for them.
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
