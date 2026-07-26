function dmdOffsetPx = sampleToDmdOffset(sampleOffsetUm, mapSpec, varargin)
%sampleToDmdOffset Sample-plane um offsets -> DMD pixel offsets (anisotropic, 45-degree clocked chip).
%
%   dmdOffsetPx = sampleToDmdOffset(sampleOffsetUm)
%   dmdOffsetPx = sampleToDmdOffset(sampleOffsetUm, model)
%   dmdOffsetPx = sampleToDmdOffset(sampleOffsetUm, config)
%   dmdOffsetPx = sampleToDmdOffset(sampleOffsetUm, linearMatrix)
%   dmdOffsetPx = sampleToDmdOffset(..., 'mapUnits', 'um')
%
%   The inverse half of the bring-up coordinate map (docs/dmd_control_handoff.md
%   §5), and the function experiment code should use to turn a desired
%   sample-plane displacement (a PPSF step, a cell-to-cell offset) into DMD
%   pixels. It replaces the scalar `pixelsPerUm` used elsewhere in the repo,
%   which is isotropic, axis-unaware, and ~4x too small.
%
%     dc = (x_disp/umPerPixelDispersion * sign + y_groove/umPerPixelGroove)/sqrt(2)
%     dr = (x_disp/umPerPixelDispersion * sign - y_groove/umPerPixelGroove)/sqrt(2)
%
%   Because the sample scale is anisotropic (1.4162 um/px along the grating's
%   dispersion axis vs 1.1250 um/px along the grooves), a round spot at the
%   sample requires an ELLIPSE on the DMD, compressed by 1.2588x along the
%   (1, 1) chip diagonal. Passing the points of a round sample-plane spot
%   through this function produces exactly that pre-compensated ellipse.
%
%   Inputs:
%     sampleOffsetUm - 1x2 or N x 2 numeric. Each row is [x_disp y_groove] in
%                      um: column 1 along the grating's dispersion axis,
%                      column 2 along the grooves.
%     mapSpec        - optional. One of:
%                        [] or omitted - design constants from
%                                        tfp.util.opticalModel() (all defaults).
%                        struct        - a model struct from
%                                        tfp.util.opticalModel, or any config
%                                        struct; it is passed through
%                                        tfp.util.opticalModel for validation.
%                                        A struct carrying a numeric field
%                                        .dmdToSampleLinear is treated as the
%                                        fitted-affine case below.
%                        2x2 or 3x3    - the LINEAR part of a FITTED DMD->sample
%                          numeric        affine, i.e. the SAME direction as the
%                                        design map: [dCol dRow] -> [x y] um.
%                                        This function inverts it for you, so
%                                        that one stored matrix serves both
%                                        directions. For a 3x3 the translation
%                                        row/column is ignored (these are
%                                        offsets). Per §9 of the handoff a
%                                        fitted affine always wins over the
%                                        design constants — the same call site
%                                        therefore works pre- and
%                                        post-calibration.
%     options        - optional trailing options struct or name/value pairs
%                      (see "Units guard" below):
%                        'mapUnits'         'um' (asserts the supplied map is
%                                           um-valued; trusted, and the
%                                           sanctioned way to silence the
%                                           plausibility warning),
%                                           'camera_px' (errors), or
%                                           'unknown' (default behaviour).
%                                           A struct mapSpec may instead carry
%                                           the tag as a .mapUnits / .units
%                                           field beside .dmdToSampleLinear.
%                        'cameraUmPerPixel' um per substage-camera pixel, used
%                                           by the plausibility check below.
%                                           Defaults to config camera.umPerPixel
%                                           if the caller passed a config.
%
%   Units guard (T-BU-2e). The map handed in here must be um-valued. The
%   hazard is calibration.dmdToSample_affine, which despite its name maps DMD
%   px -> substage CAMERA px (tfp.calibration.alignDMDtoCamera); passing it
%   here silently mis-scales every target. Two layers defend against it:
%     1. An explicit 'mapUnits' tag, which is authoritative. 'camera_px'
%        throws tfp:patterns:sampleToDmdOffset:wrongUnits.
%     2. An untagged plausibility backstop: the map's overall scale is compared
%        against tfp.util.opticalModel and, if it is off by more than the
%        threshold, tfp:patterns:sampleToDmdOffset:suspiciousMapScale is
%        WARNED (never thrown — a fitted map is allowed to disagree with design
%        intent) listing every hypothesis that fits. It is deliberately not a
%        diagnosis: the camera-pixel factor (1.56) and the periscope-reversal
%        factor (1.778, handoff §9) are only 14% apart, so scale alone cannot
%        tell "wrong units" from "periscope installed the other way". Note the
%        blind spot that follows: a camera-valued map on a reversed periscope
%        is only 1.14x off and will NOT be flagged.
%
%   Output:
%     dmdOffsetPx - same shape as sampleOffsetUm (1x2 or N x 2). Each row is a
%                   pixel OFFSET from the patch centre, [dCol dRow], matching
%                   the [col row] ordering used by tfp.patterns.multiSpot and
%                   tfp.patterns.singleSpot. Values are NOT rounded; round only
%                   at the point you rasterize a mask.
%
%   The round trip is exact to floating-point round-off:
%     tfp.patterns.dmdToSampleOffset(tfp.patterns.sampleToDmdOffset(x)) == x.
%
%   %VERIFY sign convention. Which chip diagonal is +dispersion (and which way
%   x_disp runs at the sample) is NOT specified by the optics document — it
%   depends on how the grating and the folds are actually installed, and is
%   resolved on the bench with a two-point calibration. It is exposed as
%   model.dispersionAxisSign (config key dmd.dispersionAxisSign), default +1.
%   When mapSpec is a matrix its signs are already fitted and
%   dispersionAxisSign is not consulted.
%
%   NOTE: do not pass calibration.dmdToSample_affine here. In this repo that
%   field maps DMD pixels -> substage CAMERA pixels (see
%   tfp.calibration.alignDMDtoCamera), not -> sample um. Convert it to um
%   first (multiply by camera.umPerPixel), then pass the 2x2 linear part.
%   Whether that field should be renamed or composed into a um-valued fit is
%   deferred to the first calibration run (TASKS.md T-BU-M0); until then the
%   units guard above is what stands between it and every photostim target.
%
%   Errors:   tfp:patterns:sampleToDmdOffset:<reason>
%             ...:wrongUnits is the units guard; ...:badUnits / ...:badOption
%             are malformed option arguments.
%   Warnings: tfp:patterns:sampleToDmdOffset:suspiciousMapScale
%
%   See also tfp.patterns.dmdToSampleOffset, tfp.util.opticalModel,
%            tfp.patterns.calibratedAffine, tfp.patterns.ppsfPattern.

if nargin < 2
    mapSpec = [];
end

opts = parseMapOptions_('sampleToDmdOffset', varargin);
sampleOffsetUm = validateOffsets_(sampleOffsetUm, 'sampleToDmdOffset', 'sampleOffsetUm');
M = resolveLinearMap_(mapSpec, 'sampleToDmdOffset', opts);  % [dc dr] px -> [x y] um

% Solve M * [dc; dr] = [x; y] instead of multiplying by inv(M): mldivide is
% better conditioned, and it makes the round trip through dmdToSampleOffset
% agree to floating-point round-off.
dmdOffsetPx = (M \ sampleOffsetUm')';
end

% =========================================================================
% EVERYTHING BELOW THIS LINE IS DUPLICATED VERBATIM in sampleToDmdOffset.m and
% dmdToSampleOffset.m so each file stands alone (the repo's configField
% convention: promote to +tfp/+util/ only when a third caller appears). Keep
% the two blocks byte-identical — `diff` them after editing either one; the
% round-trip and units tests in tests/test_sampleDmdMapping.m exercise both
% copies and fail loudly if they drift.

function offsets = validateOffsets_(offsets, fname, argName)
%validateOffsets_ Shape/finiteness check shared by both directions of the map.
if ~isnumeric(offsets) || ~isreal(offsets) || ndims(offsets) > 2 ...
        || size(offsets, 2) ~= 2
    error(sprintf('tfp:patterns:%s:badOffsets', fname), ...
        '%s must be 1x2 or N x 2 real numeric; got size [%s] of class %s.', ...
        argName, num2str(size(offsets)), class(offsets));
end
if ~all(isfinite(offsets(:)))
    error(sprintf('tfp:patterns:%s:badOffsets', fname), ...
        '%s must be finite; a NaN/Inf offset would silently mis-place a target.', ...
        argName);
end
offsets = double(offsets);
end

function M = resolveLinearMap_(mapSpec, fname, opts)
%resolveLinearMap_ Return the 2x2 DMD-px -> sample-um linear map.
%   Accepts the design constants (model/config struct, or []) or the linear
%   part of a fitted affine. The fitted affine wins whenever it is supplied.
%   Every path ends in the units guard, checkMapUnits_.
cfg      = struct();    % the config-ish struct the caller supplied, if any
isFitted = false;       % true once a caller-supplied matrix is in play

if isnumeric(mapSpec) && ~isempty(mapSpec)
    M = linearPart_(mapSpec, fname);
    isFitted = true;
elseif isstruct(mapSpec) && isfield(mapSpec, 'dmdToSampleLinear') ...
        && ~isempty(mapSpec.dmdToSampleLinear)
    M = linearPart_(mapSpec.dmdToSampleLinear, fname);
    isFitted = true;
    cfg = mapSpec;
elseif isempty(mapSpec) || isstruct(mapSpec)
    % Design intent. tfp.util.opticalModel is the single source of truth for
    % the constants and validates them; a model struct fed back in is a no-op.
    if isstruct(mapSpec)
        cfg = mapSpec;
    end
    model = tfp.util.opticalModel(mapSpec);
    M = designMap_(model);
else
    error(sprintf('tfp:patterns:%s:badMap', fname), ...
        ['mapSpec must be [] (design constants), a model/config struct, or a ' ...
         '2x2/3x3 fitted-affine matrix; got %s.'], class(mapSpec));
end

if rcond(M) < 1e-12 || ~all(isfinite(M(:)))
    error(sprintf('tfp:patterns:%s:singularMap', fname), ...
        ['The DMD->sample linear map is singular or near-singular ' ...
         '(rcond = %g); it cannot be inverted. Check the fitted affine.'], ...
        rcond(M));
end

checkMapUnits_(M, isFitted, cfg, opts, fname);
end

function opts = parseMapOptions_(fname, args)
%parseMapOptions_ Trailing options: one options struct, or name/value pairs.
%   Returns a struct with
%     .mapUnits         '' (nothing supplied) | 'um' | 'camera' | 'unknown'
%     .cameraUmPerPixel [] (unset) or a positive scalar
opts = struct('mapUnits', '', 'cameraUmPerPixel', []);
if isempty(args)
    return
end
if numel(args) == 1 && isstruct(args{1})
    % Flatten an options struct into the same name/value list.
    s     = args{1};
    names = fieldnames(s);
    args  = cell(1, 2 * numel(names));
    for k = 1:numel(names)
        args{2*k - 1} = names{k};
        args{2*k}     = s.(names{k});
    end
end
if mod(numel(args), 2) ~= 0
    error(sprintf('tfp:patterns:%s:badOption', fname), ...
        ['Options must be a single options struct or name/value pairs; got ' ...
         '%d trailing argument(s).'], numel(args));
end
for k = 1:2:numel(args)
    name = args{k};
    if ~(ischar(name) || (isstring(name) && isscalar(name)))
        error(sprintf('tfp:patterns:%s:badOption', fname), ...
            'Option names must be char/string; got %s.', class(name));
    end
    value = args{k + 1};
    switch lower(char(name))
        case {'mapunits', 'units'}
            opts.mapUnits = canonicalUnits_(value, fname);
        case 'cameraumperpixel'
            if ~isnumeric(value) || ~isscalar(value) || ~isreal(value) ...
                    || ~isfinite(value) || value <= 0
                error(sprintf('tfp:patterns:%s:badOption', fname), ...
                    'cameraUmPerPixel must be a positive finite real scalar.');
            end
            opts.cameraUmPerPixel = double(value);
        otherwise
            error(sprintf('tfp:patterns:%s:badOption', fname), ...
                ['Unknown option "%s"; the supported options are mapUnits ' ...
                 'and cameraUmPerPixel.'], char(name));
    end
end
end

function u = canonicalUnits_(raw, fname)
%canonicalUnits_ Normalise a units tag to 'um' | 'camera' | 'unknown'.
if isempty(raw)
    u = 'unknown';
    return
end
if ~(ischar(raw) || (isstring(raw) && isscalar(raw)))
    error(sprintf('tfp:patterns:%s:badUnits', fname), ...
        'mapUnits must be char/string; got %s.', class(raw));
end
switch lower(strtrim(char(raw)))
    case {'um', 'sample_um', 'sampleum', 'sample', 'micron', 'microns', ...
          'micrometre', 'micrometres', 'micrometer', 'micrometers'}
        u = 'um';
    case {'camera_px', 'camerapx', 'camera', 'cam', 'cam_px', 'campx', ...
          'camera_pixels', 'camerapixels', 'camera_pixel'}
        u = 'camera';
    case {'unknown', 'unspecified'}
        u = 'unknown';
    otherwise
        error(sprintf('tfp:patterns:%s:badUnits', fname), ...
            ['mapUnits must be "um" (sample micrometres), "camera_px" ' ...
             '(substage-camera pixels) or "unknown"; got "%s".'], ...
            strtrim(char(raw)));
end
end

function checkMapUnits_(M, isFitted, cfg, opts, fname)
%checkMapUnits_ Units guard on a caller-supplied DMD->sample map (T-BU-2e).
%   The map must be um-valued. The hazard is calibration.dmdToSample_affine:
%   despite its name it maps DMD px -> substage CAMERA px
%   (tfp.calibration.alignDMDtoCamera), so feeding it in here mis-scales every
%   target with no other symptom. Two layers:
%     1. An explicit tag, which is authoritative: 'camera_px' errors, 'um' is
%        trusted (and silences layer 2).
%     2. For the untagged case — which is most callers — a plausibility
%        backstop on the map's overall scale. It only ever WARNS: a fitted
%        affine is entitled to disagree with design intent, and refusing to
%        run would be worse than saying so loudly.

units = opts.mapUnits;                  % '' when the caller passed no option
if isempty(units)
    % A struct mapSpec may carry the tag alongside the matrix instead.
    units = canonicalUnits_(configField(cfg, 'mapUnits', ...
        configField(cfg, 'units', '')), fname);
end

if strcmp(units, 'camera')
    if isFitted
        detail = ['The supplied map is tagged camera_px, i.e. it maps DMD px ' ...
                  '-> substage camera px, not -> sample micrometres.'];
    else
        detail = ['mapUnits was tagged camera_px but no fitted map was ' ...
                  'supplied, so the tag contradicts the call.'];
    end
    error(sprintf('tfp:patterns:%s:wrongUnits', fname), ...
        ['%s %s needs a um-valued DMD->sample map. Convert first: multiply ' ...
         'the camera-valued linear part by camera.umPerPixel (um per camera ' ...
         'pixel; configs/real.yaml) and pass the result. In particular do NOT ' ...
         'pass calibration.dmdToSample_affine straight in — despite its name ' ...
         'that field is the camera-valued fit (tfp.calibration.alignDMDtoCamera, ' ...
         'TASKS.md T-BU-M0).'], detail, fname);
end
if strcmp(units, 'um') || ~isFitted
    % Tagged um: the caller has asserted the units, so take their word for it.
    % Not fitted: the design map is um-valued by construction.
    return
end

% --- Plausibility backstop (no tag) --------------------------------------
model = expectedModel_(cfg);

% Singular values are the map's two principal scales in um per DMD px. They
% are invariant to the chip's 45-degree clocking and to whatever rotation the
% fit absorbed, which is exactly what makes them comparable with the two
% design axis scales.
sObs = sort(svd(M), 'descend')';
sExp = sort([model.umPerPixelDispersion, model.umPerPixelGroove], 'descend');

% Compare the AREA scale (geometric mean of the two singular values, i.e.
% sqrt(|det|)). Every hypothesis below is an isotropic rescaling, so the
% geometric mean isolates them from the aspect ratio — which a real fit is
% allowed to move a little without meaning anything about units.
r = sqrt((sObs(1) * sObs(2)) / (sExp(1) * sExp(2)));

c = cameraUmPerPixel_(cfg, opts, model);
f = configField(model, 'periscopeReversalFactor', (200/150)^2);

% Threshold: the geometric midpoint between "um-valued" (ratio 1) and
% "camera-valued" (ratio 1/c). Below it the design hypothesis is the closer
% explanation of what we see; at or beyond it the camera hypothesis is at
% least as close. It has to be smaller than c or the guard could never fire on
% the very error it exists to catch, and at ~25% it is 5-10x looser than the
% "a few percent" of fit-vs-design disagreement that handoff sec 9 calls
% normal, so an honest fit stays quiet.
tol = sqrt(c);
if max(r, 1 / r) <= tol
    return
end

% Candidate explanations. NONE of these is asserted — the observation is a
% single scalar, and the camera hypothesis (1/c ~ 0.641) and the reversed-
% periscope hypothesis (1/f ~ 0.563) predict almost the same thing, so the
% message reports which ones fit and leaves the call to the operator.
hypotheses = { ...
    1,   'a um-valued fit, optics installed as the handoff documents'; ...
    1/c, sprintf(['a CAMERA-valued map: DMD px -> substage camera px, i.e. ' ...
                  'the um map divided by the %.4g um camera pixel ' ...
                  '(calibration.dmdToSample_affine is exactly this)'], c); ...
    f,   sprintf(['a um-valued fit with the 200/150 periscope installed the ' ...
                  'other way round (x%.4g; handoff sec 9, TASKS.md T-BU-M1)'], f); ...
    1/f, sprintf(['a um-valued fit where the handoff constants themselves ' ...
                  'already assume the reversed periscope (x1/%.4g)'], f)};

report = '';
nFits  = 0;
for k = 1:size(hypotheses, 1)
    predicted = hypotheses{k, 1};
    if max(r / predicted, predicted / r) <= tol
        mark  = '  <== FITS';
        nFits = nFits + 1;
    else
        mark = '';
    end
    report = sprintf('%s     predicts %.4g : %s%s\n', ...
        report, predicted, hypotheses{k, 2}, mark);
end

if nFits >= 2
    verdict = sprintf(['MORE THAN ONE explanation fits. Overall scale alone ' ...
        'CANNOT tell them apart — the camera pixel (%.4g) and the periscope ' ...
        'reversal (%.4g) differ by only %.0f%% — so this warning does not ' ...
        'claim the map is camera-valued. Settle it with a known-distance ' ...
        'measurement, or tag the units explicitly.'], c, f, ...
        100 * abs(max(c, f) / min(c, f) - 1));
elseif nFits == 1
    verdict = ['Only one listed explanation fits at this tolerance, but this ' ...
        'guard sees overall scale only (not rotation, aspect or offset) and ' ...
        'cannot rule out an ordinary bad fit. Treat it as a lead, not a ' ...
        'diagnosis.'];
else
    verdict = ['NONE of the listed explanations fits. The map may be in units ' ...
        'this guard does not know about, or the fit is simply bad. Check it ' ...
        'before projecting anything.'];
end

warnId = sprintf('tfp:patterns:%s:suspiciousMapScale', fname);
msg = sprintf([ ...
    '%s: the supplied DMD->sample map is %.4gx the overall scale ' ...
    'tfp.util.opticalModel expects, outside the [%.3g, %.3g] band this guard ' ...
    'treats as a fit of the documented optics.\n' ...
    '     observed principal scales: %.4g and %.4g um per DMD px (aspect %.3g)\n' ...
    '     design   principal scales: %.4g and %.4g um per DMD px (aspect %.3g)\n' ...
    '   Candidate explanations:\n%s' ...
    '   %s\n' ...
    '   To silence: pass ''mapUnits'', ''um'' once you know the map really is ' ...
    'um-valued (or warning(''off'', ''%s'')). If it is camera-valued, multiply ' ...
    'it by camera.umPerPixel = %.4g first.'], ...
    fname, r, 1 / tol, tol, ...
    sObs(1), sObs(2), sObs(1) / sObs(2), ...
    sExp(1), sExp(2), sExp(1) / sExp(2), ...
    report, verdict, warnId, c);

% '%s' rather than msg-as-format: the report text contains user-supplied
% numbers and must never be re-interpreted as a format string.
warning(warnId, '%s', msg);
end

function model = expectedModel_(cfg)
%expectedModel_ Design constants to compare a fitted map against.
%   Uses the caller's own config when they supplied one (a rig that knows its
%   scales differ from the document should not be nagged about it), and never
%   lets a malformed config turn this warning path into an error.
try
    model = tfp.util.opticalModel(cfg);
catch
    model = tfp.util.opticalModel();
end
end

function c = cameraUmPerPixel_(cfg, opts, model)
%cameraUmPerPixel_ um per substage-camera pixel, for the camera hypothesis.
%   Order of preference: explicit option > the caller's config
%   (camera.umPerPixel) > tfp.util.opticalModel, if the field ever moves there
%   (T-BU-M0 may put it there) > the documented default.
if ~isempty(opts.cameraUmPerPixel)
    c = opts.cameraUmPerPixel;
    return
end
%ASSUMED 1.56 um per camera pixel — configs/real.yaml camera.umPerPixel, the
% same default tfp.calibration.alignDMDtoCamera uses. It is not in
% tfp.util.opticalModel today; the configField chain below picks it up
% automatically on the day it lands there.
c = configField(configField(cfg, 'camera', struct()), 'umPerPixel', ...
        configField(model, 'cameraUmPerPixel', 1.56));
if ~isnumeric(c) || ~isscalar(c) || ~isreal(c) || ~isfinite(c) || c <= 0
    c = 1.56;
end
c = double(c);
end

function value = configField(s, name, default)
%configField Repo-standard config read with a fallback.
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    value = s.(name);
else
    value = default;
end
end

function M = designMap_(model)
%designMap_ Build the 2x2 map from the design constants (handoff §5).
%   Columns are the sample-plane images of a one-pixel step in DMD column and
%   in DMD row; the 1/sqrt(2) is the chip's 45-degree clocking.
s   = model.dispersionAxisSign;          % %VERIFY on the bench
ppd = model.umPerPixelDispersion;
ppg = model.umPerPixelGroove;
k   = 1 / sqrt(2);
M = [ s * ppd * k,  s * ppd * k; ...
          ppg * k,     -ppg * k];
end

function M = linearPart_(A, fname)
%linearPart_ Extract and check the 2x2 linear block of a fitted affine.
if ~isnumeric(A) || ~isreal(A) || ~all(isfinite(A(:)))
    error(sprintf('tfp:patterns:%s:badMap', fname), ...
        'The fitted map must be a real finite numeric matrix; got %s.', class(A));
end
switch size(A, 1) * 10 + size(A, 2)
    case 22
        M = double(A);
    case 33
        % Translation is meaningless for an offset-to-offset map; drop it.
        M = double(A(1:2, 1:2));
    otherwise
        error(sprintf('tfp:patterns:%s:badMap', fname), ...
            'The fitted map must be 2x2 or 3x3; got size [%s].', num2str(size(A)));
end
end
