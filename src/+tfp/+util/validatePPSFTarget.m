function target = validatePPSFTarget(targets, dmd, callerId, options)
%validatePPSFTarget Enforce a single PPSF target whose whole sweep stays in the patch.
%
%   target = tfp.util.validatePPSFTarget(targets, dmd, callerId)
%   target = tfp.util.validatePPSFTarget(targets, dmd, callerId, options)
%
%   PPSF experiments sweep the stim spot away from the target cell and need
%   the response to fall off cleanly. Two things must hold:
%     1. exactly one target per session (multiple targets would interfere);
%     2. the target PLUS the largest requested sweep offset PLUS the spot's own
%        radius still lands inside the illuminated patch. Mirrors outside the
%        patch are dark (handoff §4), so a sweep that leaves the patch does not
%        measure a PPSF — it measures the edge of the illumination.
%
%   Until T-BU-2b condition 2 was a hardcoded "within 80 px of the DMD
%   GEOMETRIC centre", which is wrong in both halves:
%     * the relevant centre is the ILLUMINATION centroid
%       (model.patchCenterPx), which need not be the chip centre — measuring
%       it is a bench task (TASKS.md T-BU-M3);
%     * 80 px was a guess unrelated to either the patch radius (278 px) or the
%       actual sweep, which at the real ~1.1-1.4 um/px scale is only ~30 px for
%       a +/-40 um lateral PPSF. The old rule simultaneously rejected perfectly
%       good targets and said nothing about whether the sweep fitted.
%
%   Inputs:
%     targets  - Nx2 [col row] in DMD pixel coordinates (output of the
%                experiment's resolveTargets).
%     dmd      - DMD object/struct with .nCols and .nRows.
%     callerId - char, e.g. 'exp_ppsf_lateral'; used to namespace the error
%                identifier as tfp:experiments:<callerId>:<reason>.
%     options  - optional scalar struct. Fields (all optional):
%       .offsetsUm    - Nx2 SAMPLE-PLANE sweep offsets in um, ordered
%                       [x_disp y_groove] as in tfp.patterns.sampleToDmdOffset,
%                       or an Nx1 / 1xN vector, which is treated as a 1-D sweep
%                       along the first (dispersion) axis. Converted to DMD
%                       pixels with the same map the experiment uses, so the
%                       check and the patterns cannot disagree.
%       .offsetsPx    - Nx2 [dCol dRow] sweep offsets already in DMD pixels.
%                       Use when the caller has done the conversion itself.
%                       Wins over .offsetsUm.
%       .spotRadiusPx - the spot's largest semi-axis in DMD px (default 0). Add
%                       it so the spot EDGE, not just its centre, is required
%                       to stay inside the patch.
%       .model        - struct from tfp.util.opticalModel. If absent it is
%                       built from .config.
%       .config       - config struct passed to tfp.util.opticalModel; default
%                       all defaults. Ignored when .model is given.
%
%   With no options the check degenerates to "the target itself is inside the
%   patch", which is the most that can be said without knowing the sweep.
%
%   Output:
%     target   - 1x2 [col row], the validated single target.
%
%   Throws (on failure):
%     tfp:experiments:<callerId>:badTargets     - targets is not Nx2, N >= 1.
%     tfp:experiments:<callerId>:tooManyTargets - size(targets,1) ~= 1.
%     tfp:experiments:<callerId>:targetOffChip  - the target is off the chip.
%     tfp:experiments:<callerId>:targetOffCenter - the target, swept by the
%       largest requested offset, leaves the illuminated patch. (Identifier
%       kept from the pre-T-BU-2b version so existing callers/handlers still
%       match; the meaning is now patch containment, not a fixed radius.)
%
%   See also tfp.util.opticalModel, tfp.util.assertPatternInPatch,
%            tfp.patterns.sampleToDmdOffset, tfp.patterns.somaSpotGeometry.

if nargin < 4 || isempty(options)
    options = struct();
end
if ~isstruct(options) || ~isscalar(options)
    error(sprintf('tfp:experiments:%s:badOptions', callerId), ...
        'options must be a scalar struct (or empty); got %s.', class(options));
end

if ~isnumeric(targets) || ndims(targets) ~= 2 || size(targets, 2) ~= 2 ...
        || size(targets, 1) < 1
    error(sprintf('tfp:experiments:%s:badTargets', callerId), ...
        'PPSF target list must be Nx2 [col row] with N >= 1.');
end

nTargets = size(targets, 1);
if nTargets ~= 1
    error(sprintf('tfp:experiments:%s:tooManyTargets', callerId), ...
        ['PPSF requires exactly 1 target cell per session, got %d. ' ...
         'PPSF measures the response falloff for a single cell while ' ...
         'the stim spot is swept away from it; multiple targets would ' ...
         'interfere. Pick a single ROI in ScanImage and re-send.'], ...
        nTargets);
end

target = double(targets(1, :));

% tfp.util.opticalModel is the single source of truth for the patch geometry;
% never hardcode 278 or [640 400] here.
model = configField(options, 'model', []);
if isempty(model)
    model = tfp.util.opticalModel(configField(options, 'config', struct()));
end
if ~isstruct(model) || ~isscalar(model) ...
        || ~all(isfield(model, {'patchCenterPx', 'patchRadiusPx'}))
    error(sprintf('tfp:experiments:%s:badOptions', callerId), ...
        ['options.model must be a scalar struct from tfp.util.opticalModel ' ...
         '(needs .patchCenterPx and .patchRadiusPx); got %s.'], class(model));
end

% Off-chip targets are a separate, more basic failure — report them as such
% rather than as a patch-containment message.
nCols = [];
nRows = [];
try
    nCols = double(dmd.nCols);
    nRows = double(dmd.nRows);
catch
    % dmd geometry is optional here; the patch check below is the real guard.
end
if ~isempty(nCols) && ~isempty(nRows)
    if target(1) < 1 || target(1) > nCols || target(2) < 1 || target(2) > nRows
        error(sprintf('tfp:experiments:%s:targetOffChip', callerId), ...
            ['PPSF target at (col=%g, row=%g) is not on the %dx%d DMD chip. ' ...
             'Check the scan-field -> DMD calibration used to place it.'], ...
            target(1), target(2), nCols, nRows);
    end
end

offsetsPx    = resolveSweepOffsetsPx(options, model, callerId);
spotRadiusPx = configField(options, 'spotRadiusPx', 0);
if ~isnumeric(spotRadiusPx) || ~isscalar(spotRadiusPx) ...
        || ~isfinite(spotRadiusPx) || spotRadiusPx < 0
    error(sprintf('tfp:experiments:%s:badOptions', callerId), ...
        'options.spotRadiusPx must be a non-negative finite scalar.');
end
spotRadiusPx = double(spotRadiusPx);

% Worst case over the whole sweep: distance from the ILLUMINATION centroid to
% the furthest swept spot centre, plus that spot's own radius.
centre  = model.patchCenterPx(:)';
swept   = target + offsetsPx;
radii   = hypot(swept(:, 1) - centre(1), swept(:, 2) - centre(2));
[worstCentreRadius, worstIdx] = max(radii);
worstRadius = worstCentreRadius + spotRadiusPx;

if worstRadius > model.patchRadiusPx
    error(sprintf('tfp:experiments:%s:targetOffCenter', callerId), ...
        ['PPSF target at (col=%g, row=%g) does not leave room for the ' ...
         'requested sweep. The worst-case spot (offset [%g %g] px, spot ' ...
         'radius %g px) reaches %.1f px from the illumination centroid ' ...
         '(col=%g, row=%g); the illuminated patch radius is %g px, so the ' ...
         'spot would fall on dark mirrors and the measured falloff would be ' ...
         'the edge of the illumination rather than a PPSF. Either pick a ' ...
         'more central cell as the PPSF target in ScanImage, translate the ' ...
         'scope so the target cell is nearer the patch centre and re-take ' ...
         'the ROI, or shorten the sweep.'], ...
        target(1), target(2), ...
        offsetsPx(worstIdx, 1), offsetsPx(worstIdx, 2), spotRadiusPx, ...
        worstRadius, centre(1), centre(2), model.patchRadiusPx);
end
end

% =========================================================================

function offsetsPx = resolveSweepOffsetsPx(options, model, callerId)
%resolveSweepOffsetsPx Sweep offsets as Nx2 DMD [dCol dRow], or [0 0].
%   Pre-converted pixel offsets win; um offsets go through the same map the
%   pattern builders use, so the guard and the patterns cannot disagree.

offsetsPx = configField(options, 'offsetsPx', []);
if ~isempty(offsetsPx)
    offsetsPx = checkOffsets(offsetsPx, 'offsetsPx', callerId);
    return;
end

offsetsUm = configField(options, 'offsetsUm', []);
if isempty(offsetsUm)
    offsetsPx = [0 0];
    return;
end

% A 1-D sweep (the lateral-PPSF distance list) is a vector; treat it as motion
% along the first sample axis, matching how the experiments build their trials.
if isnumeric(offsetsUm) && isvector(offsetsUm) && numel(offsetsUm) ~= 2
    offsetsUm = [double(offsetsUm(:)), zeros(numel(offsetsUm), 1)];
end
offsetsUm = checkOffsets(offsetsUm, 'offsetsUm', callerId);

offsetsPx = tfp.patterns.sampleToDmdOffset(offsetsUm, model);
end

function v = checkOffsets(v, name, callerId)
if ~isnumeric(v) || ~isreal(v) || ndims(v) > 2 || size(v, 2) ~= 2 ...
        || ~all(isfinite(v(:)))
    error(sprintf('tfp:experiments:%s:badOptions', callerId), ...
        'options.%s must be a finite Nx2 real numeric array.', name);
end
v = double(v);
end

function value = configField(s, name, default)
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    value = s.(name);
else
    value = default;
end
end
