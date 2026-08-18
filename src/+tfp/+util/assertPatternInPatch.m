function info = assertPatternInPatch(patterns, options)
%assertPatternInPatch Enforce the illuminated-patch containment rule.
%
%   tfp.util.assertPatternInPatch(patterns)
%   tfp.util.assertPatternInPatch(patterns, options)
%   info = tfp.util.assertPatternInPatch(...)
%
%   Returns silently when every ON mirror lies inside the illuminated patch;
%   throws otherwise. A pure predicate — no hardware access, no side effects —
%   so it drops into any pattern-load path.
%
%   WHY (docs/optics_handoff.md §4). There is no piShaper, so the chip is lit
%   by a raw Gaussian and only the middle of it is optically usable: "Write
%   nothing outside the patch — mirrors outside it must be OFF." Mirrors
%   beyond the patch edge still reflect light, into field angles the lens
%   apertures were never sized for. At alignment power that is a fuzzy,
%   misleading beam edge; at experiment power it is watts of stray light.
%
%   THE THRESHOLD IS "UNVERIFIED", NOT "SLIGHTLY WORSE". §4 is explicit that
%   every buildability gate — lens apertures, grating ruling, SLM fill — was
%   checked AT the design patch diameter, and that "nothing larger is verified
%   — a bigger patch is a new sweep, not a bigger bitmap". So this is not a
%   soft dose-quality limit with a graceful rolloff; outside the patch the
%   optical train simply has no analysis behind it.
%
%   DO NOT SIMPLIFY THE PATCH TO A SQUARE. §4: written in row/column
%   coordinates a square's DIAGONAL is what the grating and the SLM fill see,
%   so it presents sqrt(2) of its side. The chip is clocked 45 deg, so the
%   optical axes are the chip diagonals — precisely where a square sticks out
%   furthest, and where the Gaussian is dimmest. The patch is a disc; keep the
%   test radial.
%
%   THE CENTRE IS AN ASSUMPTION. The patch is centred on the ILLUMINATION,
%   which is only the chip centre if the beam is centred on the chip — a bench
%   fact, not a given (a 2 mm error in the DMD mount height moves it). Pass
%   options.center once measured; scripts/alignmentField.m is how you measure
%   it, and scripts/alignmentTarget.m gives you a ruler in 40 px rings.
%
%   Inputs:
%     patterns - logical (nRows x nCols) or (nRows x nCols x nFrames).
%                Numeric is accepted and compared ~= 0.
%     options  - optional struct:
%       .patchDiameterPx - patch diameter, px. Default: the handoff constant
%                          patch_diameter_px, read at runtime so a
%                          regenerated handoff propagates without a code edit.
%       .center          - [col row] patch centre. Default: chip centre.
%       .mode            - 'error' (default) or 'warn'. 'warn' issues
%                          tfp:util:assertPatternInPatch:outsidePatch as a
%                          warning and returns, for load paths that must stay
%                          permissive (see tfp.hardware.DMD.assertPatternsSafe).
%       .label           - char, prefix for messages (e.g. the caller name).
%
%   Output:
%     info - struct with .patchRadiusPx, .center, .nFrames, and per-frame
%            row vectors .nOutside, .fracOutside, .maxRadiusPx. Returned even
%            in 'warn' mode, so callers can log the numbers.
%
%   Error/warning identifier:
%     tfp:util:assertPatternInPatch:outsidePatch
%
%   See also tfp.util.readHandoffConstants, tfp.hardware.DMD.assertPatternsSafe,
%   tfp.patterns.alignmentTarget.

if nargin < 2 || isempty(options), options = struct(); end

if ~isnumeric(patterns) && ~islogical(patterns)
    error('tfp:util:assertPatternInPatch:badPatterns', ...
        'patterns must be logical or numeric; got %s.', class(patterns));
end
if ndims(patterns) > 3
    error('tfp:util:assertPatternInPatch:badPatterns', ...
        'patterns must be 2-D or 3-D; got %d dimensions.', ndims(patterns));
end

[nRows, nCols, nFrames] = size(patterns);

patchDiamPx = tfp.util.configField(options, 'patchDiameterPx', []);
if isempty(patchDiamPx)
    c = tfp.util.readHandoffConstants();
    patchDiamPx = c.patch_diameter_px;
end
if ~isnumeric(patchDiamPx) || ~isscalar(patchDiamPx) || ~(patchDiamPx > 0)
    error('tfp:util:assertPatternInPatch:badPatchDiameter', ...
        'patchDiameterPx must be a positive scalar; got %s.', mat2str(patchDiamPx));
end

center = tfp.util.configField(options, 'center', [(nCols + 1)/2, (nRows + 1)/2]);
if ~isnumeric(center) || numel(center) ~= 2
    error('tfp:util:assertPatternInPatch:badCenter', ...
        'options.center must be [col row]; got %s.', mat2str(center));
end

mode  = lower(char(tfp.util.configField(options, 'mode', 'error')));
label = char(tfp.util.configField(options, 'label', ''));
if ~ismember(mode, {'error', 'warn'})
    error('tfp:util:assertPatternInPatch:badMode', ...
        'options.mode must be ''error'' or ''warn''; got ''%s''.', mode);
end
if ~isempty(label), label = [label ': ']; end

R = double(patchDiamPx) / 2;

% Radius of every mirror from the patch centre, computed once.
[C, Rr] = meshgrid(1:nCols, 1:nRows);
radius  = hypot(C - center(1), Rr - center(2));
outside = radius > R;

info = struct('patchRadiusPx', R, 'center', center(:).', 'nFrames', nFrames, ...
              'nOutside', zeros(1, nFrames), 'fracOutside', zeros(1, nFrames), ...
              'maxRadiusPx', zeros(1, nFrames));

worstFrame = 0;
worstCount = 0;
for k = 1:nFrames
    on = patterns(:, :, k) ~= 0;
    bad = on & outside;
    n   = nnz(bad);
    info.nOutside(k)    = n;
    info.fracOutside(k) = n / max(1, nnz(on));
    if any(on(:))
        info.maxRadiusPx(k) = max(radius(on));
    end
    if n > worstCount
        worstCount = n;
        worstFrame = k;
    end
end

if worstCount == 0
    return
end

msgId = 'tfp:util:assertPatternInPatch:outsidePatch';
msg = sprintf(['%spattern %d lights %d mirrors outside the O%.0f px patch ' ...
    '(%.1f%% of its ON mirrors; furthest is %.0f px from centre, patch ' ...
    'radius %.1f px).\ndocs/optics_handoff.md §4: "write nothing outside ' ...
    'the patch". Every aperture gate was checked AT this diameter and ' ...
    'nothing larger is verified, so those mirrors throw light into field ' ...
    'angles the train was never analysed for.'], ...
    label, worstFrame, worstCount, 2*R, ...
    100 * info.fracOutside(worstFrame), info.maxRadiusPx(worstFrame), R);

if strcmp(mode, 'warn')
    warning(msgId, '%s', msg);
else
    error(msgId, '%s', msg);
end
end
