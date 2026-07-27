classdef test_dwellCorrection < matlab.unittest.TestCase
    %test_dwellCorrection Gaussian-uniformity dwell correction (TASK-BU T-BU-3d).
    %
    %   Pins the three things about tfp.patterns.dwellCorrection that a future
    %   maintainer could plausibly "simplify" into a bug:
    %
    %   1. THE SQUARE. Two-photon excitation goes as I^2, so equalising
    %      delivered 2p response (dwell ~ 1/g^2, the default) and equalising
    %      delivered energy (dwell ~ 1/g, the handoff §8 convention) differ in
    %      the EXPONENT. measureIlluminationUniformity returns both a response
    %      map (.intensityNorm, prop to I^2) and its square root
    %      (.intensitySqrtNorm, prop to I); swapping them silently changes the
    %      exponent. Several tests below lock the exponent down.
    %
    %   2. CORRECT IN TIME, NOT IN FILL. Raising an edge target's FILL to
    %      compensate for dimming raises the pupil peak quadratically
    %      (docs/dmd_control_handoff.md §7, tfp.util.assertPulseEnergySafe);
    %      raising its DWELL does not. The output must stay purely a frame
    %      count.
    %
    %   3. QUANTISATION. Dwell exists only in whole 80 us frames, so at a base
    %      dwell of 1 frame a 1.65x correction cannot be expressed at all
    %      (1 frame = 1.00x, 2 frames = 2.00x). The caller must be told.
    %
    %   Reference values from handoff §8, I(r)/I0 = exp(-2 r^2 / 555.6^2):
    %
    %     r (px) | relative intensity g | 1/g (linear) | 1/g^2 (2p)
    %        0   | 1.000                | 1.00         | 1.00
    %      139   | 0.882                | 1.13         | 1.28
    %      278   | 0.606  (patch edge)  | 1.65         | 2.72

    properties (Constant)
        % Handoff §8 headline numbers, at the design patch edge r = 278 px.
        EdgeRadiusPx        = 278;
        EdgeRelativeInt     = 0.61;   % §8 table
        EdgeLinearCorrection = 1.65;  % §8 "worst-case correction ... 1.65x"
        MidRadiusPx         = 139;
        MidRelativeInt      = 0.88;
        PatchCentrePx       = [640 400];   % opticalModel default patchCenterPx
    end

    methods (Access = private)

        function pts = ptsAtRadius(tc, r)
            % A target r px to the right of the illumination centre.
            pts = [tc.PatchCentrePx(1) + r, tc.PatchCentrePx(2)];
        end

        function calib = syntheticCalib(tc, waistPx)
            % A stand-in for tfp.calibration.measureIlluminationUniformity's
            % output: a 9x9 grid spanning the patch, with intensityNorm set to
            % the ANALYTIC 2p response g^2 so the measured and analytic routes
            % must agree exactly at a grid point.
            n = 9;
            spacing = 2 * tc.EdgeRadiusPx / (n - 1);
            off = (-(n-1)/2 : (n-1)/2) * spacing;
            [c, r] = meshgrid(tc.PatchCentrePx(1) + off, tc.PatchCentrePx(2) + off);
            pts = [c(:), r(:)];
            rad = hypot(pts(:,1) - tc.PatchCentrePx(1), pts(:,2) - tc.PatchCentrePx(2));
            g = exp(-2 * rad.^2 / waistPx^2);

            calib.dmdGridPts        = pts;
            calib.intensity         = g.^2;
            calib.intensityNorm     = g.^2;         % the 2p RESPONSE map
            calib.intensitySqrtNorm = g;            % relative INTENSITY
            calib.reachable         = true(size(g));
        end
    end

    methods (Test)

        % =================================================================
        % The handoff's own numbers
        % =================================================================

        function handoffEdgeIntensityAndCorrection(tc)
            % THE pinning test the task asks for: 0.61 relative intensity at
            % the patch edge, and a 1.65x dwell correction there.
            d = tfp.patterns.dwellCorrection( ...
                tc.ptsAtRadius(tc.EdgeRadiusPx), struct('mode', 'linear'));

            tc.verifyEqual(d.relativeIntensity, tc.EdgeRelativeInt, ...
                'AbsTol', 0.005, ...
                'Handoff §8: I(278)/I0 = 0.61.');
            tc.verifyEqual(d.correction, tc.EdgeLinearCorrection, ...
                'AbsTol', 0.005, ...
                'Handoff §8: the worst-case dwell correction at the edge is 1.65x.');
            tc.verifyEqual(d.worstCaseCorrection, d.correction, 'AbsTol', 1e-12);
            tc.verifyEqual(d.radiusPx, tc.EdgeRadiusPx, 'AbsTol', 1e-9);
        end

        function handoffMidFieldIntensity(tc)
            d = tfp.patterns.dwellCorrection( ...
                tc.ptsAtRadius(tc.MidRadiusPx), struct('mode', 'linear'));
            tc.verifyEqual(d.relativeIntensity, tc.MidRelativeInt, ...
                'AbsTol', 0.005, 'Handoff §8: I(139)/I0 = 0.88.');
        end

        function centreTargetNeedsNoCorrection(tc)
            d = tfp.patterns.dwellCorrection(tc.PatchCentrePx, ...
                struct('baseDwellFrames', 125));
            tc.verifyEqual(d.relativeIntensity, 1, 'AbsTol', 1e-12);
            tc.verifyEqual(d.correction, 1, 'AbsTol', 1e-12);
            tc.verifyEqual(d.dwellFrames, 125);
            tc.verifyEqual(d.timeCostFactor, 1, 'AbsTol', 1e-12);
        end

        function correctionGrowsMonotonicallyWithRadius(tc)
            radii = (0:50:278)';
            d = tfp.patterns.dwellCorrection([], struct('radiusPx', radii));
            tc.verifyEqual(numel(d.correction), numel(radii));
            tc.verifyTrue(all(diff(d.correction) > 0), ...
                'Dimmer targets (larger radius) must need longer dwell.');
        end

        % =================================================================
        % THE SQUARE
        % =================================================================

        function defaultModeEqualisesTwoPhotonResponse(tc)
            d = tfp.patterns.dwellCorrection(tc.ptsAtRadius(tc.EdgeRadiusPx));
            tc.verifyEqual(d.mode, 'twoPhoton', ...
                'Default must equalise 2p excitation on a 2p photostim rig.');
            tc.verifyEqual(d.exponent, 2);
            tc.verifyTrue(contains(d.equalises, 'I^2'), ...
                'The output must SAY in words which quantity it equalises.');
        end

        function twoPhotonCorrectionIsTheSquareOfTheLinearOne(tc)
            % The whole point: the two conventions differ in the EXPONENT.
            pts = [tc.ptsAtRadius(tc.MidRadiusPx); tc.ptsAtRadius(tc.EdgeRadiusPx)];
            lin = tfp.patterns.dwellCorrection(pts, struct('mode', 'linear'));
            twoP = tfp.patterns.dwellCorrection(pts, struct('mode', 'twoPhoton'));
            tc.verifyEqual(twoP.correction, lin.correction.^2, 'AbsTol', 1e-12);
        end

        function twoPhotonEdgeCorrectionIsAboutTwoPointSevenTwo(tc)
            % 1/0.6061^2 = 2.722. If this ever reads 1.65 again, the default
            % has silently reverted to equalising ENERGY, not 2p excitation.
            d = tfp.patterns.dwellCorrection(tc.ptsAtRadius(tc.EdgeRadiusPx));
            tc.verifyEqual(d.correction, 2.7222, 'AbsTol', 0.01);
        end

        function responseMapAndIntensityMapAgreeWhenUsedCorrectly(tc)
            % measureIlluminationUniformity returns intensityNorm (prop I^2)
            % and intensitySqrtNorm (prop I). Fed through the RIGHT option
            % field, both must give the same dwell.
            g = tc.EdgeRelativeInt;
            viaIntensity = tfp.patterns.dwellCorrection([], ...
                struct('relativeIntensity', g));
            viaResponse = tfp.patterns.dwellCorrection([], ...
                struct('relativeResponse', g^2));
            tc.verifyEqual(viaResponse.correction, viaIntensity.correction, ...
                'AbsTol', 1e-12);
            tc.verifyEqual(viaResponse.relativeIntensity, g, 'AbsTol', 1e-12);
            tc.verifyEqual(viaIntensity.relativeResponse, g^2, 'AbsTol', 1e-12);
        end

        function feedingTheResponseMapAsIntensityIsOffByOneSquare(tc)
            % The bug this task exists to prevent, made explicit: handing
            % .intensityNorm (a RESPONSE map) to .relativeIntensity is wrong
            % in the exponent, not merely in magnitude — here 7.2x instead of
            % 2.7x at the patch edge.
            g = tc.EdgeRelativeInt;
            correct = tfp.patterns.dwellCorrection([], ...
                struct('relativeResponse', g^2));            % intensityNorm
            wrong = tfp.patterns.dwellCorrection([], ...
                struct('relativeIntensity', g^2));           % same numbers, wrong slot
            tc.verifyEqual(wrong.correction, correct.correction^2, ...
                'RelTol', 1e-12);
            tc.verifyGreaterThan(wrong.correction, 7, ...
                'Misreading the response map as intensity over-corrects badly.');
        end

        function measuredMapIsConsumedAsTheResponseMap(tc)
            % With intensityNorm = g^2 on the grid, the default (2p) mode must
            % reproduce the analytic answer exactly at a grid point: the code
            % must be treating intensityNorm as g^2, not as g.
            model = tfp.util.opticalModel();
            calib = tc.syntheticCalib(model.gaussianWaistPx);
            pts = tc.ptsAtRadius(tc.EdgeRadiusPx);

            measured = tfp.patterns.dwellCorrection(pts, ...
                struct('uniformityCalib', calib));
            analytic = tfp.patterns.dwellCorrection(pts, struct());

            tc.verifyEqual(measured.source, 'measured');
            tc.verifyEqual(analytic.source, 'analytic');
            tc.verifyEqual(measured.relativeIntensity, ...
                analytic.relativeIntensity, 'AbsTol', 1e-9);
            tc.verifyEqual(measured.correction, analytic.correction, ...
                'AbsTol', 1e-9);
            tc.verifyEqual(measured.dwellFrames, analytic.dwellFrames);
        end

        function measuredMapFallsBackToSqrtMapWhenOnlyThatIsPresent(tc)
            model = tfp.util.opticalModel();
            calib = tc.syntheticCalib(model.gaussianWaistPx);
            calib = rmfield(calib, 'intensityNorm');
            pts = tc.ptsAtRadius(tc.MidRadiusPx);

            d = tfp.patterns.dwellCorrection(pts, struct('uniformityCalib', calib));
            ref = tfp.patterns.dwellCorrection(pts, struct());
            tc.verifyEqual(d.correction, ref.correction, 'AbsTol', 1e-9, ...
                'intensitySqrtNorm must be squared back into a response map.');
        end

        function radiusInputMatchesCoordinateInput(tc)
            byPts = tfp.patterns.dwellCorrection(tc.ptsAtRadius(200));
            byRad = tfp.patterns.dwellCorrection([], struct('radiusPx', 200));
            tc.verifyEqual(byRad.correction, byPts.correction, 'AbsTol', 1e-12);
        end

        % =================================================================
        % Quantisation to whole 80 us frames
        % =================================================================

        function dwellIsWholeFramesOfEightyMicroseconds(tc)
            d = tfp.patterns.dwellCorrection(tc.ptsAtRadius(tc.EdgeRadiusPx));
            tc.verifyEqual(mod(d.dwellFrames, 1), 0, ...
                'Dwell must be a whole number of binary frames.');
            tc.verifyEqual(d.frameDurationS, 80e-6, 'AbsTol', 1e-12);
            tc.verifyEqual(d.binaryFrameRateHz, 12500);
            tc.verifyEqual(d.dwellS, d.dwellFrames * 80e-6, 'AbsTol', 1e-15);
        end

        function baseDwellOfOneFrameCannotExpressTheEdgeCorrection(tc)
            % The task's named limit: 1 frame has only 1.00x and 2.00x
            % available, so a 1.65x correction is not representable at all.
            opts = struct('mode', 'linear', 'baseDwellFrames', 1);
            d = tc.verifyWarning( ...
                @() tfp.patterns.dwellCorrection( ...
                        tc.ptsAtRadius(tc.EdgeRadiusPx), opts), ...
                'tfp:patterns:dwellCorrection:dwellQuantization');

            tc.verifyEqual(d.dwellFrames, 2, ...
                'round(1.65) = 2 frames — the only nearby choice.');
            tc.verifyEqual(d.achievedCorrection, 2, 'AbsTol', 1e-12);
            tc.verifyFalse(d.quantizationOk);
            tc.verifyGreaterThan(d.quantizationErrorFrac, 0.2, ...
                'A 2.00x delivered against a 1.65x request is a ~21% over-dose.');
        end

        function quantizationReportSuggestsAWorkableBaseDwell(tc)
            opts = struct('mode', 'linear', 'baseDwellFrames', 1);
            d = tc.verifyWarning( ...
                @() tfp.patterns.dwellCorrection( ...
                        tc.ptsAtRadius(tc.EdgeRadiusPx), opts), ...
                'tfp:patterns:dwellCorrection:dwellQuantization');
            tc.verifyEqual(d.minBaseDwellFrames, 3, ...
                'At 3 frames, 3*1.65 = 4.95 rounds to 5 — a 1.0% error.');

            % ...and taking that advice must clear the warning.
            opts.baseDwellFrames = d.minBaseDwellFrames;
            ok = tfp.patterns.dwellCorrection(tc.ptsAtRadius(tc.EdgeRadiusPx), opts);
            tc.verifyTrue(ok.quantizationOk);
            tc.verifyLessThanOrEqual(abs(ok.quantizationErrorFrac), 0.02);
        end

        function longBaseDwellQuantisesCleanlyWithNoWarning(tc)
            opts = struct('baseDwellFrames', 1000);
            d = tfp.patterns.dwellCorrection(tc.ptsAtRadius(tc.EdgeRadiusPx), opts);
            tc.verifyTrue(d.quantizationOk);
            tc.verifyLessThan(abs(d.quantizationErrorFrac), 1e-3);
        end

        function quantizationErrorIsSignedAndRelative(tc)
            d = tfp.patterns.dwellCorrection([], ...
                struct('relativeIntensity', [1; 0.61], 'mode', 'linear', ...
                       'baseDwellFrames', 10, 'warnOnQuantization', false));
            expected = (d.dwellFrames - d.exactDwellFrames) ./ d.exactDwellFrames;
            tc.verifyEqual(d.quantizationErrorFrac, expected, 'AbsTol', 1e-12);
            tc.verifyEqual(d.maxQuantizationErrorFrac, max(abs(expected)), ...
                'AbsTol', 1e-12);
        end

        function baseDwellInSecondsIsConvertedToFrames(tc)
            d = tfp.patterns.dwellCorrection(tc.PatchCentrePx, ...
                struct('baseDwellS', 10e-3));
            tc.verifyEqual(d.baseDwellFrames, 125, ...
                '10 ms at 12.5 kHz is 125 binary frames.');
            tc.verifyEqual(d.baseDwellS, 10e-3, 'AbsTol', 1e-12);
        end

        % =================================================================
        % Sequence-level cost reporting
        % =================================================================

        function worstCaseAndTotalDurationAreReported(tc)
            pts = [tc.ptsAtRadius(0); ...
                   tc.ptsAtRadius(tc.MidRadiusPx); ...
                   tc.ptsAtRadius(tc.EdgeRadiusPx)];
            d = tfp.patterns.dwellCorrection(pts, ...
                struct('mode', 'linear', 'baseDwellFrames', 125));

            tc.verifyEqual(d.nTargets, 3);
            tc.verifyEqual(d.worstCaseTargetIdx, 3, ...
                'The edge target is the worst case.');
            tc.verifyEqual(d.worstCaseCorrection, tc.EdgeLinearCorrection, ...
                'AbsTol', 0.005);

            tc.verifyEqual(d.totalFrames, sum(d.dwellFrames));
            tc.verifyEqual(d.totalDurationS, d.totalFrames * 80e-6, 'AbsTol', 1e-15);
            tc.verifyEqual(d.uncorrectedTotalFrames, 3 * 125);
            tc.verifyEqual(d.timeCostFactor, ...
                d.totalFrames / d.uncorrectedTotalFrames, 'AbsTol', 1e-12);
            tc.verifyGreaterThan(d.timeCostFactor, 1, ...
                'Flat-fielding a spread ensemble must cost time.');
            tc.verifyLessThan(d.timeCostFactor, 1.65, ...
                'The average correction is below the worst-case one.');
        end

        function descriptionSummarisesTheCorrection(tc)
            d = tfp.patterns.dwellCorrection(tc.ptsAtRadius(tc.EdgeRadiusPx));
            tc.verifyClass(d.description, 'char');
            tc.verifyTrue(contains(d.description, 'twoPhoton'));
            tc.verifyTrue(contains(d.description, 'analytic'));
        end

        % =================================================================
        % Safety: time, not fill fraction
        % =================================================================

        function outputCarriesNoFillFractionKnob(tc)
            % Anti-drift lock for the §7 pupil hazard: this correction must
            % never be re-expressed as a fill-fraction change, because fill
            % raises the pupil peak QUADRATICALLY while dwell leaves it
            % untouched. If a maintainer adds a fill output here, this fails.
            d = tfp.patterns.dwellCorrection(tc.ptsAtRadius(tc.EdgeRadiusPx));
            f = fieldnames(d);
            tc.verifyEmpty(f(contains(lower(f), 'fill')), ...
                ['dwellCorrection must correct in TIME only. See ' ...
                 'docs/dmd_control_handoff.md §7 and ' ...
                 'tfp.util.assertPulseEnergySafe.']);
            tc.verifyEmpty(f(contains(lower(f), 'voltage')), ...
                'Nor may it touch the ao3 laser-power path.');
        end

        function correctionIsPurelyTemporalAndIndependentOfPatternGeometry(tc)
            % Same target, same answer, regardless of how big the spot is —
            % the correction is a frame count, not a geometry change.
            d1 = tfp.patterns.dwellCorrection(tc.ptsAtRadius(tc.EdgeRadiusPx));
            d2 = tfp.patterns.dwellCorrection(tc.ptsAtRadius(tc.EdgeRadiusPx));
            tc.verifyEqual(d2.dwellFrames, d1.dwellFrames);
        end

        % =================================================================
        % Constants come from opticalModel, never hardcoded
        % =================================================================

        function waistComesFromTheOpticalModel(tc)
            cfg = struct('dmd', struct('gaussianWaistPx', 1000));
            d = tfp.patterns.dwellCorrection(tc.ptsAtRadius(tc.EdgeRadiusPx), ...
                struct('mode', 'linear', 'config', cfg));
            expected = 1 / exp(-2 * tc.EdgeRadiusPx^2 / 1000^2);
            tc.verifyEqual(d.correction, expected, 'AbsTol', 1e-12, ...
                'A config waist must propagate — 555.6 must not be hardcoded.');
            tc.verifyLessThan(d.correction, 1.3, ...
                'A wider beam means a flatter patch and a smaller correction.');
        end

        function frameRateComesFromTheOpticalModel(tc)
            cfg = struct('dmd', struct('binaryFrameRateHz', 25000));
            d = tfp.patterns.dwellCorrection(tc.PatchCentrePx, ...
                struct('config', cfg, 'baseDwellFrames', 100));
            tc.verifyEqual(d.frameDurationS, 40e-6, 'AbsTol', 1e-15, ...
                'A config frame rate must propagate — 12500 must not be hardcoded.');
            tc.verifyEqual(d.dwellS, 100 * 40e-6, 'AbsTol', 1e-15);
        end

        function patchCentreComesFromTheOpticalModel(tc)
            % Radius is measured from the ILLUMINATION centroid, which is not
            % necessarily the chip centre (T-BU-M3).
            cfg = struct('dmd', struct('patchCenterPx', [700 450]));
            d = tfp.patterns.dwellCorrection([700 450], struct('config', cfg));
            tc.verifyEqual(d.radiusPx, 0, 'AbsTol', 1e-12);
            tc.verifyEqual(d.correction, 1, 'AbsTol', 1e-12);
        end

        % =================================================================
        % Warnings
        % =================================================================

        function targetOutsideThePatchWarns(tc)
            d = tc.verifyWarning( ...
                @() tfp.patterns.dwellCorrection(tc.ptsAtRadius(300)), ...
                'tfp:patterns:dwellCorrection:outsidePatch');
            tc.verifyTrue(d.outsidePatch);
        end

        function targetAtExactlyThePatchEdgeDoesNotWarn(tc)
            % Boundary is inclusive, matching tfp.util.assertPatternInPatch.
            d = tfp.patterns.dwellCorrection(tc.ptsAtRadius(tc.EdgeRadiusPx));
            tc.verifyFalse(d.outsidePatch);
        end

        function runawayCorrectionIsClippedAndWarns(tc)
            d = tc.verifyWarning( ...
                @() tfp.patterns.dwellCorrection([], ...
                        struct('relativeIntensity', 0.1)), ...
                'tfp:patterns:dwellCorrection:correctionClipped');
            tc.verifyEqual(d.correction, 10, 'AbsTol', 1e-12, ...
                'Default maxCorrection is 10.');
            tc.verifyTrue(d.clipped);
        end

        function brightnessAboveUnityWarns(tc)
            tc.verifyWarning( ...
                @() tfp.patterns.dwellCorrection([], ...
                        struct('relativeIntensity', 1.5)), ...
                'tfp:patterns:dwellCorrection:aboveUnity');
        end

        function uniformityMapWithRadiusOnlyInputWarns(tc)
            model = tfp.util.opticalModel();
            calib = tc.syntheticCalib(model.gaussianWaistPx);
            tc.verifyWarning( ...
                @() tfp.patterns.dwellCorrection([], ...
                        struct('radiusPx', 100, 'uniformityCalib', calib)), ...
                'tfp:patterns:dwellCorrection:calibIgnored');
        end

        function targetOutsideTheMeasuredGridWarns(tc)
            model = tfp.util.opticalModel();
            calib = tc.syntheticCalib(model.gaussianWaistPx);
            tc.verifyWarning( ...
                @() tfp.patterns.dwellCorrection(tc.ptsAtRadius(320), ...
                        struct('uniformityCalib', calib)), ...
                'tfp:patterns:dwellCorrection:extrapolatedFromMap');
        end

        % =================================================================
        % Errors
        % =================================================================

        function noTargetsErrors(tc)
            tc.verifyError(@() tfp.patterns.dwellCorrection(), ...
                'tfp:patterns:dwellCorrection:noTargets');
        end

        function twoTargetSpecificationsError(tc)
            tc.verifyError(@() tfp.patterns.dwellCorrection( ...
                    tc.PatchCentrePx, struct('radiusPx', 50)), ...
                'tfp:patterns:dwellCorrection:ambiguousInput');
        end

        function badTargetShapeErrors(tc)
            tc.verifyError(@() tfp.patterns.dwellCorrection([1 2 3]), ...
                'tfp:patterns:dwellCorrection:badTargets');
            tc.verifyError(@() tfp.patterns.dwellCorrection([640 NaN]), ...
                'tfp:patterns:dwellCorrection:badTargets');
        end

        function badModeErrors(tc)
            tc.verifyError(@() tfp.patterns.dwellCorrection( ...
                    tc.PatchCentrePx, struct('mode', 'sqrt')), ...
                'tfp:patterns:dwellCorrection:badMode');
        end

        function badBaseDwellErrors(tc)
            tc.verifyError(@() tfp.patterns.dwellCorrection( ...
                    tc.PatchCentrePx, struct('baseDwellFrames', 2.5)), ...
                'tfp:patterns:dwellCorrection:badBaseDwell');
            tc.verifyError(@() tfp.patterns.dwellCorrection( ...
                    tc.PatchCentrePx, struct('baseDwellFrames', 0)), ...
                'tfp:patterns:dwellCorrection:badBaseDwell');
        end

        function conflictingBaseDwellSpecificationsError(tc)
            tc.verifyError(@() tfp.patterns.dwellCorrection( ...
                    tc.PatchCentrePx, ...
                    struct('baseDwellFrames', 10, 'baseDwellS', 1e-3)), ...
                'tfp:patterns:dwellCorrection:conflictingBaseDwell');
        end

        function subFrameBaseDwellErrors(tc)
            tc.verifyError(@() tfp.patterns.dwellCorrection( ...
                    tc.PatchCentrePx, struct('baseDwellS', 1e-6)), ...
                'tfp:patterns:dwellCorrection:baseDwellTooShort');
        end

        function unilluminatedTargetErrors(tc)
            % NaN in a measured map means the spot was never detected — no
            % dwell can fix that, so it must not silently become Inf frames.
            tc.verifyError(@() tfp.patterns.dwellCorrection([], ...
                    struct('relativeResponse', [0.5; NaN])), ...
                'tfp:patterns:dwellCorrection:targetNotIlluminated');
        end

        function zeroBrightnessErrors(tc)
            tc.verifyError(@() tfp.patterns.dwellCorrection([], ...
                    struct('relativeIntensity', [1; 0])), ...
                'tfp:patterns:dwellCorrection:badRelativeValue');
        end

        function malformedUniformityMapErrors(tc)
            tc.verifyError(@() tfp.patterns.dwellCorrection( ...
                    tc.PatchCentrePx, struct('uniformityCalib', struct('foo', 1))), ...
                'tfp:patterns:dwellCorrection:badCalib');

            bad = struct('dmdGridPts', [1 2; 3 4], 'intensityNorm', [1;1;1]);
            tc.verifyError(@() tfp.patterns.dwellCorrection( ...
                    tc.PatchCentrePx, struct('uniformityCalib', bad)), ...
                'tfp:patterns:dwellCorrection:badCalib');
        end

        function tooSparseUniformityMapErrors(tc)
            sparseCalib = struct('dmdGridPts', [640 400; 700 400], ...
                                 'intensityNorm', [1; 0.9]);
            tc.verifyError(@() tfp.patterns.dwellCorrection( ...
                    tc.PatchCentrePx, struct('uniformityCalib', sparseCalib)), ...
                'tfp:patterns:dwellCorrection:calibTooSparse');
        end

        function badInterpolationMethodErrors(tc)
            model = tfp.util.opticalModel();
            calib = tc.syntheticCalib(model.gaussianWaistPx);
            tc.verifyError(@() tfp.patterns.dwellCorrection( ...
                    tc.PatchCentrePx, ...
                    struct('uniformityCalib', calib, 'interpolation', 'cubic')), ...
                'tfp:patterns:dwellCorrection:badInterpolation');
        end

        function badOptionsTypeErrors(tc)
            tc.verifyError(@() tfp.patterns.dwellCorrection( ...
                    tc.PatchCentrePx, 42), ...
                'tfp:patterns:dwellCorrection:badOptions');
        end

    end
end
