function depth = targetDepthOffset(targetsPx, options)
%targetDepthOffset Per-target depth (z) offset from the tilted excitation plane, and the ensemble spread.
%
%   depth = tfp.util.targetDepthOffset(targetsPx)
%   depth = tfp.util.targetDepthOffset(targetsPx, options)
%
%   THE FIELD IS NOT ONE FOCAL PLANE (docs/dmd_control_handoff.md §6). The
%   temporal-focusing grating tilts the surface of best 2p focus by 1.245°,
%   entirely along the DISPERSION axis:
%
%       z_um ≈ x_disp * 0.02174        (x_disp in sample µm; sign %VERIFY)
%
%   Across the design patch that is a **17.1 µm depth walk against a 17.7 µm
%   axial FWHM**, so two targets at opposite field edges are genuinely NOT in
%   the same plane and **no single objective Z brings both into focus**. There
%   is no PLM in this build, so the tilt cannot be corrected optically — but it
%   is deterministic, and §6 is explicit that the control code should REPORT
%   it rather than hide it. That reporting is what this function is for.
%
%   ---------------------------------------------------------------------
%   *** WHY YOU SHOULD CARE, IN ONE PARAGRAPH. ***
%   ---------------------------------------------------------------------
%   An ensemble whose targets span an appreciable fraction of the axial FWHM
%   is an ensemble in which the peripheral cells are partly OUT OF FOCUS.
%   They therefore receive less 2p excitation than the central ones for
%   reasons that have nothing to do with biology, and the resulting
%   position-dependent response gradient looks exactly like a real spatial
%   effect — connectivity, opsin gradient, distance-dependent recruitment.
%   It is an optical artefact of a tilted plane. This function computes the
%   spread and says so in words (`:ensembleDepthSpread` /
%   `:exceedsAxialFwhm`), names the worst-offending pair so you know which
%   cells to drop, and reports the objective Z that best splits the
%   difference if you keep them.
%
%   TWO TIERS, AND WHERE THE DESIGN CASE LANDS. `:ensembleDepthSpread` fires
%   from half an axial FWHM (configurable); `:exceedsAxialFwhm` — the
%   categorical "no objective Z holds both" — needs a FULL FWHM and
%   supersedes it. The design full-field pair lands at 17.118/17.7 = 0.967,
%   i.e. just BELOW the hard tier: at the compromise Z each of those two
%   targets sits 0.48 FWHM off focus, technically still inside the
%   half-maximum. So the flagship case gets the soft warning, correctly. Do
%   not read that as reassurance — §6 quotes the 17.7 µm FWHM as
%   `[LOW ±40%]`, so a focus 30% tighter than the estimate tips exactly this
%   geometry over the line, and "both cells are at their half-maximum" is
%   already a large excitation difference from a cell at the centre.
%
%   Note this is a DIFFERENT artefact from the one
%   tfp.patterns.dwellCorrection fixes. That one is lateral illumination
%   fall-off (the Gaussian, §8) and is correctable in time. This one is
%   defocus, and dwell does not fix it: holding an out-of-focus cell longer
%   raises its dose but not its peak intensity, and 2p excitation is not
%   linear in dose. The two effects are both radial-looking and both bias the
%   same figure, so quote both.
%
%   ---------------------------------------------------------------------
%   *** THE MAP. NEVER A SCALAR µm/px. ***
%   ---------------------------------------------------------------------
%   The chip is clocked 45°, so the optical axes are the chip DIAGONALS, and
%   the sample scale is anisotropic (1.4162 µm/px dispersion, 1.1250 µm/px
%   groove). The depth gradient lives on the dispersion diagonal, so getting
%   from a DMD pixel coordinate to `x_disp` REQUIRES the anisotropic map.
%   This function therefore routes every target through
%   tfp.patterns.dmdToSampleOffset and never multiplies by a scalar µm/px.
%   T-BU-3b measured the cost of the scalar shortcut on this exact quantity:
%   it was 12.2% wrong (a 1.3973° tilt instead of 1.2454°). Do not
%   "simplify" this back.
%
%   ---------------------------------------------------------------------
%   *** MEASURED BEATS DESIGN. ***
%   ---------------------------------------------------------------------
%   Pass `options.sampleTilt` (the `calib.sampleTilt` struct from
%   tfp.calibration.measureFocalPlaneTilt) or `options.calib` (the whole
%   calib struct) and the MEASURED gradient is used, groove-axis component
%   and all. Without one, the design gradient from tfp.util.opticalModel is
%   used and `depth.source` says `'design'`. Handoff §9: the design numbers
%   are intent, not calibration. A measured tilt struct that is present but
%   invalid warns (`:invalidMeasuredTilt`) and falls back — it never silently
%   degrades to design intent.
%
%   ---------------------------------------------------------------------
%   *** THE SIGN IS UNRESOLVED (%VERIFY, TASKS.md T-BU-M4). ***
%   ---------------------------------------------------------------------
%   Two bench conventions are unsettled: which chip diagonal is +dispersion
%   (`dmd.dispersionAxisSign`, applied inside dmdToSampleOffset) and which way
%   depth runs along it (`dmd.depthGradientSign`, applied here). They COMPOSE,
%   so only their product is physically observable, and until a two-point
%   calibration settles it the SIGN of `depth.zUm` — i.e. which way to move
%   the objective — is a guess. Both signs are honoured so that flipping the
%   config flips the answer.
%
%   What is NOT a guess, and is the reason this function is still worth
%   running before T-BU-M4: **every ensemble quantity here is sign-invariant**.
%   Flipping either sign negates all z together, which leaves the spread, the
%   worst pair, and the "can these two be in focus at once" verdict exactly
%   unchanged. A test pins that. So trust `.spreadUm`; treat the sign of
%   `.zUm` as provisional. A measured tilt carries its own sign and
%   `depth.signResolved` is then true.
%
%   Inputs:
%     targetsPx - N x 2 numeric [col row] DMD pixel coordinates (1-indexed,
%                 origin top-left, per CLAUDE.md), matching the ordering used
%                 by tfp.patterns.singleSpot / multiSpot. Depth is reported
%                 relative to the plane's height at the reference point
%                 (default: the illumination patch centre), so a target at the
%                 centre gets z = 0 by construction.
%     options - struct, all fields optional:
%       .config          - config struct (or an opticalModel struct) forwarded
%                          to tfp.util.opticalModel. Supplies the patch centre,
%                          the axis scales, the design gradient/sign and the
%                          axial FWHM. Nothing here hardcodes 0.02174, 1.245
%                          or 17.7 (T-BU-0).
%       .model           - alias for .config.
%       .sampleTilt      - MEASURED tilt: the `.sampleTilt` struct from
%                          tfp.calibration.measureFocalPlaneTilt. Needs
%                          `.valid` and `.gradientUmPerUm` = [dispersion
%                          groove] (or the two scalar fields
%                          `.gradientDispersionUmPerUm` /
%                          `.gradientGrooveUmPerUm`). Supersedes design.
%       .calib           - the whole measureFocalPlaneTilt calib struct; its
%                          `.sampleTilt` is used. Supplying both is an error.
%       .dmdToSampleLinear - 2x2/3x3 linear part of a FITTED, µm-valued
%                          DMD→sample affine, superseding the design axis
%                          scales (handoff §9). Do NOT pass
%                          calibration.dmdToSample_affine — that field is
%                          CAMERA-valued; see tfp.patterns.dmdToSampleOffset.
%       .mapUnits, .cameraUmPerPixel - forwarded to that function's units guard.
%       .referencePx     - 1x2 [col row] the z = 0 reference. Default
%                          model.patchCenterPx (the ILLUMINATION centre, not
%                          necessarily the chip centre — see T-BU-M3).
%       .axialFwhmUm     - override the axial FWHM (default model.axialFwhmUm
%                          = 17.7 µm, quoted `[LOW ±40%]` in §6 — the tolerance
%                          on the yardstick is wider than most of the numbers
%                          it is compared against).
%       .spreadFwhmFraction - fraction of the axial FWHM the ensemble spread
%                          may reach before `:ensembleDepthSpread` fires.
%                          Default 0.5 (half an FWHM), matching
%                          measureFocalPlaneTilt's `walkFwhmFraction`, whose
%                          name is also accepted.
%       .warnOnSpread    - logical, default true. Suppresses the two spread
%                          warnings only; the verdict fields are unaffected.
%       .verbose         - logical, default false. Prints `.report`.
%
%   Output struct `depth`:
%     Per target (N x 1 unless stated)
%       .zUm                depth offset from the reference plane, µm. THE
%                           per-target number. Positive/negative sense is
%                           %VERIFY until T-BU-M4.
%       .sampleOffsetUm     N x 2 [x_disp y_groove] µm from the reference.
%       .dispersionUm/.grooveUm  those two columns, for convenience.
%       .dmdOffsetPx        N x 2 [dCol dRow] from the reference.
%       .radiusPx           DMD-pixel radius from the reference.
%       .outsidePatch       logical, radius > model.patchRadiusPx.
%       .defocusAtCompromiseUm  .zUm - .suggestedObjectiveZUm.
%       .inFocusAtCompromise    |defocus| <= axialFwhm/2.
%       .zRelativeToMeanUm  .zUm - mean(.zUm).
%     Ensemble
%       .spreadUm           max(z) - min(z). The headline number, and the one
%                           that is sign-invariant.
%       .spreadInAxialFwhm  .spreadUm / .axialFwhmUm.
%       .zMinUm/.zMaxUm/.zMeanUm/.zMedianUm
%       .worstPairIdx       [iDeepest jShallowest] — the two targets furthest
%                           apart in depth. Drop one of these, or split the
%                           difference.
%       .worstPairSeparationUm / .worstPairSeparationInAxialFwhm
%       .worstPairTargetsPx 2 x 2 [col row] of those two targets.
%       .suggestedObjectiveZUm  mid-range of z: the single objective Z that
%                           minimises the WORST defocus in the ensemble
%                           (worst = .spreadUm/2).
%       .worstDefocusAtCompromiseUm  .spreadUm/2.
%       .nOutOfFocusAtCompromise / .allInFocusAtCompromise
%       .spreadAfterDroppingDeepestUm / .spreadAfterDroppingShallowestUm
%                           what dropping either extreme buys (NaN for N = 1).
%       .maxSpanUm          how far apart two targets may be along the tilt
%                           direction before they span one axial FWHM
%                           (axialFwhm / |gradient|).
%     Verdicts (assertable, no I/O)
%       .exceedsThreshold   spread >= spreadFwhmFraction * axialFwhm.
%       .exceedsAxialFwhm   spread >= axialFwhm — the categorical case.
%       .spreadFwhmFraction / .axialFwhmUm
%     Provenance
%       .source             'measured' | 'design'.
%       .gradientUmPerUm    [dispersion groove] µm depth per sample µm, as used.
%       .gradientDispersionUmPerUm / .gradientGrooveUmPerUm
%       .tiltAngleDeg       atand(norm(gradient)).
%       .signResolved       false for the design source (%VERIFY, T-BU-M4).
%       .depthGradientSign  the sign actually applied (design source only).
%       .referencePx, .nTargets, .model, .report, .description
%
%   Warnings (stable identifiers — nothing assertable is printed):
%     tfp:util:targetDepthOffset:ensembleDepthSpread - the ensemble spans at
%       least `spreadFwhmFraction` of an axial FWHM in depth.
%     tfp:util:targetDepthOffset:exceedsAxialFwhm - it spans a FULL axial
%       FWHM or more: the extremes CANNOT both be in focus at any objective Z.
%       This is the harder statement and SUPERSEDES the one above (only one of
%       the two ever fires), the same precedence rule
%       tfp.util.assertPatternInPatch uses for its two radii.
%     tfp:util:targetDepthOffset:invalidMeasuredTilt - a measured tilt was
%       supplied but is unusable; the design gradient was used instead.
%     tfp:util:targetDepthOffset:outsidePatch - a target lies outside
%       model.patchRadiusPx, so its depth extrapolates the plane beyond where
%       it was measured (containment itself is tfp.util.assertPatternInPatch).
%
%   Errors: tfp:util:targetDepthOffset:<reason>
%
%   Wiring into the Sequencer is deliberately NOT done here — that is
%   TASKS.md T-BU-4b. This is a pure function: no hardware, no state, no I/O.
%
%   See also tfp.calibration.measureFocalPlaneTilt, tfp.util.opticalModel,
%            tfp.patterns.dmdToSampleOffset, tfp.patterns.dwellCorrection.

if nargin < 2 || isempty(options)
    options = struct();
end
if ~isstruct(options) || ~isscalar(options)
    error('tfp:util:targetDepthOffset:badOptions', ...
        'options must be a scalar struct; got %s.', class(options));
end

% Single source of truth for the patch geometry, the axis scales, the design
% gradient and the axial FWHM. No optical constant is written literally below.
cfg = configField(options, 'config', configField(options, 'model', struct()));
if ~isstruct(cfg)
    error('tfp:util:targetDepthOffset:badConfig', ...
        ['options.config (or options.model) must be a struct that ' ...
         'tfp.util.opticalModel accepts; got %s.'], class(cfg));
end
model = tfp.util.opticalModel(cfg);

targetsPx = validateTargets(targetsPx);
nTargets  = size(targetsPx, 1);

referencePx = configField(options, 'referencePx', model.patchCenterPx);
if ~isnumeric(referencePx) || numel(referencePx) ~= 2 || ~all(isfinite(referencePx))
    error('tfp:util:targetDepthOffset:badReference', ...
        'options.referencePx must be a finite 1x2 [col row]; got %s.', ...
        mat2str(referencePx));
end
referencePx = double(referencePx(:))';

axialFwhmUm = configField(options, 'axialFwhmUm', model.axialFwhmUm);
checkPositiveScalar(axialFwhmUm, 'options.axialFwhmUm');
axialFwhmUm = double(axialFwhmUm);

% `walkFwhmFraction` is measureFocalPlaneTilt's name for the same knob; accept
% it so an operator can pass one tolerance struct to both.
fwhmFraction = configField(options, 'spreadFwhmFraction', ...
                   configField(options, 'walkFwhmFraction', 0.5));
checkPositiveScalar(fwhmFraction, 'options.spreadFwhmFraction');
fwhmFraction = double(fwhmFraction);

warnOnSpread = logical(configField(options, 'warnOnSpread', true));
verbose      = logical(configField(options, 'verbose', false));

% --- Lateral: DMD pixels -> sample µm, through the anisotropic map ---------
% THE line that must never become a scalar multiply. The depth gradient lives
% on the dispersion diagonal of a 45°-clocked chip, so the [col row] -> [disp
% groove] rotation AND the 1.26x anisotropy both matter; T-BU-3b measured a
% 12.2% error from doing this with one µm/px number.
[mapSpec, mapArgs] = resolveMapSpec(options, cfg);
dmdOffsetPx   = targetsPx - referencePx;
sampleOffsetUm = tfp.patterns.dmdToSampleOffset(dmdOffsetPx, mapSpec, mapArgs{:});

% --- Depth gradient: measured if we have one, design otherwise ------------
[gradient, source, signResolved, appliedSign] = resolveGradient(options, model);

% z = g . s. With a design gradient the groove term is exactly zero (the
% grating disperses along one diagonal only); a measured gradient may carry a
% groove component, and if it does it is real data and is used as given —
% measureFocalPlaneTilt has already raised its own :grooveComponent flag.
zUm = sampleOffsetUm * gradient(:);

% --- Ensemble statistics --------------------------------------------------
[zMax, iDeep]    = max(zUm);
[zMin, jShallow] = min(zUm);
spreadUm         = zMax - zMin;
spreadInFwhm     = spreadUm / axialFwhmUm;

% The objective Z that minimises the WORST defocus is the mid-range, not the
% mean: defocus is a max-norm problem, so the midpoint of the extremes is the
% minimax solution and every target then sits within spread/2 of focus.
compromiseZUm = 0.5 * (zMax + zMin);
defocusUm     = zUm - compromiseZUm;
inFocus       = abs(defocusUm) <= 0.5 * axialFwhmUm;

exceedsThreshold = spreadInFwhm >= fwhmFraction;
exceedsFwhm      = spreadInFwhm >= 1;

radiusPx     = hypot(dmdOffsetPx(:,1), dmdOffsetPx(:,2));
outsidePatch = radiusPx > model.patchRadiusPx;

% How far apart two targets may be along the steepest (tilt) direction before
% they span one axial FWHM. The dual of the spread: a targeting budget.
gradMag = norm(gradient);
if gradMag > 0
    maxSpanUm = axialFwhmUm / gradMag;
else
    maxSpanUm = Inf;
end

% What dropping either extreme buys. The actionable half of "name the worst
% pair": with 2 targets dropping one trivially leaves zero spread, which is
% still the right answer; with 1 there is nothing to drop.
if nTargets >= 2
    spreadDropDeep    = rangeExcluding(zUm, iDeep);
    spreadDropShallow = rangeExcluding(zUm, jShallow);
else
    spreadDropDeep    = NaN;
    spreadDropShallow = NaN;
end

% --- Assemble -------------------------------------------------------------
depth.zUm                    = zUm;
depth.sampleOffsetUm         = sampleOffsetUm;
depth.dispersionUm           = sampleOffsetUm(:,1);
depth.grooveUm               = sampleOffsetUm(:,2);
depth.dmdOffsetPx            = dmdOffsetPx;
depth.radiusPx               = radiusPx;
depth.outsidePatch           = logical(outsidePatch);
depth.defocusAtCompromiseUm  = defocusUm;
depth.inFocusAtCompromise    = inFocus;
depth.zRelativeToMeanUm      = zUm - mean(zUm);

depth.spreadUm               = spreadUm;
depth.spreadInAxialFwhm      = spreadInFwhm;
depth.zMinUm                 = zMin;
depth.zMaxUm                 = zMax;
depth.zMeanUm                = mean(zUm);
depth.zMedianUm              = median(zUm);

if nTargets >= 2
    depth.worstPairIdx       = [iDeep, jShallow];
    depth.worstPairTargetsPx = targetsPx([iDeep, jShallow], :);
else
    depth.worstPairIdx       = [1 1];
    depth.worstPairTargetsPx = targetsPx([1 1], :);
end
depth.worstPairSeparationUm          = spreadUm;
depth.worstPairSeparationInAxialFwhm = spreadInFwhm;

depth.suggestedObjectiveZUm          = compromiseZUm;
depth.worstDefocusAtCompromiseUm     = 0.5 * spreadUm;
depth.nOutOfFocusAtCompromise        = nnz(~inFocus);
depth.allInFocusAtCompromise         = all(inFocus);
depth.spreadAfterDroppingDeepestUm   = spreadDropDeep;
depth.spreadAfterDroppingShallowestUm = spreadDropShallow;
depth.maxSpanUm                      = maxSpanUm;

depth.exceedsThreshold       = exceedsThreshold;
depth.exceedsAxialFwhm       = exceedsFwhm;
depth.spreadFwhmFraction     = fwhmFraction;
depth.axialFwhmUm            = axialFwhmUm;

depth.source                     = source;
depth.gradientUmPerUm            = gradient(:)';
depth.gradientDispersionUmPerUm  = gradient(1);
depth.gradientGrooveUmPerUm      = gradient(2);
depth.tiltAngleDeg               = atand(gradMag);
depth.signResolved               = signResolved;
depth.depthGradientSign          = appliedSign;
depth.referencePx                = referencePx;
depth.nTargets                   = nTargets;
depth.model                      = model;

depth.report = depthReport(depth);

depth.description = sprintf( ...
    ['%d target(s), %s tilt (%.5g um/um dispersion, %.5g groove; %.3f deg): ' ...
     'depth spread %.2f um = %.2f of the %.1f um axial FWHM, worst pair ' ...
     '(%d, %d); best single objective Z %+.2f um leaves worst defocus ' ...
     '%.2f um'], ...
    nTargets, source, gradient(1), gradient(2), depth.tiltAngleDeg, ...
    spreadUm, spreadInFwhm, axialFwhmUm, ...
    depth.worstPairIdx(1), depth.worstPairIdx(2), ...
    compromiseZUm, depth.worstDefocusAtCompromiseUm);

% --- Say it out loud ------------------------------------------------------
if any(outsidePatch)
    warning('tfp:util:targetDepthOffset:outsidePatch', ...
        ['%d of %d target(s) lie outside the illuminated patch (worst radius ' ...
         '%.1f px vs patchRadiusPx %g), so their depth EXTRAPOLATES the tilted ' ...
         'plane beyond the region it describes. The depth number is still ' ...
         'reported, but the target should not be projected at all -- ' ...
         'containment is enforced by tfp.util.assertPatternInPatch.'], ...
        nnz(outsidePatch), nTargets, max(radiusPx(outsidePatch)), ...
        model.patchRadiusPx);
end

if warnOnSpread && nTargets >= 2
    warnEnsembleSpread(depth);
end

if verbose
    fprintf('%s\n', depth.report);
end
end

% =========================================================================
% Local functions
% =========================================================================

function warnEnsembleSpread(d)
%warnEnsembleSpread The point of the whole function, in words.
%   Two tiers, and only ONE fires: `:exceedsAxialFwhm` is the strictly harder
%   statement, so it supersedes `:ensembleDepthSpread` rather than doubling up
%   (the precedence rule tfp.util.assertPatternInPatch uses for its two radii).
if d.exceedsAxialFwhm
    warning('tfp:util:targetDepthOffset:exceedsAxialFwhm', ...
        ['THESE TARGETS CANNOT ALL BE IN FOCUS AT ONCE. The ensemble spans ' ...
         '%.2f um of DEPTH, which is %.2f of the %.1f um axial FWHM -- a full ' ...
         'FWHM or more. Targets %d and %d are the extremes (%+.2f and %+.2f um ' ...
         'from the reference plane, %.2f um apart); there is NO objective Z ' ...
         'that puts both inside the axial FWHM.\n' ...
         'This is the tilted excitation surface of handoff sec 6, not a fault, ' ...
         'and with no PLM on this build it cannot be corrected optically. ' ...
         'What it does to an experiment: the off-focus cells receive less 2p ' ...
         'excitation for purely optical reasons, so the ensemble will show a ' ...
         'SPURIOUS POSITION-DEPENDENT RESPONSE GRADIENT that looks biological ' ...
         '(distance-dependent recruitment, an opsin gradient) and is not. ' ...
         'Note dwell correction does NOT rescue this -- it fixes lateral ' ...
         'illumination fall-off, not defocus.\n' ...
         'Fix: drop target %d or %d (dropping the first leaves %.2f um of ' ...
         'spread, the second %.2f um), or keep the ensemble within about ' ...
         '%.0f um along the tilt direction. If you keep them, objective ' ...
         'Z %+.2f um splits the difference and leaves every target within ' ...
         '%.2f um of focus -- and %d of %d still fall outside the FWHM there. ' ...
         'The SIGN of these offsets is %%VERIFY (TASKS.md T-BU-M4); the ' ...
         'spread itself is sign-invariant and does not depend on it.'], ...
        d.spreadUm, d.spreadInAxialFwhm, d.axialFwhmUm, ...
        d.worstPairIdx(1), d.worstPairIdx(2), d.zMaxUm, d.zMinUm, d.spreadUm, ...
        d.worstPairIdx(1), d.worstPairIdx(2), ...
        d.spreadAfterDroppingDeepestUm, d.spreadAfterDroppingShallowestUm, ...
        d.maxSpanUm, d.suggestedObjectiveZUm, d.worstDefocusAtCompromiseUm, ...
        d.nOutOfFocusAtCompromise, d.nTargets);

elseif d.exceedsThreshold
    warning('tfp:util:targetDepthOffset:ensembleDepthSpread', ...
        ['ENSEMBLE SPANS %.2f um OF DEPTH -- %.2f of the %.1f um axial FWHM ' ...
         '(threshold %.2f). Targets %d and %d are the extremes (%+.2f and ' ...
         '%+.2f um from the reference plane).\n' ...
         'They are not in the same plane: the excitation surface is tilted ' ...
         '%.3f deg (handoff sec 6) and there is no PLM to correct it. At one ' ...
         'objective Z the more defocused cells get less 2p excitation for ' ...
         'purely optical reasons, which shows up as a position-dependent ' ...
         'response gradient that is easy to mistake for a biological one. ' ...
         'Lateral dwell correction does not fix defocus.\n' ...
         'Objective Z %+.2f um minimises the worst defocus (%.2f um); ' ...
         'alternatively keep the ensemble within about %.0f um along the ' ...
         'tilt direction, or drop target %d or %d. Sign of the offsets is ' ...
         '%%VERIFY (T-BU-M4); the spread is sign-invariant.'], ...
        d.spreadUm, d.spreadInAxialFwhm, d.axialFwhmUm, d.spreadFwhmFraction, ...
        d.worstPairIdx(1), d.worstPairIdx(2), d.zMaxUm, d.zMinUm, ...
        d.tiltAngleDeg, d.suggestedObjectiveZUm, ...
        d.worstDefocusAtCompromiseUm, d.maxSpanUm, ...
        d.worstPairIdx(1), d.worstPairIdx(2));
end
end

function report = depthReport(d)
%depthReport Experimenter-facing text of the depth picture.
%   Returned as a field rather than printed (options.verbose prints it), so a
%   test can assert on it -- same convention as measureFocalPlaneTilt.report.
L = {};
L{end+1} = 'Per-target depth from the tilted excitation plane (docs/dmd_control_handoff.md sec 6)';
L{end+1} = '---------------------------------------------------------------------------------';
L{end+1} = sprintf('  gradient source                    %s', upper(d.source));
L{end+1} = sprintf('  gradient, DISPERSION axis          %12.5f   um depth per um', ...
    d.gradientDispersionUmPerUm);
L{end+1} = sprintf('  gradient, GROOVE axis              %12.5f   um depth per um', ...
    d.gradientGrooveUmPerUm);
L{end+1} = sprintf('  surface tilt                       %12.3f   deg', d.tiltAngleDeg);
L{end+1} = sprintf('  axial FWHM                         %12.1f   um', d.axialFwhmUm);
L{end+1} = sprintf('  targets                            %12d', d.nTargets);
L{end+1} = sprintf('  depth spread                       %12.2f   um', d.spreadUm);
L{end+1} = sprintf('  spread / axial FWHM                %12.2f', d.spreadInAxialFwhm);
L{end+1} = sprintf('  best single objective Z            %+12.2f   um', d.suggestedObjectiveZUm);
L{end+1} = sprintf('  worst defocus at that Z            %12.2f   um', ...
    d.worstDefocusAtCompromiseUm);
L{end+1} = '';
L{end+1} = '  IN WORDS:';
if d.nTargets < 2
    L{end+1} = sprintf(['    Single target, %+.2f um from the reference plane. Nothing to ' ...
        'compare it'], d.zUm(1));
    L{end+1} =         '    against, so there is no ensemble depth spread to report.';
elseif d.exceedsAxialFwhm
    L{end+1} = sprintf(['    These targets CANNOT all be in focus at once. They span %.2f um in ' ...
        'depth,'], d.spreadUm);
    L{end+1} = sprintf(['    %.2f of the %.1f um axial FWHM. Targets %d and %d are the extremes ' ...
        'and no'], d.spreadInAxialFwhm, d.axialFwhmUm, d.worstPairIdx(1), d.worstPairIdx(2));
    L{end+1} =         '    objective Z brings both inside the FWHM. The out-of-focus cells will be';
    L{end+1} =         '    under-excited for optical reasons alone, which reads as a spurious';
    L{end+1} =         '    position-dependent response gradient. Drop one of the extremes, or';
    L{end+1} = sprintf(['    keep the ensemble within about %.0f um along the tilt direction.'], ...
        d.maxSpanUm);
elseif d.exceedsThreshold
    L{end+1} = sprintf(['    The ensemble spans %.2f um in depth, %.2f of the %.1f um axial ' ...
        'FWHM.'], d.spreadUm, d.spreadInAxialFwhm, d.axialFwhmUm);
    L{end+1} =         '    Targets at the extremes are partly defocused relative to each other, so';
    L{end+1} =         '    part of any response difference between them is optics, not biology.';
    L{end+1} = sprintf(['    Objective Z %+.2f um minimises the worst defocus (%.2f um).'], ...
        d.suggestedObjectiveZUm, d.worstDefocusAtCompromiseUm);
else
    L{end+1} = sprintf(['    The ensemble spans %.2f um in depth, only %.2f of the %.1f um axial ' ...
        'FWHM,'], d.spreadUm, d.spreadInAxialFwhm, d.axialFwhmUm);
    L{end+1} =         '    so a single objective Z holds every target inside the focal depth.';
end
L{end+1} = '';
if d.signResolved
    L{end+1} =         '    The depth SIGN comes from the measurement, so it is settled.';
else
    L{end+1} =         '    The depth SIGN is a design guess (%VERIFY, TASKS.md T-BU-M4): which chip';
    L{end+1} =         '    diagonal is +dispersion and which way depth runs along it are both';
    L{end+1} =         '    unresolved bench conventions. The SPREAD above is unaffected by either --';
    L{end+1} =         '    flipping a sign negates every z together -- but which way to move the';
    L{end+1} =         '    objective is not yet known.';
end
report = strjoin(L, newline);
end

function [gradient, source, signResolved, appliedSign] = resolveGradient(options, model)
%resolveGradient The MEASURED tilt when one is supplied, design otherwise.
%   Handoff sec 9: a measurement always beats design intent. A measured struct
%   that is present but unusable warns and falls back -- it must never
%   degrade silently, because the design gradient is groove-free and would
%   quietly erase a real groove component.
tiltIn  = configField(options, 'sampleTilt', []);
calibIn = configField(options, 'calib',      []);

if ~isempty(tiltIn) && ~isempty(calibIn)
    error('tfp:util:targetDepthOffset:conflictingTilt', ...
        ['Supply either options.sampleTilt or options.calib, not both -- ' ...
         'options.calib.sampleTilt is the same struct, and two disagreeing ' ...
         'tilts would silently mis-state every depth.']);
end

if isempty(tiltIn) && ~isempty(calibIn)
    if ~isstruct(calibIn) || ~isscalar(calibIn) || ~isfield(calibIn, 'sampleTilt')
        error('tfp:util:targetDepthOffset:badCalib', ...
            ['options.calib must be the scalar struct returned by ' ...
             'tfp.calibration.measureFocalPlaneTilt (it needs a .sampleTilt ' ...
             'field); got %s.'], class(calibIn));
    end
    tiltIn = calibIn.sampleTilt;
end

if ~isempty(tiltIn)
    [g, why] = measuredGradient(tiltIn);
    if isempty(why)
        gradient     = g;
        source       = 'measured';
        signResolved = true;
        appliedSign  = sign(g(1));
        if appliedSign == 0
            appliedSign = model.depthGradientSign;
        end
        return
    end
    warning('tfp:util:targetDepthOffset:invalidMeasuredTilt', ...
        ['The supplied measured tilt is unusable (%s), so the DESIGN gradient ' ...
         'from tfp.util.opticalModel was used instead. Design numbers are ' ...
         'intent, not calibration (handoff sec 9), and the design tilt is ' ...
         'groove-free -- if the rig really does have a groove-axis component, ' ...
         'this answer does not contain it. Re-run ' ...
         'tfp.calibration.measureFocalPlaneTilt, or omit the struct to ' ...
         'accept design intent knowingly.'], why);
end

% Design intent. depthGradientSign is honoured here (%VERIFY, T-BU-M4) and
% composes with dispersionAxisSign, which dmdToSampleOffset already applied to
% x_disp; only the product is observable.
appliedSign  = model.depthGradientSign;
gradient     = [appliedSign * model.depthGradientUmPerUm, 0];
source       = 'design';
signResolved = false;
end

function [g, why] = measuredGradient(tilt)
%measuredGradient Pull [dispersion groove] out of a measureFocalPlaneTilt struct.
%   `why` is empty on success, else a short reason for the fallback warning.
g   = [NaN NaN];
why = '';
if ~isstruct(tilt) || ~isscalar(tilt)
    why = sprintf('it is a %s, not a scalar struct', class(tilt));
    return
end
if isfield(tilt, 'valid') && ~tilt.valid
    why = 'its .valid flag is false, i.e. the plane fit did not succeed';
    return
end

if isfield(tilt, 'gradientUmPerUm') && numel(tilt.gradientUmPerUm) == 2
    g = double(tilt.gradientUmPerUm(:))';
elseif isfield(tilt, 'gradientDispersionUmPerUm') && isfield(tilt, 'gradientGrooveUmPerUm')
    g = [double(tilt.gradientDispersionUmPerUm), double(tilt.gradientGrooveUmPerUm)];
else
    why = ['it carries neither .gradientUmPerUm ([dispersion groove]) nor the ' ...
           'pair .gradientDispersionUmPerUm/.gradientGrooveUmPerUm'];
    return
end

if ~all(isfinite(g))
    why = sprintf('its gradient is %s, which is not finite', mat2str(g));
    g   = [NaN NaN];
end
end

function [mapSpec, mapArgs] = resolveMapSpec(options, cfg)
%resolveMapSpec The DMD-px -> sample-um map spec for tfp.patterns.dmdToSampleOffset.
%   Mirrors measureFocalPlaneTilt's resolveTiltMap_ so a caller can hand the
%   same options struct to both. A FITTED, um-valued affine supersedes the
%   design constants (handoff sec 9). mapSpec is the raw config rather than
%   the resolved model so that dmdToSampleOffset re-derives the constants
%   through tfp.util.opticalModel itself -- one source of truth, read once on
%   each side.
fitted = configField(options, 'dmdToSampleLinear', []);
if ~isempty(fitted)
    mapSpec = fitted;
else
    mapSpec = cfg;
end

mapArgs = {};
if isfield(options, 'mapUnits') && ~isempty(options.mapUnits)
    mapArgs(end+1:end+2) = {'mapUnits', options.mapUnits};
end
if isfield(options, 'cameraUmPerPixel') && ~isempty(options.cameraUmPerPixel)
    mapArgs(end+1:end+2) = {'cameraUmPerPixel', options.cameraUmPerPixel};
end
end

function r = rangeExcluding(z, idx)
%rangeExcluding Peak-to-peak of z with element idx removed.
keep = true(numel(z), 1);
keep(idx) = false;
r = max(z(keep)) - min(z(keep));
end

function pts = validateTargets(pts)
if ~isnumeric(pts) || isempty(pts) || ndims(pts) ~= 2 || size(pts, 2) ~= 2 %#ok<ISMAT>
    error('tfp:util:targetDepthOffset:badTargets', ...
        ['targetsPx must be a non-empty N x 2 numeric array of [col row] DMD ' ...
         'pixel coordinates; got %s of size %s.'], class(pts), mat2str(size(pts)));
end
if ~all(isfinite(pts(:)))
    error('tfp:util:targetDepthOffset:badTargets', ...
        ['targetsPx must be finite; %d entrie(s) are NaN or Inf. A NaN target ' ...
         'would poison the ensemble spread silently.'], nnz(~isfinite(pts(:))));
end
pts = double(pts);
end

function checkPositiveScalar(v, name)
if ~isnumeric(v) || ~isscalar(v) || ~isfinite(v) || v <= 0
    error('tfp:util:targetDepthOffset:badValue', ...
        '%s must be a positive finite scalar; got %s.', name, mat2str(v));
end
end

function value = configField(s, name, default)
%configField Repo-standard config/options read with a fallback.
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    value = s.(name);
else
    value = default;
end
end
