function info = assertPatternInPatch(patterns, config, options)
%assertPatternInPatch Enforce the illuminated-patch containment rule on a pattern.
%
%   tfp.util.assertPatternInPatch(patterns)
%   tfp.util.assertPatternInPatch(patterns, config)
%   tfp.util.assertPatternInPatch(patterns, config, options)
%   info = tfp.util.assertPatternInPatch(...)
%
%   Returns silently if every ON mirror lies inside the illuminated patch;
%   throws otherwise. Mirrors the CHECK form of tfp.util.assertLaserPowerSafe:
%   a pure predicate with no hardware access and no side effects, so it can be
%   dropped into any pattern-load path.
%
%   WHY THIS EXISTS (docs/dmd_control_handoff.md §4). The bring-up path has no
%   piShaper, so the chip is lit by a raw Gaussian (Ø12.0 mm 1/e^2) and only
%   the middle of it is optically usable: "Write nothing outside the patch —
%   mirrors outside it must be OFF." Nothing else in the repo enforces that;
%   patchRadiusPx (nee roiHalfWidthPx) is otherwise used only to lay out
%   calibration grids.
%
%   TWO SEVERITY LEVELS, because the optics have two distinct thresholds:
%     1. r > patchRadiusPx    (278 px = Ø6.0 mm design patch)
%        The mirror is off the useful part of the Gaussian. It still reflects
%        light somewhere, so it wastes the target's dose budget and delivers an
%        unpredictable (and un-correctable) dose — the §8 dwell correction
%        1/I(r) is only characterised out to the patch edge, where I has
%        already fallen to 0.61 of centre.
%        -> tfp:util:assertPatternInPatch:outsidePatch
%     2. r > patchMaxRadiusPx (329 px = Ø7.12 mm hard maximum)
%        HARDER failure: beyond this the beam clips lens La and the grating
%        ruling. That is an optical-train violation, not a dose error.
%        -> tfp:util:assertPatternInPatch:outsideHardLimit
%   The hard-limit error wins when both are violated.
%
%   DO NOT "SIMPLIFY" THE PATCH TO A SQUARE. §4 is explicit that a square is a
%   bad idea and a bigger one than it looks: written in row/column coordinates
%   its *diagonal* is what the grating sees (the chip is clocked 45°, so the
%   optical axes are the chip diagonals), so an 8 mm square presents 11.31 mm
%   and overruns both the grating blank and lens La. It is also the worst place
%   to put mirrors photometrically — a square's corners sit at sqrt(2) further
%   out, where the Gaussian has fallen to 0.37 of centre (§8). The patch is a
%   disc; keep the test radial.
%
%   THE CENTRE IS NOT THE CHIP CENTRE. patchCenterPx is the ILLUMINATION
%   centroid — where the expanded beam actually lands — which is only
%   incidentally near the chip centre ([640 400] on a 1280x800 DLP650LNIR) and
%   is %VERIFY on the rig. The radius is therefore always measured from the
%   configured centre, never from the array centre.
%
%   Inputs:
%     patterns - logical H x W (single pattern) or H x W x N (stack), in DMD
%                pixel coordinates: element (row, col) is DMD pixel
%                (col, row), 1-indexed, origin top-left (per CLAUDE.md, and
%                matching tfp.patterns.singleSpot). Numeric input is accepted
%                and read as "nonzero means ON".
%     config   - optional. Anything tfp.util.opticalModel accepts: a full
%                loaded config, a bare dmd sub-struct, or a model struct
%                already returned by opticalModel. Omit or pass [] for the
%                documented defaults. The patch geometry (patchCenterPx,
%                patchRadiusPx, patchMaxRadiusPx, pitchUm) comes from there —
%                this function hardcodes no optical constants.
%     options  - optional struct (read via the local configField helper):
%                  .context ('') char tag naming the caller, prefixed to any
%                           error message, e.g. 'DLP650LNIR_DMD.loadPatternSequence'.
%
%   Output (optional):
%     info     - struct describing the worst ON mirror found:
%                  .nPatterns, .worstRadiusPx, .worstPatternIdx,
%                  .worstPixelColRow ([col row]), .nOverPatch, .nOverHardLimit,
%                  .patchCenterPx, .patchRadiusPx, .patchMaxRadiusPx.
%                All-OFF input gives worstRadiusPx = 0 and worstPatternIdx = 0.
%                Requesting info forces the exact scan (see PERFORMANCE).
%
%   Error identifiers:
%     tfp:util:assertPatternInPatch:outsideHardLimit - beyond patchMaxRadiusPx
%     tfp:util:assertPatternInPatch:outsidePatch     - beyond patchRadiusPx
%     tfp:util:assertPatternInPatch:badPattern       - malformed pattern input
%     tfp:util:assertPatternInPatch:badOptions       - malformed options
%
%   PERFORMANCE. This runs on every pattern load and stacks can be large
%   (1280x800xN), so no meshgrid is built. Two ideas do the work:
%     (a) Separable radii. The squared radius of pixel (row, col) is
%         dy2(row) + dx2(col), so only two 1-D lookup vectors (H and W long)
%         are needed, built once for the whole stack.
%     (b) A convexity fast path per slice. any(slice,2) and any(slice,1) are
%         cheap vectorised reductions; max(dy2(onRows)) + max(dx2(onCols)) is
%         the squared radius of the farthest corner of the ON bounding box,
%         which upper-bounds every ON pixel in that slice. A disc is convex, so
%         if that corner is inside the patch the whole slice is, and the slice
%         is cleared without ever enumerating its pixels. Only slices that fail
%         the bound (or that could beat the running worst case, when info is
%         requested) get the exact two-output find. The bound is never used to
%         *report* a radius, only to skip work, so results stay exact.
%
%   See also tfp.util.opticalModel, tfp.util.assertLaserPowerSafe,
%            tfp.util.assertPulseEnergySafe, tfp.util.validatePPSFTarget.

if nargin < 2
    config = [];
end
if nargin < 3 || isempty(options)
    options = struct();
end
if ~isstruct(options)
    error('tfp:util:assertPatternInPatch:badOptions', ...
        'options must be a struct; got %s.', class(options));
end
context = configField(options, 'context', '');
if isstring(context) || ischar(context)
    context = char(context);
else
    error('tfp:util:assertPatternInPatch:badOptions', ...
        'options.context must be char or string; got %s.', class(context));
end

% --- Validate the pattern ------------------------------------------------
if ~(islogical(patterns) || isnumeric(patterns))
    error('tfp:util:assertPatternInPatch:badPattern', ...
        'patterns must be a logical (or numeric) H x W [x N] array; got %s.', ...
        class(patterns));
end
if isempty(patterns) || ndims(patterns) > 3
    error('tfp:util:assertPatternInPatch:badPattern', ...
        ['patterns must be a non-empty H x W [x N] array of DMD mirror states; ' ...
         'got size [%s].'], strtrim(num2str(size(patterns))));
end
if ~islogical(patterns)
    patterns = patterns ~= 0;   % "nonzero means ON"
end

[nRows, nCols, nPatterns] = size(patterns);

% --- Patch geometry (single source of truth) -----------------------------
model      = tfp.util.opticalModel(config);
centerCol  = model.patchCenterPx(1);
centerRow  = model.patchCenterPx(2);
patchR     = model.patchRadiusPx;
patchMaxR  = model.patchMaxRadiusPx;
patchR2    = patchR^2;
patchMaxR2 = patchMaxR^2;

% Separable squared-radius lookups, built once for the whole stack. Both are
% COLUMN vectors so that indexing them with row/column subscripts of either
% orientation can never trigger implicit expansion into an N x N array.
dy2 = ((1:nRows)' - centerRow).^2;   % nRows x 1
dx2 = ((1:nCols)' - centerCol).^2;   % nCols x 1

% --- Scan ----------------------------------------------------------------
needExact      = nargout > 0;   % info must report a true radius, not a bound
worstR2        = 0;
worstIdx       = 0;
worstColRow    = [NaN NaN];
nOverPatch     = 0;
nOverHardLimit = 0;

for n = 1:nPatterns
    slice  = patterns(:, :, n);
    onRows = any(slice, 2);
    if ~any(onRows)
        continue                    % all-OFF slice: nothing to contain
    end
    onCols = any(slice, 1);

    % Farthest corner of the ON bounding box: an upper bound on this slice.
    boundR2 = max(dy2(onRows)) + max(dx2(onCols(:)));

    % Cannot violate the patch AND cannot beat the running worst case, so its
    % exact radius is of no interest to anybody. Skip the pixel enumeration.
    if boundR2 <= patchR2 && (~needExact || boundR2 <= worstR2)
        continue
    end

    % Exact: enumerate only this slice's ON mirrors.
    [onR, onC] = find(slice);
    r2 = dy2(onR) + dx2(onC);
    [sliceWorstR2, k] = max(r2);

    if sliceWorstR2 > patchR2
        nOverPatch = nOverPatch + 1;
        if sliceWorstR2 > patchMaxR2
            nOverHardLimit = nOverHardLimit + 1;
        end
    end
    if sliceWorstR2 > worstR2
        worstR2     = sliceWorstR2;
        worstIdx    = n;
        worstColRow = [onC(k) onR(k)];
    end
end

worstR = sqrt(worstR2);

% --- Report --------------------------------------------------------------
if nOverHardLimit > 0
    error('tfp:util:assertPatternInPatch:outsideHardLimit', ...
        ['%sPATTERN BEYOND THE HARD OPTICAL LIMIT: pattern %d of %d has an ON ' ...
         'mirror at (col=%g, row=%g), %.1f px from the patch centre ' ...
         '(col=%g, row=%g); the hard maximum is %.1f px (%.2f mm dia). ' ...
         '%d of %d patterns exceed it. Beyond this radius the beam clips lens ' ...
         'La and the grating ruling, so those mirrors do not just waste dose — ' ...
         'they send light into the mounts. Do not project this sequence. ' ...
         'Re-pick a more central target (or shrink the spot) so every ON mirror ' ...
         'falls inside the %.1f px design patch, and re-generate the pattern.'], ...
        prefix(context), worstIdx, nPatterns, worstColRow(1), worstColRow(2), ...
        worstR, centerCol, centerRow, patchMaxR, mmDia(patchMaxR, model.pitchUm), ...
        nOverHardLimit, nPatterns, patchR);
end

if nOverPatch > 0
    error('tfp:util:assertPatternInPatch:outsidePatch', ...
        ['%sPATTERN OUTSIDE THE ILLUMINATED PATCH: pattern %d of %d has an ON ' ...
         'mirror at (col=%g, row=%g), %.1f px from the patch centre ' ...
         '(col=%g, row=%g); the design patch radius is %.1f px (%.2f mm dia). ' ...
         '%d of %d patterns offend. There is no piShaper, so mirrors outside ' ...
         'the patch sit off the usable part of the illuminating Gaussian: they ' ...
         'waste the target''s dose budget and deliver an unpredictable dose that ' ...
         'the 1/I(r) dwell correction cannot fix. Re-pick a more central target ' ...
         '(or shrink the spot radius) and re-generate the pattern; if the cell ' ...
         'you want is genuinely at the edge, translate the scope to bring it in ' ...
         'rather than widening the patch.'], ...
        prefix(context), worstIdx, nPatterns, worstColRow(1), worstColRow(2), ...
        worstR, centerCol, centerRow, patchR, mmDia(patchR, model.pitchUm), ...
        nOverPatch, nPatterns);
end

if needExact
    info = struct( ...
        'nPatterns',        nPatterns, ...
        'worstRadiusPx',    worstR, ...
        'worstPatternIdx',  worstIdx, ...
        'worstPixelColRow', worstColRow, ...
        'nOverPatch',       nOverPatch, ...
        'nOverHardLimit',   nOverHardLimit, ...
        'patchCenterPx',    [centerCol centerRow], ...
        'patchRadiusPx',    patchR, ...
        'patchMaxRadiusPx', patchMaxR);
end
end

% =========================================================================

function s = prefix(context)
%prefix Format the caller tag for the head of an error message.
if isempty(context)
    s = '';
else
    s = sprintf('[%s] ', context);
end
end

function mm = mmDia(radiusPx, pitchUm)
%mmDia Patch diameter in mm, for an error message the operator can act on.
mm = 2 * radiusPx * pitchUm / 1000;
end

function value = configField(s, name, default)
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    value = s.(name);
else
    value = default;
end
end
