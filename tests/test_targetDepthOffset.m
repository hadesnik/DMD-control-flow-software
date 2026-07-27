classdef test_targetDepthOffset < matlab.unittest.TestCase
    %test_targetDepthOffset Per-target depth offset from the tilted plane (TASK-BU T-BU-3c).
    %
    %   docs/dmd_control_handoff.md §6: the excitation surface is a plane
    %   tilted 1.245° entirely along the DISPERSION axis,
    %
    %       z_um ~= x_disp * 0.02174
    %
    %   which walks 17.1 µm across the patch against a 17.7 µm axial FWHM
    %   (0.967 of it). Two targets at opposite field edges are therefore NOT
    %   in the same plane and no single objective Z brings both into focus.
    %
    %   The four things these tests exist to stop a future edit from breaking:
    %
    %   1. THE HANDOFF'S OWN NUMBERS. An edge target sits ~17.1/2 = 8.56 µm
    %      from the centre plane; a full-width pair spans ~17.1 µm = 0.97 of
    %      the axial FWHM. Pinned to the doc, not to the implementation.
    %
    %   2. THE MAP MUST BE ANISOTROPIC. The depth gradient lives on the
    %      dispersion diagonal of a 45°-clocked chip, so the conversion has to
    %      go through tfp.patterns.dmdToSampleOffset. T-BU-3b measured the
    %      scalar-µm/px shortcut at 12.2% wrong on this same quantity; a test
    %      below re-derives that gap so the shortcut cannot come back quietly.
    %
    %   3. MEASURED BEATS DESIGN, LOUDLY. A measured sampleTilt supersedes the
    %      design gradient (handoff §9), and an unusable one warns rather than
    %      silently degrading — the design tilt is groove-free and would erase
    %      a real groove component without a word.
    %
    %   4. THE SPREAD IS SIGN-INVARIANT. Both bench signs are unresolved
    %      (T-BU-M4), so the experimenter-facing verdict must not depend on
    %      them. Flipping either sign negates all z together and leaves the
    %      spread, the worst pair and the verdict unchanged.

    properties (Constant)
        % Handoff §6 / §5 headline numbers. Written here as literals ON
        % PURPOSE: these are the document's values, and the point of the
        % pinning tests is to catch the code drifting away from the document.
        DepthGradient   = 0.02174;   % µm depth per µm along dispersion
        TiltDeg         = 1.245;     % surface tilt
        WalkAcrossPatch = 17.1;      % µm, total across the patch
        AxialFwhmUm     = 17.7;      % µm [LOW ±40%]
        WalkPerDmdPx    = 0.03079;   % µm per px along the (1,1) diagonal
        PatchRadiusPx   = 278;
        UmPerPxDisp     = 1.4162;
        UmPerPxGroove   = 1.1250;
        PatchCentrePx   = [640 400]; % opticalModel default patchCenterPx
    end

    methods (Access = private)

        function pts = alongDispersion(tc, dDiagPx)
            % A target dDiagPx DMD pixels from the patch centre along the
            % (1,1) DISPERSION diagonal. Its DMD radius is |dDiagPx| and its
            % sample dispersion coordinate is dDiagPx * 1.4162 µm.
            step = dDiagPx / sqrt(2);
            pts  = [tc.PatchCentrePx(1) + step, tc.PatchCentrePx(2) + step];
        end

        function pts = alongGroove(tc, dDiagPx)
            % Same, along the (1,-1) GROOVE diagonal — the design tilt has no
            % component here, so depth must stay 0.
            step = dDiagPx / sqrt(2);
            pts  = [tc.PatchCentrePx(1) + step, tc.PatchCentrePx(2) - step];
        end

        function [pts, opts] = beyondOneFwhmCase(tc)
            % A full-width pair on a MEASURED tilt 1.5x the design gradient:
            % 25.7 um of spread against the 17.7 um FWHM, i.e. past the point
            % where any single objective Z can hold both. Both targets stay
            % inside the patch, so no other warning confounds the case.
            pts  = [tc.alongDispersion(-tc.PatchRadiusPx); ...
                    tc.alongDispersion(+tc.PatchRadiusPx)];
            opts = struct('sampleTilt', tc.measuredTilt(1.5 * tc.DepthGradient, 0));
        end

        function tilt = measuredTilt(~, gDisp, gGroove)
            % Minimal stand-in for measureFocalPlaneTilt's calib.sampleTilt.
            tilt = struct('valid', true, ...
                'gradientUmPerUm',           [gDisp gGroove], ...
                'gradientDispersionUmPerUm', gDisp, ...
                'gradientGrooveUmPerUm',     gGroove);
        end
    end

    methods (Test)

        % =================================================================
        % 1. The handoff's own numbers
        % =================================================================

        function edgeTargetSitsHalfTheWalkFromCentre(tc)
            % THE pinning test the task asks for. A target at the patch edge,
            % on the dispersion diagonal, is half the 17.1 µm walk away from
            % the plane's height at the patch centre.
            d = tfp.util.targetDepthOffset(tc.alongDispersion(tc.PatchRadiusPx));

            tc.verifyEqual(d.zUm, tc.WalkAcrossPatch / 2, 'RelTol', 0.01, ...
                'edge target should sit ~17.1/2 um from the centre plane');

            % And it is the doc's own arithmetic, not a coincidence: the edge
            % is 278 px * 1.4162 um/px along dispersion, times 0.02174.
            expected = tc.PatchRadiusPx * tc.UmPerPxDisp * tc.DepthGradient;
            tc.verifyEqual(d.zUm, expected, 'RelTol', 1e-6);

            % The lateral half of the answer is the anisotropic map's, and
            % the centre of the patch is z = 0 by construction.
            tc.verifyEqual(d.dispersionUm, tc.PatchRadiusPx * tc.UmPerPxDisp, ...
                'RelTol', 1e-9);
            tc.verifyEqual(d.grooveUm, 0, 'AbsTol', 1e-9);
        end

        function fullWidthPairSpansTheWholeWalk(tc)
            % Two targets at opposite field edges span the full 17.1 µm, i.e.
            % 0.97 of the 17.7 µm axial FWHM — the number that makes this
            % whole task family necessary.
            pts = [tc.alongDispersion(-tc.PatchRadiusPx); ...
                   tc.alongDispersion(+tc.PatchRadiusPx)];
            d = tc.verifyWarning(@() tfp.util.targetDepthOffset(pts), ...
                'tfp:util:targetDepthOffset:ensembleDepthSpread');

            tc.verifyEqual(d.spreadUm, tc.WalkAcrossPatch, 'RelTol', 0.01, ...
                'full-width pair should span ~17.1 um');
            tc.verifyEqual(d.spreadInAxialFwhm, ...
                tc.WalkAcrossPatch / tc.AxialFwhmUm, 'RelTol', 0.01, ...
                'spread should be ~0.97 of the 17.7 um axial FWHM');
            tc.verifyEqual(d.axialFwhmUm, tc.AxialFwhmUm, 'AbsTol', 1e-9);

            % 0.967 is BELOW one FWHM, so the design full-field case gets the
            % soft warning, not the categorical one — and at the compromise Z
            % each target sits 0.48 FWHM off focus, i.e. just inside the
            % half-maximum. That margin is why the hard tier is reserved for
            % spreads of a full FWHM or more, and it is thin: §6 quotes the
            % 17.7 um FWHM as [LOW +/-40%], so a 30% narrower focus tips this
            % same geometry over the line.
            tc.verifyTrue(d.exceedsThreshold);
            tc.verifyFalse(d.exceedsAxialFwhm);
            tc.verifyTrue(d.allInFocusAtCompromise);

            % The worst pair IS the pair, and their separation is the spread.
            tc.verifyEqual(sort(d.worstPairIdx), [1 2]);
            tc.verifyEqual(d.worstPairSeparationUm, d.spreadUm, 'AbsTol', 1e-12);
            tc.verifyEqual(d.worstPairTargetsPx, pts([2 1], :), 'AbsTol', 1e-9);
        end

        function perPixelGradientAlongTheDiagonalMatchesTheDoc(tc)
            % §6's other quoted figure: 0.03079 µm of depth per DMD pixel
            % stepped along the (1,1) diagonal.
            d = tfp.util.targetDepthOffset(tc.alongDispersion(1));
            tc.verifyEqual(d.zUm, tc.WalkPerDmdPx, 'RelTol', 0.001);
        end

        function tiltAngleMatchesTheDoc(tc)
            d = tfp.util.targetDepthOffset(tc.PatchCentrePx);
            tc.verifyEqual(d.tiltAngleDeg, tc.TiltDeg, 'AbsTol', 0.005);
            tc.verifyEqual(d.gradientUmPerUm, [tc.DepthGradient 0], 'AbsTol', 1e-12);
        end

        function grooveAxisHasNoDepthComponent(tc)
            % The grating disperses along ONE diagonal, so a target displaced
            % purely along the grooves stays in the same plane. If this ever
            % fails, the [disp groove] column order has been swapped.
            d = tfp.util.targetDepthOffset(tc.alongGroove(tc.PatchRadiusPx));
            tc.verifyEqual(d.zUm, 0, 'AbsTol', 1e-12);
            tc.verifyEqual(d.dispersionUm, 0, 'AbsTol', 1e-9);
            tc.verifyEqual(d.grooveUm, tc.PatchRadiusPx * tc.UmPerPxGroove, ...
                'RelTol', 1e-9);
        end

        % =================================================================
        % 2. The map must be anisotropic
        % =================================================================

        function scalarUmPerPixelCannotExpressTheDepth(tc)
            % T-BU-3b found the scalar shortcut 12.2% wrong for this exact
            % quantity. Re-derive that here so nobody "simplifies"
            % dmdToSampleOffset back into a single µm/px multiply: the
            % geometric-mean scale under-states the dispersion scale by
            % sqrt(anisotropy), and the depth is linear in it.
            edgePx = tc.PatchRadiusPx;
            d = tfp.util.targetDepthOffset(tc.alongDispersion(edgePx));

            model  = tfp.util.opticalModel();
            scalar = edgePx * model.umPerPixel * tc.DepthGradient;  % the WRONG way

            tc.verifyGreaterThan(abs(d.zUm - scalar) / d.zUm, 0.10, ...
                'the scalar shortcut must be visibly wrong, not a rounding difference');
            tc.verifyEqual(scalar / d.zUm, 1 / sqrt(model.anisotropy), ...
                'RelTol', 1e-9, ...
                'the scalar error is exactly sqrt(anisotropy) on the dispersion axis');
            % Same 12.2% relationship T-BU-3b reported (1.3973 vs 1.2454 deg).
            tc.verifyEqual(sqrt(model.anisotropy), 1.122, 'AbsTol', 0.002);
        end

        function anisotropyIsVisibleBetweenTheTwoDiagonals(tc)
            % Equal DMD-pixel steps on the two diagonals do NOT give equal
            % sample distances, which is the whole reason the map matters.
            dDisp = tfp.util.targetDepthOffset(tc.alongDispersion(100));
            tc.verifyEqual(dDisp.dispersionUm, 100 * tc.UmPerPxDisp, 'RelTol', 1e-9);

            dGroove = tfp.util.targetDepthOffset(tc.alongGroove(100));
            tc.verifyEqual(abs(dGroove.grooveUm), 100 * tc.UmPerPxGroove, ...
                'RelTol', 1e-9);
        end

        function fittedMapSupersedesDesignConstants(tc)
            % Handoff §9: a fitted, µm-valued DMD->sample affine always wins.
            % Halve the scale and every depth must halve with it.
            model = tfp.util.opticalModel();
            k = 1/sqrt(2);
            M = 0.5 * [model.umPerPixelDispersion * k,  model.umPerPixelDispersion * k; ...
                       model.umPerPixelGroove     * k, -model.umPerPixelGroove     * k];

            pts = tc.alongDispersion(tc.PatchRadiusPx);
            dRef = tfp.util.targetDepthOffset(pts);
            dFit = tfp.util.targetDepthOffset(pts, struct( ...
                'dmdToSampleLinear', M, 'mapUnits', 'um'));

            tc.verifyEqual(dFit.zUm, 0.5 * dRef.zUm, 'RelTol', 1e-9);
        end

        function cameraValuedMapIsRefusedByTheUnitsGuard(tc)
            % The T-BU-2e trap, reached through this function: a map tagged
            % camera_px must not silently mis-scale every depth.
            model = tfp.util.opticalModel();
            M = eye(2) * model.umPerPixelDispersion / 1.56;
            tc.verifyError(@() tfp.util.targetDepthOffset(tc.PatchCentrePx, ...
                struct('dmdToSampleLinear', M, 'mapUnits', 'camera_px')), ...
                'tfp:patterns:dmdToSampleOffset:wrongUnits');
        end

        % =================================================================
        % 3. Measured beats design, loudly
        % =================================================================

        function measuredTiltSupersedesDesign(tc)
            % Double the measured dispersion gradient -> double the depth,
            % and the provenance fields must say so.
            tilt = tc.measuredTilt(2 * tc.DepthGradient, 0);
            pts  = tc.alongDispersion(tc.PatchRadiusPx);

            dDesign   = tfp.util.targetDepthOffset(pts);
            dMeasured = tfp.util.targetDepthOffset(pts, struct('sampleTilt', tilt));

            tc.verifyEqual(dMeasured.zUm, 2 * dDesign.zUm, 'RelTol', 1e-9);
            tc.verifyEqual(dMeasured.source, 'measured');
            tc.verifyEqual(dDesign.source,   'design');
            tc.verifyTrue(dMeasured.signResolved);
            tc.verifyFalse(dDesign.signResolved);
        end

        function measuredGrooveComponentIsCarriedThrough(tc)
            % The design tilt is groove-free; a MEASURED one may not be, and
            % that component must reach the depth rather than be dropped.
            tilt = tc.measuredTilt(0, tc.DepthGradient);
            d = tfp.util.targetDepthOffset(tc.alongGroove(tc.PatchRadiusPx), ...
                struct('sampleTilt', tilt));

            tc.verifyEqual(d.zUm, ...
                tc.PatchRadiusPx * tc.UmPerPxGroove * tc.DepthGradient, ...
                'RelTol', 1e-9);
            tc.verifyEqual(d.gradientGrooveUmPerUm, tc.DepthGradient, 'AbsTol', 1e-12);
        end

        function wholeCalibStructIsAccepted(tc)
            % The convenience path: hand in measureFocalPlaneTilt's whole
            % calib struct rather than digging out .sampleTilt.
            calib = struct('sampleTilt', tc.measuredTilt(2 * tc.DepthGradient, 0), ...
                           'notes', 'anything else');
            pts = tc.alongDispersion(tc.PatchRadiusPx);
            dA = tfp.util.targetDepthOffset(pts, struct('calib', calib));
            dB = tfp.util.targetDepthOffset(pts, struct('sampleTilt', calib.sampleTilt));
            tc.verifyEqual(dA.zUm, dB.zUm, 'AbsTol', 1e-12);
            tc.verifyEqual(dA.source, 'measured');
        end

        function invalidMeasuredTiltWarnsAndFallsBack(tc)
            % Silent fallback would erase a real groove component without a
            % word, so this must be audible.
            bad = tc.measuredTilt(NaN, NaN);
            bad.valid = false;
            pts = tc.alongDispersion(tc.PatchRadiusPx);

            d = tc.verifyWarning(@() tfp.util.targetDepthOffset(pts, ...
                struct('sampleTilt', bad)), ...
                'tfp:util:targetDepthOffset:invalidMeasuredTilt');
            tc.verifyEqual(d.source, 'design');
            tc.verifyEqual(d.zUm, tc.WalkAcrossPatch / 2, 'RelTol', 0.01);

            % Same for a struct with no gradient fields at all.
            tc.verifyWarning(@() tfp.util.targetDepthOffset(pts, ...
                struct('sampleTilt', struct('valid', true))), ...
                'tfp:util:targetDepthOffset:invalidMeasuredTilt');
        end

        function conflictingTiltSourcesAreRejected(tc)
            tilt  = tc.measuredTilt(tc.DepthGradient, 0);
            calib = struct('sampleTilt', tilt);
            tc.verifyError(@() tfp.util.targetDepthOffset(tc.PatchCentrePx, ...
                struct('sampleTilt', tilt, 'calib', calib)), ...
                'tfp:util:targetDepthOffset:conflictingTilt');
        end

        % =================================================================
        % 4. The unresolved signs (T-BU-M4)
        % =================================================================

        function depthSignIsHonouredButTheSpreadIsInvariant(tc)
            % Both signs are unresolved bench conventions, so the
            % experimenter-facing verdict must not depend on them: flipping
            % either negates every z together and changes nothing else.
            pts = [tc.alongDispersion(-tc.PatchRadiusPx); ...
                   tc.alongDispersion(0); ...
                   tc.alongDispersion(+tc.PatchRadiusPx)];
            base = struct('warnOnSpread', false);

            dPlus  = tfp.util.targetDepthOffset(pts, base);
            dDepth = tfp.util.targetDepthOffset(pts, ...
                setfield(base, 'config', struct('dmd', struct('depthGradientSign', -1)))); %#ok<SFLD>
            dDisp  = tfp.util.targetDepthOffset(pts, ...
                setfield(base, 'config', struct('dmd', struct('dispersionAxisSign', -1)))); %#ok<SFLD>

            tc.verifyEqual(dDepth.zUm, -dPlus.zUm, 'AbsTol', 1e-12, ...
                'depthGradientSign must flip the depth');
            tc.verifyEqual(dDisp.zUm,  -dPlus.zUm, 'AbsTol', 1e-12, ...
                'dispersionAxisSign composes with it and flips the depth too');

            for d = [dDepth, dDisp]
                tc.verifyEqual(d.spreadUm, dPlus.spreadUm, 'AbsTol', 1e-12);
                tc.verifyEqual(d.exceedsAxialFwhm, dPlus.exceedsAxialFwhm);
                tc.verifyEqual(sort(d.worstPairIdx), sort(dPlus.worstPairIdx));
            end

            % Both signs flipped is the identity: only their product shows.
            dBoth = tfp.util.targetDepthOffset(pts, setfield(base, 'config', ...
                struct('dmd', struct('depthGradientSign', -1, ...
                                     'dispersionAxisSign', -1)))); %#ok<SFLD>
            tc.verifyEqual(dBoth.zUm, dPlus.zUm, 'AbsTol', 1e-12);
        end

        % =================================================================
        % 5. The ensemble report — the point of the task
        % =================================================================

        function tightEnsembleIsSilent(tc)
            % A compact ensemble must not cry wolf: 60 px along the diagonal
            % is ~1.8 µm of depth, ~0.1 FWHM.
            pts = [tc.alongDispersion(-30); tc.alongDispersion(30); ...
                   tc.alongGroove(30)];
            d = tfp.util.targetDepthOffset(pts);   % verifyWarningFree below

            tc.verifyWarningFree(@() tfp.util.targetDepthOffset(pts));
            tc.verifyLessThan(d.spreadInAxialFwhm, 0.5);
            tc.verifyFalse(d.exceedsThreshold);
            tc.verifyFalse(d.exceedsAxialFwhm);
            tc.verifyTrue(d.allInFocusAtCompromise);
            tc.verifyTrue(contains(d.report, 'single objective Z holds every target'));
        end

        function halfFwhmSpreadWarnsWithTheSoftIdentifier(tc)
            % Between half an FWHM and a full one: the soft warning fires and
            % the hard one does not.
            model = tfp.util.opticalModel();
            % Diagonal offset that produces exactly 0.6 of an axial FWHM.
            % Split about the patch centre so both targets stay INSIDE the
            % patch and the :outsidePatch warning does not confound the test.
            dz  = 0.6 * model.axialFwhmUm;
            px  = dz / (model.umPerPixelDispersion * model.depthGradientUmPerUm);
            pts = [tc.alongDispersion(-px/2); tc.alongDispersion(px/2)];

            d = tc.verifyWarning(@() tfp.util.targetDepthOffset(pts), ...
                'tfp:util:targetDepthOffset:ensembleDepthSpread');
            tc.verifyEqual(d.spreadInAxialFwhm, 0.6, 'RelTol', 1e-9);
            tc.verifyTrue(d.exceedsThreshold);
            tc.verifyFalse(d.exceedsAxialFwhm);

            % The hard identifier must NOT also fire — the two tiers are
            % exclusive, the harder statement superseding the softer one.
            tc.verifyWarningFree(@() warnOnly(pts, struct(), ...
                'tfp:util:targetDepthOffset:ensembleDepthSpread'));
        end

        function hardTierSupersedesSoftTier(tc)
            % At or above a FULL axial FWHM only the categorical warning
            % fires. A measured tilt 1.5x the design one over the same
            % full-width pair gets there (25.7 um vs 17.7 um) while keeping
            % both targets inside the patch.
            [pts, opts] = tc.beyondOneFwhmCase();
            d = tc.verifyWarning(@() tfp.util.targetDepthOffset(pts, opts), ...
                'tfp:util:targetDepthOffset:exceedsAxialFwhm');
            tc.verifyGreaterThan(d.spreadInAxialFwhm, 1);
            tc.verifyFalse(d.allInFocusAtCompromise, ...
                'beyond one FWHM no single objective Z holds both targets');

            % Only ONE of the two tiers ever fires: with the hard identifier
            % muted nothing else is left to warn about.
            tc.verifyWarningFree(@() warnOnly(pts, opts, ...
                'tfp:util:targetDepthOffset:exceedsAxialFwhm'));
        end

        function warningSaysWhyItMattersInWords(tc)
            % Requirement of the task: the warning must explain the SCIENCE
            % consequence, not just quote numbers. Assert on the words, in
            % both tiers.
            [hardPts, hardOpts] = tc.beyondOneFwhmCase();
            [~, hard] = captureWarning(@() tfp.util.targetDepthOffset(hardPts, hardOpts));

            tc.verifyTrue(contains(hard, 'CANNOT'), 'states the categorical fact');
            tc.verifyTrue(contains(lower(hard), 'spurious'), ...
                'names the artefact as spurious');
            tc.verifyTrue(contains(lower(hard), 'biological'), ...
                'says it can be mistaken for biology');
            tc.verifyTrue(contains(lower(hard), 'drop target'), ...
                'says what to do about it');
            tc.verifyTrue(contains(hard, 'T-BU-M4'), 'flags the unresolved sign');

            % The soft tier is the one the design full-field case actually
            % hits, so it has to carry the same explanation.
            softPts = [tc.alongDispersion(-tc.PatchRadiusPx); ...
                       tc.alongDispersion(+tc.PatchRadiusPx)];
            [~, soft] = captureWarning(@() tfp.util.targetDepthOffset(softPts));
            tc.verifyTrue(contains(lower(soft), 'not in the same plane'));
            tc.verifyTrue(contains(lower(soft), 'biological'));
            tc.verifyTrue(contains(lower(soft), 'drop target'));
            tc.verifyTrue(contains(soft, 'T-BU-M4'));
        end

        function worstPairAndCompromiseZAreActionable(tc)
            % Name the offending pair, and the single Z that best splits the
            % difference (mid-range, the minimax choice — not the mean).
            pts = [tc.alongDispersion(0); ...
                   tc.alongDispersion(50); ...
                   tc.alongDispersion(60); ...
                   tc.alongDispersion(-tc.PatchRadiusPx); ...
                   tc.alongDispersion(+tc.PatchRadiusPx)];
            d = tfp.util.targetDepthOffset(pts, struct('warnOnSpread', false));

            tc.verifyEqual(d.worstPairIdx, [5 4], 'the extremes, deepest first');
            tc.verifyEqual(d.worstPairSeparationUm, d.zMaxUm - d.zMinUm, ...
                'AbsTol', 1e-12);
            tc.verifyEqual(d.worstPairTargetsPx, pts([5 4], :), 'AbsTol', 1e-9);

            % Mid-range minimises the WORST defocus; it differs from the mean
            % here because the ensemble is lopsided.
            tc.verifyEqual(d.suggestedObjectiveZUm, ...
                0.5 * (d.zMaxUm + d.zMinUm), 'AbsTol', 1e-12);
            tc.verifyNotEqual(d.suggestedObjectiveZUm, d.zMeanUm);
            tc.verifyEqual(max(abs(d.defocusAtCompromiseUm)), ...
                0.5 * d.spreadUm, 'RelTol', 1e-9);
            tc.verifyEqual(d.worstDefocusAtCompromiseUm, 0.5 * d.spreadUm, ...
                'AbsTol', 1e-12);

            % Dropping either extreme is the other actionable answer.
            tc.verifyLessThan(d.spreadAfterDroppingDeepestUm,   d.spreadUm);
            tc.verifyLessThan(d.spreadAfterDroppingShallowestUm, d.spreadUm);

            % maxSpanUm is the targeting budget: one axial FWHM of depth.
            tc.verifyEqual(d.maxSpanUm, tc.AxialFwhmUm / tc.DepthGradient, ...
                'RelTol', 1e-6);
        end

        function thresholdFractionIsConfigurable(tc)
            % Default is half an axial FWHM; a caller may tighten or relax it.
            pts = [tc.alongDispersion(0); tc.alongDispersion(100)];
            dQuiet = tfp.util.targetDepthOffset(pts);          % ~0.25 FWHM
            tc.verifyFalse(dQuiet.exceedsThreshold);
            tc.verifyEqual(dQuiet.spreadFwhmFraction, 0.5);

            d = tc.verifyWarning(@() tfp.util.targetDepthOffset(pts, ...
                struct('spreadFwhmFraction', 0.1)), ...
                'tfp:util:targetDepthOffset:ensembleDepthSpread');
            tc.verifyTrue(d.exceedsThreshold);

            % measureFocalPlaneTilt's name for the same knob is accepted, so
            % one tolerance struct can drive both.
            tc.verifyWarning(@() tfp.util.targetDepthOffset(pts, ...
                struct('walkFwhmFraction', 0.1)), ...
                'tfp:util:targetDepthOffset:ensembleDepthSpread');
        end

        function warnOnSpreadSuppressesOnlyTheWarning(tc)
            pts = [tc.alongDispersion(-tc.PatchRadiusPx); ...
                   tc.alongDispersion(+tc.PatchRadiusPx)];
            d = tc.verifyWarningFree(@() tfp.util.targetDepthOffset(pts, ...
                struct('warnOnSpread', false)));
            tc.verifyTrue(d.exceedsThreshold, ...
                'the verdict fields must be unaffected by the mute switch');
        end

        function singleTargetHasNoSpread(tc)
            d = tc.verifyWarningFree(@() tfp.util.targetDepthOffset( ...
                tc.alongDispersion(tc.PatchRadiusPx)));
            tc.verifyEqual(d.spreadUm, 0, 'AbsTol', 1e-12);
            tc.verifyFalse(d.exceedsThreshold);
            tc.verifyEqual(d.nTargets, 1);
            tc.verifyTrue(isnan(d.spreadAfterDroppingDeepestUm));
            tc.verifyTrue(contains(d.report, 'Single target'));
        end

        % =================================================================
        % 6. Constants, config plumbing and input validation
        % =================================================================

        function constantsComeFromOpticalModelNotLiterals(tc)
            % T-BU-0: 0.02174, 1.245 and 17.7 live in ONE place. Change them
            % in the config and every number here must move with them.
            cfg = struct('dmd', struct('depthGradientUmPerUm', 0.05, ...
                                       'focalPlaneTiltDeg',    atand(0.05), ...
                                       'axialFwhmUm',          40));
            pts = tc.alongDispersion(tc.PatchRadiusPx);
            d = tfp.util.targetDepthOffset(pts, struct('config', cfg));

            tc.verifyEqual(d.gradientDispersionUmPerUm, 0.05, 'AbsTol', 1e-12);
            tc.verifyEqual(d.axialFwhmUm, 40, 'AbsTol', 1e-12);
            tc.verifyEqual(d.zUm, tc.PatchRadiusPx * tc.UmPerPxDisp * 0.05, ...
                'RelTol', 1e-9);
            tc.verifyEqual(d.tiltAngleDeg, atand(0.05), 'AbsTol', 1e-9);
        end

        function referencePointIsThePatchCentreByDefault(tc)
            % Depth is measured from the ILLUMINATION centre (T-BU-M3), not
            % the chip centre, and the reference is overridable.
            model = tfp.util.opticalModel();
            d = tfp.util.targetDepthOffset(model.patchCenterPx);
            tc.verifyEqual(d.zUm, 0, 'AbsTol', 1e-12);
            tc.verifyEqual(d.referencePx, model.patchCenterPx, 'AbsTol', 1e-12);

            pts = tc.alongDispersion(tc.PatchRadiusPx);
            dShift = tfp.util.targetDepthOffset(pts, ...
                struct('referencePx', pts));
            tc.verifyEqual(dShift.zUm, 0, 'AbsTol', 1e-12);
        end

        function axialFwhmOverrideIsHonoured(tc)
            pts = [tc.alongDispersion(-tc.PatchRadiusPx); ...
                   tc.alongDispersion(+tc.PatchRadiusPx)];
            d = tfp.util.targetDepthOffset(pts, ...
                struct('axialFwhmUm', 100, 'warnOnSpread', false));
            tc.verifyEqual(d.axialFwhmUm, 100, 'AbsTol', 1e-12);
            tc.verifyEqual(d.spreadInAxialFwhm, d.spreadUm / 100, 'RelTol', 1e-12);
            tc.verifyFalse(d.exceedsAxialFwhm, ...
                'a wider FWHM makes the same spread benign');
        end

        function targetOutsideThePatchIsFlagged(tc)
            % The plane is only described inside the patch; beyond it the
            % depth extrapolates. Containment itself is enforced elsewhere.
            d = tc.verifyWarning(@() tfp.util.targetDepthOffset( ...
                tc.alongDispersion(tc.PatchRadiusPx + 100)), ...
                'tfp:util:targetDepthOffset:outsidePatch');
            tc.verifyTrue(d.outsidePatch);
            tc.verifyEqual(d.radiusPx, tc.PatchRadiusPx + 100, 'RelTol', 1e-9);
        end

        function outputShapeIsPerTargetColumns(tc)
            pts = [tc.alongDispersion(-10); tc.alongDispersion(10); ...
                   tc.alongGroove(20)];
            d = tfp.util.targetDepthOffset(pts);
            tc.verifySize(d.zUm, [3 1]);
            tc.verifySize(d.sampleOffsetUm, [3 2]);
            tc.verifySize(d.dmdOffsetPx, [3 2]);
            tc.verifySize(d.radiusPx, [3 1]);
            tc.verifySize(d.defocusAtCompromiseUm, [3 1]);
            tc.verifySize(d.inFocusAtCompromise, [3 1]);
            tc.verifyEqual(d.zRelativeToMeanUm, d.zUm - mean(d.zUm), 'AbsTol', 1e-12);
            tc.verifyClass(d.report, 'char');
            tc.verifyClass(d.description, 'char');
        end

        function badInputsAreTyped(tc)
            tc.verifyError(@() tfp.util.targetDepthOffset([]), ...
                'tfp:util:targetDepthOffset:badTargets');
            tc.verifyError(@() tfp.util.targetDepthOffset([1 2 3]), ...
                'tfp:util:targetDepthOffset:badTargets');
            tc.verifyError(@() tfp.util.targetDepthOffset([640 NaN]), ...
                'tfp:util:targetDepthOffset:badTargets');
            tc.verifyError(@() tfp.util.targetDepthOffset(tc.PatchCentrePx, 7), ...
                'tfp:util:targetDepthOffset:badOptions');
            tc.verifyError(@() tfp.util.targetDepthOffset(tc.PatchCentrePx, ...
                struct('config', 'nope')), ...
                'tfp:util:targetDepthOffset:badConfig');
            tc.verifyError(@() tfp.util.targetDepthOffset(tc.PatchCentrePx, ...
                struct('referencePx', [1 2 3])), ...
                'tfp:util:targetDepthOffset:badReference');
            tc.verifyError(@() tfp.util.targetDepthOffset(tc.PatchCentrePx, ...
                struct('axialFwhmUm', -1)), ...
                'tfp:util:targetDepthOffset:badValue');
            tc.verifyError(@() tfp.util.targetDepthOffset(tc.PatchCentrePx, ...
                struct('spreadFwhmFraction', 0)), ...
                'tfp:util:targetDepthOffset:badValue');
            tc.verifyError(@() tfp.util.targetDepthOffset(tc.PatchCentrePx, ...
                struct('calib', 42)), ...
                'tfp:util:targetDepthOffset:badCalib');
        end

    end
end

% =========================================================================
% Local helpers
% =========================================================================

function warnOnly(pts, opts, allowedId)
%warnOnly Run the helper with `allowedId` disabled, so any OTHER warning shows.
%   Lets a test assert that exactly one of the two spread tiers fires.
st = warning('off', allowedId);
c  = onCleanup(@() warning(st)); %#ok<NASGU>
tfp.util.targetDepthOffset(pts, opts);
end

function [id, msg] = captureWarning(fn)
%captureWarning Run fn, return the identifier and text of the warning it emitted.
%   Repo idiom (see tests/test_sampleDmdMapping.m): evalc keeps the
%   deliberately long warning out of the test log, lastwarn hands back the
%   text so the wording itself can be asserted on.
lastwarn('', '');
captured = evalc('fn();'); %#ok<NASGU>
[msg, id] = lastwarn();
end
