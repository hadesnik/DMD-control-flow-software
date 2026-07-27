function dwell = dwellCorrection(targetsPx, options)
%dwellCorrection Per-target dwell, in 80 us binary frames, that flat-fields the Gaussian illumination.
%
%   dwell = tfp.patterns.dwellCorrection(targetsPx)
%   dwell = tfp.patterns.dwellCorrection(targetsPx, options)
%   dwell = tfp.patterns.dwellCorrection([], options)   % relative values supplied
%
%   There is no piShaper in the bring-up build, so the usable patch sits
%   inside a raw Gaussian (docs/dmd_control_handoff.md §8). As a function of
%   radius in DMD pixels from the ILLUMINATION centre (model.patchCenterPx —
%   not necessarily the chip centre, see T-BU-M3):
%
%       I(r) / I0 = exp(-2 * r^2 / w^2),   w = model.gaussianWaistPx
%
%   which falls to 0.61 at the r = 278 px patch edge. A target out there is
%   lit 39% less than one at the centre, so an uncorrected ensemble delivers
%   systematically less drive to its peripheral cells — exactly the gradient
%   that would masquerade as a biological effect in a lateral-PPSF figure.
%
%   The DMD is binary at 12,500 Hz, so the ONE per-target dose knob that
%   costs nothing but time is HOW MANY 80 us frames the target is ON. This
%   function turns a per-target relative brightness (measured or analytic)
%   into that frame count.
%
%   ---------------------------------------------------------------------
%   *** THE SQUARE. READ THIS BEFORE CHANGING THE EXPONENT. ***
%   ---------------------------------------------------------------------
%   Two-photon excitation goes as INTENSITY SQUARED, so "equalise the
%   delivered intensity" and "equalise the delivered 2p excitation" are
%   different corrections — different in the EXPONENT, not just in
%   magnitude. Getting it backwards is silent and looks plausible.
%
%   Let g(r) = I(r)/I0 be the relative INTENSITY at the target. Then
%
%     mode 'twoPhoton' (DEFAULT)  dwell = base / g^2   equalises the
%           delivered 2p excitation dose, integral(I^2 dt). This is what
%           actually drives the opsin, so it is what makes two cells at
%           different field positions comparable. At the patch edge
%           g = 0.606, so the correction is 1/0.606^2 = 2.72x.
%
%     mode 'linear'               dwell = base / g     equalises the
%           delivered optical ENERGY, integral(I dt). At the patch edge the
%           correction is 1/0.606 = 1.65x.
%
%   §8 of the handoff quotes the LINEAR figure ("scale each target's dwell
%   by 1/I(r) ... worst case 1.65x"). That is the right budgeting number for
%   energy and heat, and 'linear' reproduces it exactly — but it
%   UNDER-corrects a two-photon process by a factor of g, i.e. by 1.65x at
%   the patch edge. Because this is a 2p photostimulation rig and the
%   quantity we want equal across cells is evoked drive, the default here is
%   'twoPhoton'. `dwell.equalises` always states in words which one you got.
%
%   WHICH MAP TO SCALE BY. tfp.calibration.measureIlluminationUniformity
%   returns two maps and they are one square apart:
%     .intensityNorm     the raw integrated 2p signal per spot, normalised —
%                        a RESPONSE map, proportional to I^2.
%     .intensitySqrtNorm its square root, the relative INTENSITY (prop to I).
%   This function consumes `.intensityNorm` (falling back to
%   `.intensitySqrtNorm.^2` if only that is present) and treats it as g^2,
%   which matches that routine's own docstring: "the flat-field correction
%   that equalises response uses this raw map". In the default 'twoPhoton'
%   mode the dwell is therefore simply base / intensityNorm — one over the
%   measured response map, no square root anywhere. Substituting
%   `.intensitySqrtNorm` there would give base / g, i.e. silently drop to
%   the linear correction; use options.mode for that instead so the choice
%   is recorded in the output.
%
%   ---------------------------------------------------------------------
%   *** SAFETY: CORRECT IN TIME, NOT IN FILL FRACTION. ***
%   ---------------------------------------------------------------------
%   We already own a per-neuron power knob that is NOT the right one here:
%   tfp.patterns.fillFactorEnsemble sets dose by how many mirrors inside a
%   neuron's patch are ON. Do not "simplify" this function into a
%   fill-fraction correction. Every 4f relay of a collimated DMD forms a
%   real focus in air at its pupil (handoff §7), and the pupil peak scales
%   with the SQUARE of the pattern's mean, so:
%
%     * raising an edge target's FILL to compensate for dimming raises the
%       pupil peak QUADRATICALLY, pushing toward the ~68 uJ air-ionisation
%       limit that tfp.util.assertPulseEnergySafe exists to hold (T-BU-1d);
%     * raising its DWELL leaves the instantaneous pupil peak completely
%       untouched — the same frame is simply shown more times.
%
%   So the handoff's "correct it in time, not in optics" is also the safer
%   choice, not merely the convenient one. The cost is time, and this
%   function reports that cost (`.totalDurationS`, `.timeCostFactor`) so a
%   caller can see what flat-fielding a wide ensemble buys and what it
%   costs. It never touches fill fraction, pattern geometry, or ao3
%   voltage, and it deliberately returns no fill-related field.
%
%   ---------------------------------------------------------------------
%   QUANTISATION — a real limit at short dwells.
%   ---------------------------------------------------------------------
%   Dwell exists only in whole 80 us frames, so a correction is representable
%   only to within one frame of the base dwell. With a base dwell of 1 frame
%   a 1.65x correction cannot be expressed AT ALL: the choices are 1 frame
%   (1.00x) and 2 frames (2.00x). Every returned dwell therefore comes with
%   `.quantizationErrorFrac` (signed relative dose error per target),
%   `.quantizationOk`, and `.minBaseDwellFrames` — the shortest base dwell
%   that would bring the worst-case error inside tolerance. Exceeding the
%   tolerance raises tfp:patterns:dwellCorrection:dwellQuantization rather
%   than silently mis-dosing.
%
%   Inputs:
%     targetsPx - N x 2 numeric [col row] DMD pixel coordinates (1-indexed,
%                 origin top-left, per CLAUDE.md). Radii are measured from
%                 model.patchCenterPx with a plain Euclidean distance: the
%                 Gaussian is the illumination footprint ON THE CHIP, so the
%                 sample-plane anisotropy of §5 does not enter here. Pass []
%                 when supplying relative values or radii through options.
%     options - struct, all fields optional:
%       .config          - config struct forwarded to tfp.util.opticalModel
%                          (full loaded config or a bare dmd sub-struct).
%                          Supplies the waist, patch centre/radius and the
%                          binary frame rate. Never hardcode 555.6 / 12500 /
%                          278 here or anywhere else (T-BU-0).
%       .mode            - 'twoPhoton' (default) | 'linear'. See above.
%       .baseDwellFrames - positive integer, the dwell a target at the
%                          illumination centre (g = 1) receives. Default
%                          %ASSUMED 125 frames = 10 ms at 12.5 kHz.
%       .baseDwellS      - alternative to .baseDwellFrames, in seconds;
%                          rounded to the nearest whole frame. Supplying
%                          both is an error.
%       .uniformityCalib - the struct returned by
%                          tfp.calibration.measureIlluminationUniformity.
%                          When present the per-target relative brightness is
%                          interpolated from the MEASURED map instead of the
%                          analytic Gaussian. Requires .dmdGridPts and
%                          .intensityNorm (or .intensitySqrtNorm).
%       .interpolation   - 'linear' (default) | 'nearest', for that map.
%       .radiusPx        - N x 1 radii from the patch centre, as an
%                          alternative to targetsPx. Forces the analytic
%                          Gaussian (a radius cannot index a 2D map).
%       .relativeIntensity - N x 1 relative intensity g in (0, 1], supplied
%                          directly. Skips both the map and the Gaussian.
%       .relativeResponse  - N x 1 relative 2p response g^2 in (0, 1],
%                          supplied directly (e.g. a hand-picked subset of
%                          calib.intensityNorm).
%       .maxCorrection   - cap on the correction factor (default 10). Beyond
%                          it the target is essentially unlit and the "fix"
%                          is to move the target, not to stare at it for a
%                          second. Clipping warns.
%       .maxDwellFrames  - hard cap on frames per target (default Inf).
%       .quantizationTolerance - worst acceptable relative dose error from
%                          frame rounding (default 0.02 = 2%).
%       .maxBaseDwellSearch - cap for the .minBaseDwellFrames search
%                          (default 2000 frames = 160 ms).
%       .warnOnQuantization - logical, default true.
%
%   Output struct `dwell`:
%     Per target (all N x 1)
%       .dwellFrames        whole 80 us frames to hold this target ON. THIS
%                           is what a sequencer programs.
%       .dwellS             .dwellFrames * model.frameDurationS.
%       .exactDwellFrames   unquantised base * correction.
%       .correction         exact correction factor, g^-exponent.
%       .achievedCorrection .dwellFrames / .baseDwellFrames (after rounding).
%       .relativeIntensity  g.
%       .relativeResponse   g^2.
%       .radiusPx           radius from the patch centre (NaN when relative
%                           values were supplied directly).
%       .outsidePatch       logical, radius > model.patchRadiusPx.
%       .quantizationErrorFrac  signed (achieved - exact)/exact. Because
%                           dose is linear in dwell in BOTH modes, this is
%                           also the relative dose error.
%     Summary
%       .worstCaseCorrection / .worstCaseTargetIdx
%       .maxQuantizationErrorFrac / .quantizationOk / .minBaseDwellFrames
%       .totalFrames / .totalDurationS          corrected sequence
%       .uncorrectedTotalFrames / .uncorrectedDurationS
%       .timeCostFactor     corrected / uncorrected duration — the price of
%                           flat-fielding this ensemble.
%       .nTargets, .baseDwellFrames, .baseDwellS
%     Provenance
%       .mode, .exponent, .equalises, .source
%       ('measured' | 'analytic' | 'suppliedIntensity' | 'suppliedResponse')
%       .clipped, .frameDurationS, .binaryFrameRateHz, .model, .description
%
%   Warnings:
%     tfp:patterns:dwellCorrection:dwellQuantization - the base dwell is too
%       short to express the requested corrections within tolerance.
%     tfp:patterns:dwellCorrection:correctionClipped - a correction exceeded
%       .maxCorrection (or a dwell exceeded .maxDwellFrames) and was clipped;
%       those targets ARE under-dosed and the message says so.
%     tfp:patterns:dwellCorrection:outsidePatch    - a target lies outside
%       model.patchRadiusPx. Containment is enforced elsewhere
%       (tfp.util.assertPatternInPatch); this is the dose-side symptom.
%     tfp:patterns:dwellCorrection:extrapolatedFromMap - a target lies
%       outside the measured grid's extent, so its value is extrapolated.
%     tfp:patterns:dwellCorrection:aboveUnity      - a relative brightness
%       exceeded 1, i.e. the map is not normalised to its peak.
%     tfp:patterns:dwellCorrection:calibIgnored    - a uniformity map was
%       supplied alongside a radius-only input and could not be used.
%
%   Errors: tfp:patterns:dwellCorrection:<reason>
%
%   See also tfp.calibration.measureIlluminationUniformity,
%            tfp.util.opticalModel, tfp.patterns.fillFactorEnsemble,
%            tfp.util.assertPulseEnergySafe, tfp.util.targetDepthOffset.

% Default dwell at the illumination centre. 125 frames = 10 ms at 12.5 kHz,
% a plausible single-target photostim pulse. %ASSUMED — callers with a real
% protocol should pass .baseDwellFrames or .baseDwellS explicitly.
DEFAULT_BASE_DWELL_FRAMES = 125;

if nargin < 1
    targetsPx = [];
end
if nargin < 2 || isempty(options)
    options = struct();
end
if ~isstruct(options) || ~isscalar(options)
    error('tfp:patterns:dwellCorrection:badOptions', ...
        'options must be a scalar struct; got %s.', class(options));
end

% Single source of truth for the waist, the patch geometry and the frame
% rate. Nothing below may hardcode 555.6, 12500, 278 or 1.65 (T-BU-0).
model = tfp.util.opticalModel(configField(options, 'config', struct()));

% --- Mode: which quantity are we equalising? -----------------------------
% The exponent IS the decision documented at the top of this file. `linear`
% equalises delivered energy (the handoff's 1.65x budget number); the
% default `twoPhoton` equalises delivered 2p excitation, which is what
% drives the opsin and therefore what makes two cells comparable.
modeIn = configField(options, 'mode', 'twoPhoton');
if ~(ischar(modeIn) || isstring(modeIn))
    error('tfp:patterns:dwellCorrection:badMode', ...
        'options.mode must be ''twoPhoton'' or ''linear''; got %s.', class(modeIn));
end
switch lower(char(modeIn))
    case {'twophoton', '2p', 'response'}
        mode      = 'twoPhoton';
        exponent  = 2;
        equalises = 'delivered 2p excitation dose (proportional to integral of I^2 dt)';
    case {'linear', 'energy', 'intensity'}
        mode      = 'linear';
        exponent  = 1;
        equalises = 'delivered optical energy (proportional to integral of I dt)';
    otherwise
        error('tfp:patterns:dwellCorrection:badMode', ...
            ['options.mode must be ''twoPhoton'' (equalise 2p excitation, ' ...
             'dwell ~ 1/I^2) or ''linear'' (equalise energy, dwell ~ 1/I, ' ...
             'the handoff §8 convention); got ''%s''.'], char(modeIn));
end

% --- Base dwell ----------------------------------------------------------
baseFrames = configField(options, 'baseDwellFrames', []);
baseS      = configField(options, 'baseDwellS',      []);
if ~isempty(baseFrames) && ~isempty(baseS)
    error('tfp:patterns:dwellCorrection:conflictingBaseDwell', ...
        ['Supply either options.baseDwellFrames or options.baseDwellS, not ' ...
         'both — they are the same quantity in different units.']);
end
if isempty(baseFrames) && isempty(baseS)
    baseFrames = DEFAULT_BASE_DWELL_FRAMES;
elseif isempty(baseFrames)
    if ~isnumeric(baseS) || ~isscalar(baseS) || ~isfinite(baseS) || baseS <= 0
        error('tfp:patterns:dwellCorrection:badBaseDwell', ...
            'options.baseDwellS must be a positive finite scalar in seconds.');
    end
    baseFrames = round(double(baseS) / model.frameDurationS);
    if baseFrames < 1
        error('tfp:patterns:dwellCorrection:baseDwellTooShort', ...
            ['options.baseDwellS = %g s is shorter than one %g us binary ' ...
             'frame, so it cannot be expressed at all. The DMD''s dose ' ...
             'quantum is one frame.'], baseS, 1e6 * model.frameDurationS);
    end
end
if ~isnumeric(baseFrames) || ~isscalar(baseFrames) || ~isfinite(baseFrames) ...
        || baseFrames < 1 || mod(baseFrames, 1) ~= 0
    error('tfp:patterns:dwellCorrection:badBaseDwell', ...
        ['options.baseDwellFrames must be a positive whole number of 80 us ' ...
         'binary frames; got %s.'], mat2str(baseFrames));
end
baseFrames = double(baseFrames);

% --- Resolve the per-target relative brightness --------------------------
suppliedRad = toColumn(configField(options, 'radiusPx',          []));
suppliedI   = toColumn(configField(options, 'relativeIntensity', []));
suppliedR   = toColumn(configField(options, 'relativeResponse',  []));
calib       = configField(options, 'uniformityCalib', []);

hasPts = ~isempty(targetsPx);
nGiven = hasPts + ~isempty(suppliedRad) + ~isempty(suppliedI) + ~isempty(suppliedR);
if nGiven == 0
    error('tfp:patterns:dwellCorrection:noTargets', ...
        ['No targets supplied. Pass an N x 2 [col row] array of DMD ' ...
         'coordinates, or one of options.radiusPx / .relativeIntensity / ' ...
         '.relativeResponse.']);
end
if nGiven > 1
    error('tfp:patterns:dwellCorrection:ambiguousInput', ...
        ['Supply exactly ONE target specification: targetsPx, ' ...
         'options.radiusPx, options.relativeIntensity or ' ...
         'options.relativeResponse. Two disagreeing specifications would ' ...
         'silently mis-dose whichever one lost.']);
end

radiusPx = [];
relI     = [];
relR     = [];

if hasPts
    targetsPx = validateTargets(targetsPx);
    % Euclidean radius on the CHIP: the illumination Gaussian is a property
    % of the beam landing on the mirrors, so the sample-plane anisotropy of
    % handoff §5 plays no part in it.
    radiusPx = hypot(targetsPx(:,1) - model.patchCenterPx(1), ...
                     targetsPx(:,2) - model.patchCenterPx(2));
    if isempty(calib)
        relI   = gaussianRelativeIntensity(radiusPx, model.gaussianWaistPx);
        source = 'analytic';
    else
        % Consume the RESPONSE map (proportional to I^2) — see the header.
        relR   = interpolateResponseMap(calib, targetsPx, ...
                     configField(options, 'interpolation', 'linear'));
        source = 'measured';
    end

elseif ~isempty(suppliedRad)
    radiusPx = validateRadii(suppliedRad);
    if ~isempty(calib)
        warning('tfp:patterns:dwellCorrection:calibIgnored', ...
            ['A uniformity map was supplied together with options.radiusPx. ' ...
             'A scalar radius cannot index a 2D measured map, so the ' ...
             'analytic Gaussian was used instead. Pass the targets as ' ...
             'N x 2 [col row] to use the measurement.']);
    end
    relI   = gaussianRelativeIntensity(radiusPx, model.gaussianWaistPx);
    source = 'analytic';

elseif ~isempty(suppliedI)
    relI   = double(suppliedI);
    source = 'suppliedIntensity';

else
    relR   = double(suppliedR);
    source = 'suppliedResponse';
end

% One square, in one place. Everything downstream works in g.
if isempty(relI)
    checkRelative(relR, 'relative response');
    relI = sqrt(relR);
else
    checkRelative(relI, 'relative intensity');
    relR = relI.^2;
end

nTargets = numel(relI);
if isempty(radiusPx)
    radiusPx = nan(nTargets, 1);
end

if any(relI > 1 + 1e-9)
    warning('tfp:patterns:dwellCorrection:aboveUnity', ...
        ['%d of %d targets have relative brightness > 1, so the supplied map ' ...
         'is not normalised to its own peak. Corrections below 1 shorten the ' ...
         'dwell relative to the base, which is legitimate but probably not ' ...
         'what you meant.'], nnz(relI > 1 + 1e-9), nTargets);
end

outsidePatch = radiusPx > model.patchRadiusPx;
if any(outsidePatch)
    worstR = max(radiusPx(outsidePatch));
    warning('tfp:patterns:dwellCorrection:outsidePatch', ...
        ['%d of %d targets lie outside the illuminated patch (worst radius ' ...
         '%.1f px vs patchRadiusPx %g). Out there the Gaussian is falling ' ...
         'fast, so the dwell correction grows without bound and the right ' ...
         'fix is a more central target, not a longer dwell. Containment ' ...
         'itself is enforced by tfp.util.assertPatternInPatch.'], ...
        nnz(outsidePatch), nTargets, worstR, model.patchRadiusPx);
end

% --- Correction ----------------------------------------------------------
% THE line. exponent = 2 equalises 2p excitation, 1 equalises energy.
correction = relI .^ (-exponent);

maxCorrection = configField(options, 'maxCorrection', 10);
maxDwell      = configField(options, 'maxDwellFrames', Inf);
checkPositiveScalar(maxCorrection, 'options.maxCorrection');
if ~isnumeric(maxDwell) || ~isscalar(maxDwell) || isnan(maxDwell) || maxDwell < 1
    error('tfp:patterns:dwellCorrection:badValue', ...
        'options.maxDwellFrames must be a scalar >= 1 (or Inf).');
end

clipped = correction > maxCorrection;
correction(clipped) = maxCorrection;

exactFrames = baseFrames * correction;

% Quantise: dose exists only in whole frames.
dwellFrames = max(1, round(exactFrames));

clippedByDwell = dwellFrames > maxDwell;
if any(clippedByDwell)
    dwellFrames(clippedByDwell) = floor(maxDwell);
    exactFrames(clippedByDwell) = min(exactFrames(clippedByDwell), maxDwell);
end
clipped = clipped | clippedByDwell;

if any(clipped)
    warning('tfp:patterns:dwellCorrection:correctionClipped', ...
        ['%d of %d targets needed more correction than the cap allows ' ...
         '(maxCorrection %g, maxDwellFrames %g) and were clipped. Those ' ...
         'targets are UNDER-DOSED relative to the centre — treat them as ' ...
         'unequalised, or move them inward.'], ...
        nnz(clipped), nTargets, maxCorrection, maxDwell);
end

% Relative dose error from the rounding. Dose is linear in dwell in both
% modes, so the dwell error and the dose error are the same number.
achieved  = dwellFrames / baseFrames;
quantErr  = (dwellFrames - exactFrames) ./ exactFrames;

tol = configField(options, 'quantizationTolerance', 0.02);
checkPositiveScalar(tol, 'options.quantizationTolerance');
searchCap = configField(options, 'maxBaseDwellSearch', 2000);
checkPositiveScalar(searchCap, 'options.maxBaseDwellSearch');

maxQuantErr    = max(abs(quantErr));
quantizationOk = maxQuantErr <= tol;
minBase        = minBaseDwellFor(correction, tol, floor(searchCap));

if ~quantizationOk && logical(configField(options, 'warnOnQuantization', true))
    [~, worstQ] = max(abs(quantErr));
    if isnan(minBase)
        advice = sprintf(['no base dwell up to %d frames meets it — relax ' ...
            'options.quantizationTolerance or accept the error'], floor(searchCap));
    else
        advice = sprintf('use options.baseDwellFrames >= %d', minBase);
    end
    warning('tfp:patterns:dwellCorrection:dwellQuantization', ...
        ['Dwell correction cannot be represented within %.1f%% at a base ' ...
         'dwell of %d frame(s): target %d wants %.3fx but the nearest whole ' ...
         'frame count (%d) delivers %.3fx, a %+.1f%% dose error. Dwell is ' ...
         'quantised to whole %g us frames, so a short base dwell has few ' ...
         'levels to choose from (at 1 frame the only options are 1.00x and ' ...
         '2.00x). To fix: %s.'], ...
        100*tol, baseFrames, worstQ, correction(worstQ), dwellFrames(worstQ), ...
        achieved(worstQ), 100*quantErr(worstQ), 1e6*model.frameDurationS, advice);
end

% --- Sequence-level cost -------------------------------------------------
% Targets are stimulated one pattern at a time, so the flat-fielded sequence
% costs the SUM of the corrected dwells. This is the number that tells a
% caller whether equalising a wide ensemble is affordable.
[worstCorrection, worstIdx] = max(correction);
totalFrames        = sum(dwellFrames);
uncorrectedFrames  = nTargets * baseFrames;

dwell.dwellFrames            = dwellFrames;
dwell.dwellS                 = dwellFrames * model.frameDurationS;
dwell.exactDwellFrames       = exactFrames;
dwell.correction             = correction;
dwell.achievedCorrection     = achieved;
dwell.relativeIntensity      = relI;
dwell.relativeResponse       = relR;
dwell.radiusPx               = radiusPx;
dwell.outsidePatch           = logical(outsidePatch);
dwell.quantizationErrorFrac  = quantErr;

dwell.worstCaseCorrection      = worstCorrection;
dwell.worstCaseTargetIdx       = worstIdx;
dwell.maxQuantizationErrorFrac = maxQuantErr;
dwell.quantizationOk           = quantizationOk;
dwell.minBaseDwellFrames       = minBase;

dwell.totalFrames             = totalFrames;
dwell.totalDurationS          = totalFrames * model.frameDurationS;
dwell.uncorrectedTotalFrames  = uncorrectedFrames;
dwell.uncorrectedDurationS    = uncorrectedFrames * model.frameDurationS;
dwell.timeCostFactor          = totalFrames / uncorrectedFrames;

dwell.nTargets          = nTargets;
dwell.baseDwellFrames   = baseFrames;
dwell.baseDwellS        = baseFrames * model.frameDurationS;
dwell.mode              = mode;
dwell.exponent          = exponent;
dwell.equalises         = equalises;
dwell.source            = source;
dwell.clipped           = logical(clipped);
dwell.frameDurationS    = model.frameDurationS;
dwell.binaryFrameRateHz = model.binaryFrameRateHz;
dwell.model             = model;

dwell.description = sprintf( ...
    ['%d target(s), %s map, mode ''%s'' (equalises %s): worst correction ' ...
     '%.2fx at target %d, %d frames total = %.1f ms (%.2fx the uncorrected ' ...
     '%.1f ms), worst quantisation error %+.1f%%'], ...
    nTargets, source, mode, equalises, worstCorrection, worstIdx, ...
    totalFrames, 1e3 * dwell.totalDurationS, dwell.timeCostFactor, ...
    1e3 * dwell.uncorrectedDurationS, 100 * maxQuantErr);
end

% =========================================================================
% Local functions
% =========================================================================

function g = gaussianRelativeIntensity(radiusPx, waistPx)
%gaussianRelativeIntensity Handoff §8: I(r)/I0 = exp(-2 r^2 / w^2).
%   The fallback used before measureIlluminationUniformity has been run.
%   Design intent, not calibration — prefer the measured map when one exists.
g = exp(-2 * (radiusPx(:).^2) / (waistPx^2));
end

function relR = interpolateResponseMap(calib, targetsPx, method)
%interpolateResponseMap Sample the measured 2p-response map at the targets.
%   Consumes calib.intensityNorm, which is proportional to I^2 (see the
%   header's discussion of the square). Unreachable grid points are NaN in
%   that map and are dropped before interpolating.
if ~isstruct(calib) || ~isscalar(calib) || ~isfield(calib, 'dmdGridPts')
    error('tfp:patterns:dwellCorrection:badCalib', ...
        ['options.uniformityCalib must be the scalar struct returned by ' ...
         'tfp.calibration.measureIlluminationUniformity (it needs at least ' ...
         '.dmdGridPts and .intensityNorm).']);
end

if isfield(calib, 'intensityNorm') && ~isempty(calib.intensityNorm)
    vals = double(calib.intensityNorm(:));
elseif isfield(calib, 'intensitySqrtNorm') && ~isempty(calib.intensitySqrtNorm)
    % Only the sqrt map survived; square it back into a response map so the
    % exponent bookkeeping stays in one place.
    vals = double(calib.intensitySqrtNorm(:)).^2;
else
    error('tfp:patterns:dwellCorrection:badCalib', ...
        ['options.uniformityCalib carries neither .intensityNorm nor ' ...
         '.intensitySqrtNorm, so there is no flat-field map to consume.']);
end

grid = double(calib.dmdGridPts);
if size(grid, 2) ~= 2 || size(grid, 1) ~= numel(vals)
    error('tfp:patterns:dwellCorrection:badCalib', ...
        ['calib.dmdGridPts must be nPts x 2 and match numel of the ' ...
         'flat-field map (got %s vs %d values).'], mat2str(size(grid)), numel(vals));
end

% Reachable points only: NaN marks a grid point outside the lit footprint.
keep = all(isfinite(grid), 2) & isfinite(vals) & vals > 0;
if isfield(calib, 'reachable') && numel(calib.reachable) == numel(vals)
    keep = keep & logical(calib.reachable(:));
end
if nnz(keep) < 3
    error('tfp:patterns:dwellCorrection:calibTooSparse', ...
        ['Only %d usable point(s) in the uniformity map; at least 3 are ' ...
         'needed to interpolate. Re-run measureIlluminationUniformity, or ' ...
         'omit options.uniformityCalib to fall back to the analytic ' ...
         'Gaussian.'], nnz(keep));
end
gx = grid(keep, 1); gy = grid(keep, 2); gv = vals(keep);

% Warn before extrapolating: outside the measured extent the "measurement"
% is really a guess, and the caller should know which it got.
if any(targetsPx(:,1) < min(gx) | targetsPx(:,1) > max(gx) | ...
       targetsPx(:,2) < min(gy) | targetsPx(:,2) > max(gy))
    warning('tfp:patterns:dwellCorrection:extrapolatedFromMap', ...
        ['%d target(s) lie outside the measured grid extent ' ...
         '(col %.0f..%.0f, row %.0f..%.0f), so their brightness is ' ...
         'extrapolated rather than measured.'], ...
        nnz(targetsPx(:,1) < min(gx) | targetsPx(:,1) > max(gx) | ...
            targetsPx(:,2) < min(gy) | targetsPx(:,2) > max(gy)), ...
        min(gx), max(gx), min(gy), max(gy));
end

method = lower(char(method));
if ~ismember(method, {'linear', 'nearest'})
    error('tfp:patterns:dwellCorrection:badInterpolation', ...
        'options.interpolation must be ''linear'' or ''nearest''; got ''%s''.', method);
end

relR = [];
if strcmp(method, 'linear')
    % scatteredInterpolant is base MATLAB, but it refuses degenerate point
    % sets (collinear/duplicated), so fall back rather than fail the run.
    try
        F = scatteredInterpolant(gx, gy, gv, 'linear', 'nearest');
        relR = F(targetsPx(:,1), targetsPx(:,2));
    catch
        relR = [];
    end
end
if isempty(relR)
    relR = nearestValue(gx, gy, gv, targetsPx);
end
relR = relR(:);
end

function v = nearestValue(gx, gy, gv, pts)
%nearestValue Nearest-neighbour lookup, no toolbox dependency.
v = zeros(size(pts, 1), 1);
for k = 1:size(pts, 1)
    d2 = (gx - pts(k,1)).^2 + (gy - pts(k,2)).^2;
    [~, iBest] = min(d2);
    v(k) = gv(iBest);
end
end

function nMin = minBaseDwellFor(correction, tol, cap)
%minBaseDwellFor Shortest base dwell whose rounding stays inside tolerance.
%   The actionable half of the quantisation report: "1 frame cannot express
%   1.65x" is only useful if the caller is also told what can.
nMin = NaN;
c = correction(:)';
c = c(isfinite(c) & c > 0);
if isempty(c)
    return;
end
for n = 1:cap
    exact = n * c;
    q = max(1, round(exact));
    if all(abs(q - exact) ./ exact <= tol)
        nMin = n;
        return;
    end
end
end

function pts = validateTargets(pts)
if ~isnumeric(pts) || isempty(pts) || ndims(pts) ~= 2 || size(pts, 2) ~= 2 %#ok<ISMAT>
    error('tfp:patterns:dwellCorrection:badTargets', ...
        ['targetsPx must be a non-empty N x 2 numeric array of [col row] ' ...
         'DMD pixel coordinates; got %s of size %s.'], ...
        class(pts), mat2str(size(pts)));
end
if ~all(isfinite(pts(:)))
    error('tfp:patterns:dwellCorrection:badTargets', ...
        'targetsPx must be finite; %d entrie(s) are NaN or Inf.', ...
        nnz(~isfinite(pts(:))));
end
pts = double(pts);
end

function r = validateRadii(r)
if ~isnumeric(r) || ~all(isfinite(r)) || any(r < 0)
    error('tfp:patterns:dwellCorrection:badRadius', ...
        'options.radiusPx must be finite and non-negative.');
end
r = double(r(:));
end

function checkRelative(v, name)
%checkRelative Reject values that cannot be a normalised brightness.
if ~isnumeric(v) || isempty(v) || ~isvector(v)
    error('tfp:patterns:dwellCorrection:badRelativeValue', ...
        '%s must be a non-empty numeric vector.', name);
end
bad = ~isfinite(v);
if any(bad)
    error('tfp:patterns:dwellCorrection:targetNotIlluminated', ...
        ['%s is NaN/Inf for target(s) %s. In a measured map NaN means the ' ...
         'spot was never detected — that target is outside the illuminated ' ...
         'footprint and no dwell can fix it.'], name, mat2str(find(bad(:))'));
end
if any(v <= 0)
    error('tfp:patterns:dwellCorrection:badRelativeValue', ...
        ['%s must be strictly positive for target(s) %s — a zero-brightness ' ...
         'target needs infinite dwell, which is a targeting problem, not a ' ...
         'timing one.'], name, mat2str(find(v(:) <= 0)'));
end
end

function checkPositiveScalar(v, name)
if ~isnumeric(v) || ~isscalar(v) || isnan(v) || v <= 0
    error('tfp:patterns:dwellCorrection:badValue', ...
        '%s must be a positive scalar.', name);
end
end

function v = toColumn(v)
if ~isempty(v) && isnumeric(v)
    v = v(:);
end
end

function value = configField(s, name, default)
%configField Standard repo helper: read a field with a fallback.
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    value = s.(name);
else
    value = default;
end
end
