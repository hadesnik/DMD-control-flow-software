classdef test_field_tilt_mock < matlab.unittest.TestCase
    %test_field_tilt_mock tfp.calibration.measureFieldTilt against a mock
    %   camera carrying a known tilted excitation plane.
    %
    %   Methods:
    %     recoversTheInjectedGradient — the central assertion.
    %     grooveGradientIsNearZero
    %     recoversAFlippedSign        — the proposal for threeD.depth_gradient_sign.
    %     recoversAGrooveTilt         — and warns that the tilt is off-axis.
    %     transformIsPinnedIndependently — breaks the mock<->fit circularity
    %                                  through dmdToDispersionUm with a
    %                                  hand-computed literal.
    %     reportsWalkAgainstTheHandoff
    %     handoffWalkFormulaIsSelfConsistent — the extrapolation reproduces the
    %                                  handoff's own 35.1 um from its own inputs.
    %     tooFewPointsThrows / patchContainmentThrowsEarly
    %     sanityBandWarnsButDoesNotFail
    %     stampsProvenance

    methods (Test)

        function recoversTheInjectedGradient(testCase)
            [calib, truth] = tfp.calibration.measureFieldTilt_mock();
            testCase.verifyEqual(calib.fit.aUmPerUm, truth.gradient, ...
                'RelTol', 0.05, ...
                'the fitted dispersion gradient must recover the injected one');
            testCase.verifyGreaterThan(calib.fit.r2, 0.98);
            testCase.verifyEqual(calib.kind, 'field_tilt');
        end

        function grooveGradientIsNearZero(testCase)
            calib = tfp.calibration.measureFieldTilt_mock();
            testCase.verifyLessThan(abs(calib.fit.bUmPerUm), 0.005, ...
                'a pure dispersion-axis tilt must not leak into the groove axis');
        end

        function recoversAFlippedSign(testCase)
            pos = tfp.calibration.measureFieldTilt_mock( ...
                struct('truthGradientUmPerUm',  0.03));
            neg = tfp.calibration.measureFieldTilt_mock( ...
                struct('truthGradientUmPerUm', -0.03));
            testCase.verifyEqual(pos.depthGradientSign,  1);
            testCase.verifyEqual(neg.depthGradientSign, -1);
        end

        function recoversAGrooveTilt(testCase)
            % A tilt along the wrong diagonal is diagnostic, not just a poor
            % fit: it means the 45-degree handedness or the chip clocking is
            % wrong. The function must say so.
            f = @() tfp.calibration.measureFieldTilt_mock(struct( ...
                'truthGradientUmPerUm', 0.005, 'truthGrooveUmPerUm', 0.03));
            testCase.verifyWarning(f, ...
                'tfp:calibration:measureFieldTilt:grooveGradientLarge');
            calib = evalWithoutWarnings(f);
            testCase.verifyEqual(calib.fit.bUmPerUm, 0.03, 'RelTol', 0.05);
        end

        function transformIsPinnedIndependently(testCase)
            % The mock and the fit both call tfp.optics.dmdToDispersionUm, so
            % a fault in that transform could cancel out. Pin one field point
            % against a hand-computed value: for a 1280x800 chip, a point 100
            % px right and 100 px down from centre has
            %   d_disp = (100 + 100)/sqrt(2) = 141.421 px
            %   x_disp = 141.421 * um_per_px_disp
            hc = tfp.util.readHandoffConstants();
            centre = [(1280 + 1) / 2, (800 + 1) / 2];
            pt = centre + [100, 100];
            [xDisp, yGroove] = tfp.optics.dmdToDispersionUm(pt, [800 1280], hc);
            testCase.verifyEqual(xDisp, (200 / sqrt(2)) * hc.um_per_px_disp, ...
                'RelTol', 1e-12);
            testCase.verifyEqual(yGroove, 0, 'AbsTol', 1e-9, ...
                'an equal +col +row step is pure dispersion, no groove component');
        end

        function reportsWalkAgainstTheHandoff(testCase)
            calib = tfp.calibration.measureFieldTilt_mock();
            testCase.verifyGreaterThan(calib.walkFullPatchUm, 0);
            testCase.verifyEqual(calib.expected.walkUm, ...
                tfp.util.readHandoffConstants().walk_um);
            % 0.03 um/um is ~2.4% above the design 0.02929, so the extrapolated
            % walk should land near the handoff's 35.1 um.
            testCase.verifyEqual(calib.walkFullPatchUm, 35.1, 'RelTol', 0.15);
        end

        function handoffWalkFormulaIsSelfConsistent(testCase)
            % Feeding the handoff's own gradient back through the extrapolation
            % must reproduce its own walk_um. If this ever fails, either the
            % ellipse geometry here or the handoff generator has changed.
            hc  = tfp.util.readHandoffConstants();
            Rpx = hc.patch_diameter_px / 2;
            walk = 2 * hc.depth_gradient_um_per_um * Rpx * hc.um_per_px_disp;
            testCase.verifyEqual(walk, hc.walk_um, 'RelTol', 0.01);
        end

        function tooFewPointsThrows(testCase)
            testCase.verifyError(@() tfp.calibration.measureFieldTilt_mock( ...
                struct('nRing', 2)), ...
                'tfp:calibration:measureFieldTilt:badOptions');
        end

        function patchContainmentThrowsEarly(testCase)
            % A bad radiusFrac must fail before any light, not 40 sweeps in.
            dmd = tfp.hardware.MockDMD();
            dmd.initialize(struct('nRows', 800, 'nCols', 1280));
            cam = tfp.hardware.MockSubstageCamera();
            cam.initialize(struct('nRows', 128, 'nCols', 128));
            z = tfp.hardware.MockZStage();
            z.initialize(struct('startZUm', 0));
            hc = tfp.util.readHandoffConstants();
            far = [(1280+1)/2 + hc.patch_diameter_px, (800+1)/2] + zeros(6, 2);
            far(:, 2) = (800+1)/2 + (1:6)';
            testCase.verifyError(@() tfp.calibration.measureFieldTilt( ...
                dmd, cam, z, struct(), struct('dmdPts', far, 'verbose', false)), ...
                'tfp:util:assertPatternInPatch:outsidePatch');
        end

        function sanityBandWarnsButDoesNotFail(testCase)
            % The handoff is rev 4 and predates the ratified f7 = 300 build, so
            % a disagreeing measurement is information, not an error. The
            % window must be widened to match the larger walk, or the fit is
            % measuring the clamp rather than the tilt.
            f = @() tfp.calibration.measureFieldTilt_mock(struct( ...
                'truthGradientUmPerUm', 0.12, 'zSearchHalfUm', 90, 'zStepUm', 3));
            testCase.verifyWarning(f, ...
                'tfp:calibration:measureFieldTilt:gradientOutOfBand');
            calib = evalWithoutWarnings(f);
            testCase.verifyFalse(calib.sanity.gradientInBand);
            testCase.verifyEqual(calib.fit.aUmPerUm, 0.12, 'RelTol', 0.08, ...
                'the fit must still be returned when it is out of band');
        end

        function narrowWindowIsReportedNotSilentlyBiased(testCase)
            % The failure this guards against: with a sweep range too small for
            % the walk, best focus is CLAMPED at the window edge and the fitted
            % gradient is biased toward zero — silently, and in exactly the
            % quantity being measured.
            f = @() tfp.calibration.measureFieldTilt_mock(struct( ...
                'truthGradientUmPerUm', 0.12, 'zSearchHalfUm', 25, 'zStepUm', 2));
            testCase.verifyWarning(f, ...
                'tfp:calibration:measureFieldTilt:focusAtWindowEdge');
            calib = evalWithoutWarnings(f);
            testCase.verifyTrue(any(calib.focusAtWindowEdge), ...
                'clamped points must be flagged');
            testCase.verifySize(calib.searchWindowsUm, [numel(calib.bestFocusZUm), 2]);
        end

        function stampsProvenance(testCase)
            calib = tfp.calibration.measureFieldTilt_mock();
            testCase.verifyEqual(calib.zRuler.class, 'tfp.hardware.MockZStage');
            testCase.verifyEqual(calib.zRuler.mount, 'objective');
            testCase.verifyEqual(calib.cameraSettings.class, ...
                'tfp.hardware.MockSubstageCamera');
            testCase.verifyTrue(isfield(calib.cameraSettings, 'exposureMs'));
            testCase.verifyEqual(calib.expected.handoffRev, ...
                tfp.util.readHandoffConstants().handoff_rev);
            testCase.verifyNotEmpty(calib.timestamp);
        end
    end
end

% ---------------------------------------------------------------------------
function out = evalWithoutWarnings(f)
w = warning('off', 'all');
c = onCleanup(@() warning(w));
out = f();
end
