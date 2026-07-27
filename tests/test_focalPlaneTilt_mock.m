classdef test_focalPlaneTilt_mock < matlab.unittest.TestCase
    %test_focalPlaneTilt_mock Tests for measureFocalPlaneTilt[_mock] + ZStage.
    %   mockRecoversKnownTilt      — the _mock recovers a known injected tilt
    %                                (plane coeffs, angle, azimuth) analytically.
    %   mockZeroTiltFlat           — a flat plane gives ~0 tilt and ~0 P-V.
    %   structShapeMatchesFields   — the _mock returns the documented fields.
    %   mockZStageBehaves          — MockZStage move/getPosition/range; out-of-range
    %                                and uninitialised calls throw.
    %   sutterStubFailsCleanly     — SutterZStage.initialize throws portOpenFailed
    %                                with no device present (off-rig).
    %   liveRecoversTiltAgainstMocks — the real routine + MockDMD + MockZStage +
    %                                Z-aware MockSubstageCamera recover a known
    %                                tilt. Requires Image Processing Toolbox.
    %
    %   T-BU-3b cases (anisotropic sample-plane tilt + design expectation):
    %   defaultsComeFromOpticalModelNotStale027
    %   designTiltReproducesHandoffNumbers
    %   sampleGradientRoundTripIsExact
    %   scalarUmPerPixelCannotExpressTheTilt
    %   grooveComponentIsSurfacedLoudly
    %   depthWalkComparableToFwhmIsStatedInWords
    %   flatFieldFailsTheTiltExpectation
    %   expectationFollowsConfigNotHardcodedConstants
    %   fittedMapSupersedesDesignConstants
    %   truthSpecErrorsAreTyped
    %   liveRoundTripRecoversSampleGradient — synthesize a known SAMPLE-plane
    %                                gradient, drive the Z-aware mock camera with
    %                                it, and recover it through the real routine.

    methods (Test)
        function mockRecoversKnownTilt(testCase)
            dmd  = struct('nRows', 800, 'nCols', 1280);
            a = 0.03; b = -0.02; z0 = 4;
            opts = struct('truthTiltPlane', [a b z0], 'nGridPoints', 9, ...
                'roiHalfWidthPx', 278, 'umPerPixel', 1.0);
            calib = tfp.calibration.measureFocalPlaneTilt_mock(dmd, opts);

            % Plane coefficients recovered exactly (synthetic, noise-free).
            testCase.verifyEqual(calib.planeBright.coeffs(2), a, 'AbsTol', 1e-9, 'slope in x');
            testCase.verifyEqual(calib.planeBright.coeffs(3), b, 'AbsTol', 1e-9, 'slope in y');
            testCase.verifyEqual(calib.planeBright.coeffs(1), z0, 'AbsTol', 1e-9, 'offset');
            testCase.verifyLessThan(calib.planeBright.residualsRms, 1e-9, 'plane is exact');

            % Angle/azimuth match the analytic values (umPerPixel = 1).
            testCase.verifyEqual(calib.tiltAngleDeg, atand(sqrt(a^2 + b^2)), 'AbsTol', 1e-6);
            testCase.verifyEqual(calib.tiltAzimuthDeg, atan2d(b, a), 'AbsTol', 1e-6);
            testCase.verifyGreaterThan(calib.peakToValleyUm, 0);
        end

        function mockZeroTiltFlat(testCase)
            dmd   = struct('nRows', 800, 'nCols', 1280);
            opts  = struct('truthTiltPlane', [0 0 7], 'nGridPoints', 9, 'roiHalfWidthPx', 278);
            calib = tfp.calibration.measureFocalPlaneTilt_mock(dmd, opts);

            testCase.verifyEqual(calib.tiltAngleDeg, 0, 'AbsTol', 1e-9);
            testCase.verifyEqual(calib.peakToValleyUm, 0, 'AbsTol', 1e-9);
        end

        function structShapeMatchesFields(testCase)
            dmd   = struct('nRows', 800, 'nCols', 1280);
            calib = tfp.calibration.measureFocalPlaneTilt_mock(dmd);

            requiredFields = {'dmdGridPts', 'cameraPts', 'zSweepUm', 'brightness', ...
                'sigma', 'zBestBrightUm', 'zBestSharpUm', 'valid', 'planeBright', ...
                'planeSharp', 'tiltAngleDeg', 'tiltAzimuthDeg', 'tiltAnglesXYDeg', ...
                'peakToValleyUm', 'umPerPixel', 'nGridPoints', 'gridSpacingPx', ...
                'roiHalfWidthPx', 'timestamp', 'notes'};
            for k = 1:numel(requiredFields)
                testCase.verifyTrue(isfield(calib, requiredFields{k}), ...
                    ['Missing field: ' requiredFields{k}]);
            end
            testCase.verifyTrue(all(calib.valid));
        end

        function mockZStageBehaves(testCase)
            z = tfp.hardware.MockZStage();
            z.initialize(struct('rangeUm', [-100 100], 'startUm', 0));

            testCase.verifyEqual(z.getPosition(), 0);
            z.moveTo(25);
            testCase.verifyEqual(z.getPosition(), 25);
            z.moveBy(-10);
            testCase.verifyEqual(z.getPosition(), 15);

            % out-of-range throws the base-class error
            testCase.verifyError(@() z.moveTo(500), 'tfp:hardware:ZStage:outOfRange');

            % move sequence is logged
            evts = {z.getLog().eventType};
            testCase.verifyTrue(any(strcmp(evts, 'moveTo')));

            z.cleanup();
            testCase.verifyError(@() z.moveTo(0), 'tfp:hardware:MockZStage:notInitialized');
        end

        function sutterStubFailsCleanly(testCase)
            % No Sutter device on the dev Mac: opening a bogus port must fail with
            % the typed error, not an uncaught serialport error.
            z = tfp.hardware.SutterZStage();
            cfg = struct('serialPort', 'COM_NONE_1', 'baud', 9600);
            testCase.verifyError(@() z.initialize(cfg), ...
                'tfp:hardware:SutterZStage:portOpenFailed');

            % missing serialPort is a config error
            z2 = tfp.hardware.SutterZStage();
            testCase.verifyError(@() z2.initialize(struct('baud', 9600)), ...
                'tfp:hardware:SutterZStage:badConfig');
        end

        function liveRecoversTiltAgainstMocks(testCase)
            testCase.assumeTrue(logical(license('test', 'image_toolbox')), ...
                'Requires Image Processing Toolbox (findSpotCentroid / fitGaussian2D).');

            % Small DMD so the sweep is fast (mirrors liveMockCalibration).
            dmdCfg.nRows                   = 200;
            dmdCfg.nCols                   = 320;
            dmdCfg.loadLatencyMsPerPattern = 0;
            dmd = tfp.hardware.MockDMD();
            dmd.initialize(dmdCfg);

            zstage = tfp.hardware.MockZStage();
            zstage.initialize(struct('rangeUm', [-100 100], 'startUm', 0));

            % Known tilt: best-focus Z (µm) = a*(col-cx) + b*(row-cy), µm per DMD-px.
            aTrue = 0.05; bTrue = -0.03;

            camCfg.nRows          = 256;
            camCfg.nCols          = 320;
            camCfg.dmd            = dmd;
            camCfg.truthAffine    = [0.5 0 20; 0 0.5 10; 0 0 1];
            camCfg.noiseLevel     = 0.01;
            camCfg.spotSigmaPx    = 4;
            camCfg.zStage         = zstage;
            camCfg.truthTiltPlane = [aTrue bTrue 0];
            camCfg.focusWaistZUm  = 5;
            camCfg.zRayleighUm    = 8;
            cam = tfp.hardware.MockSubstageCamera();
            cam.initialize(camCfg);

            opts.nGridPoints = 3;
            opts.gridSpacing = 50;
            opts.spotRadius  = 14;
            opts.exposureS   = 0;
            opts.settleS     = 0;
            opts.zSweepUm    = -12:1:12;
            opts.umPerPixel  = 1.0;      % so tilt angle uses raw px slope
            opts.showFigure  = false;

            calib = tfp.calibration.measureFocalPlaneTilt(dmd, cam, zstage, opts);

            testCase.verifyTrue(all(calib.valid), 'All spots should focus inside the sweep');
            testCase.verifyTrue(calib.planeBright.valid);

            % Recovered slopes match the injected tilt (brightness metric).
            testCase.verifyEqual(calib.planeBright.coeffs(2), aTrue, 'AbsTol', 0.012, 'x slope');
            testCase.verifyEqual(calib.planeBright.coeffs(3), bTrue, 'AbsTol', 0.012, 'y slope');
            testCase.verifyEqual(calib.tiltAngleDeg, atand(sqrt(aTrue^2 + bTrue^2)), ...
                'AbsTol', 0.8, 'recovered tilt angle');
        end

        % =================================================================
        % T-BU-3b — anisotropic sample-plane tilt + design expectation
        % =================================================================

        function defaultsComeFromOpticalModelNotStale027(testCase)
            % The retired isotropic 0.270 µm/px guess must be gone: every scale
            % now comes from tfp.util.opticalModel. 0.270 is ~4× too small AND
            % isotropic, so leaving it in place mis-states the tilt twice over.
            dmd   = struct('nRows', 800, 'nCols', 1280);
            model = tfp.util.opticalModel();
            calib = tfp.calibration.measureFocalPlaneTilt_mock(dmd, ...
                struct('warnOnExpectation', false));

            testCase.verifyEqual(calib.umPerPixel, model.umPerPixel, 'RelTol', 1e-12);
            testCase.verifyGreaterThan(calib.umPerPixel, 1.0, ...
                'the stale 0.270 µm/px default must be gone');
            testCase.verifyEqual(calib.model.umPerPixelGroove, model.umPerPixelGroove);
            testCase.verifyEqual(calib.model.umPerPixelDispersion, model.umPerPixelDispersion);
        end

        function designTiltReproducesHandoffNumbers(testCase)
            % With no truth supplied the mock synthesizes the DESIGN tilt, so the
            % reduction must land back on every number in handoff §6:
            % 1.245°, 0.02174 µm/µm, 0.03079 µm per DMD px on the (1,1)
            % diagonal, 17.1 µm across the patch, against a 17.7 µm axial FWHM —
            % and ZERO groove-axis component.
            dmd   = struct('nRows', 800, 'nCols', 1280);
            model = tfp.util.opticalModel();
            calib = tfp.calibration.measureFocalPlaneTilt_mock(dmd, ...
                struct('warnOnExpectation', false));
            s = calib.sampleTilt;
            e = calib.expected;

            testCase.verifyEqual(s.gradientDispersionUmPerUm, ...
                model.depthGradientSign * model.depthGradientUmPerUm, 'RelTol', 1e-10);
            testCase.verifyEqual(s.gradientGrooveUmPerUm, 0, 'AbsTol', 1e-12, ...
                'the design tilt has NO groove-axis component');
            testCase.verifyEqual(s.tiltAngleDeg, model.focalPlaneTiltDeg, 'AbsTol', 0.005);
            testCase.verifyEqual(abs(s.dispersionDiagonalUmPerPx), ...
                e.diagonalUmPerDmdPx, 'RelTol', 1e-10);
            testCase.verifyEqual(abs(s.dispersionDiagonalUmPerPx), 0.03079, 'AbsTol', 5e-5);
            testCase.verifyEqual(s.depthWalkAcrossPatchUm, ...
                e.depthWalkAcrossPatchUm, 'RelTol', 1e-10);
            testCase.verifyEqual(s.depthWalkAcrossPatchUm, 17.1, 'AbsTol', 0.1);
            testCase.verifyEqual(e.axialFwhmUm, model.axialFwhmUm);
            testCase.verifyEqual(calib.expectationCheck.walkInAxialFwhm, 17.1/17.7, ...
                'AbsTol', 0.02);

            % All verdicts pass on a design-conforming rig.
            testCase.verifyTrue(calib.expectationCheck.grooveComponentOK);
            testCase.verifyTrue(calib.expectationCheck.tiltOK);
            testCase.verifyTrue(calib.expectationCheck.signMatchesDesign);
            testCase.verifyTrue(calib.expectationCheck.passed);
        end

        function sampleGradientRoundTripIsExact(testCase)
            % The strongest check available without hardware: synthesize a known
            % SAMPLE-plane gradient through the anisotropic map, recover it with
            % the inverse. Exercises the 45° clocking, the two axis scales and
            % the sign conventions together. Noise-free, so it must be exact.
            dmd    = struct('nRows', 800, 'nCols', 1280);
            truths = {[0.02174 0], [0.037 -0.0125], [-0.05 0.05], 0.011};

            for k = 1:numel(truths)
                g = truths{k};
                calib = tfp.calibration.measureFocalPlaneTilt_mock(dmd, struct( ...
                    'truthDepthGradientUmPerUm', g, 'warnOnExpectation', false));
                expected = g;
                if isscalar(expected)
                    expected = [expected 0];   %#ok<AGROW> scalar means dispersion-only
                end
                testCase.verifyEqual(calib.truthDepthGradientUmPerUm, expected, ...
                    'AbsTol', 1e-12, 'truth is echoed back in sample terms');
                testCase.verifyEqual(calib.sampleTilt.gradientUmPerUm, expected, ...
                    'AbsTol', 1e-9, sprintf('round trip %d', k));
                % The DMD-pixel plane the mock synthesized is what the fit saw.
                testCase.verifyEqual(calib.planeBright.coeffs(2:3), ...
                    calib.truthTiltPlane(1:2), 'AbsTol', 1e-9);
            end
        end

        function scalarUmPerPixelCannotExpressTheTilt(testCase)
            % Anti-regression lock. If anyone "simplifies" the decomposition back
            % to a scalar µm/px, the legacy isotropic angle and the anisotropic
            % one would agree and this test would fail. On the design tilt the
            % scalar geometric-mean reduction overstates the angle by ~12%.
            dmd   = struct('nRows', 800, 'nCols', 1280);
            calib = tfp.calibration.measureFocalPlaneTilt_mock(dmd, ...
                struct('warnOnExpectation', false));

            testCase.verifyEqual(calib.sampleTilt.tiltAngleDeg, ...
                calib.expected.tiltAngleDeg, 'AbsTol', 0.005, ...
                'the anisotropic reduction matches the design tilt');
            testCase.verifyGreaterThan( ...
                abs(calib.tiltAngleDeg - calib.sampleTilt.tiltAngleDeg), 0.05, ...
                'the legacy scalar reduction is measurably different — that is the point');
        end

        function grooveComponentIsSurfacedLoudly(testCase)
            % THE diagnostic. The grating disperses along one chip diagonal only,
            % so it cannot make a groove-axis tilt; a measured one means
            % something is mounted wrong and must be surfaced, not averaged into
            % a scalar magnitude.
            dmd  = struct('nRows', 800, 'nCols', 1280);
            opts = struct('truthDepthGradientUmPerUm', [0.02174 0.015]);

            testCase.verifyWarning( ...
                @() tfp.calibration.measureFocalPlaneTilt_mock(dmd, opts), ...
                'tfp:calibration:measureFocalPlaneTilt:grooveComponent');

            calib = tfp.calibration.measureFocalPlaneTilt_mock(dmd, ...
                struct('truthDepthGradientUmPerUm', [0.02174 0.015], ...
                       'warnOnExpectation', false));
            testCase.verifyFalse(calib.expectationCheck.grooveComponentOK);
            testCase.verifyEqual(calib.sampleTilt.gradientGrooveUmPerUm, 0.015, ...
                'AbsTol', 1e-9);
            testCase.verifyGreaterThan(calib.sampleTilt.grooveFraction, 0.5);
            testCase.verifyTrue(contains(calib.report, 'GROOVE-AXIS COMPONENT'));
            testCase.verifyTrue(contains(calib.report, 'RED FLAG'));

            % A design-conforming tilt must NOT trip it.
            clean = tfp.calibration.measureFocalPlaneTilt_mock(dmd, ...
                struct('warnOnExpectation', false));
            testCase.verifyTrue(clean.expectationCheck.grooveComponentOK);
        end

        function depthWalkComparableToFwhmIsStatedInWords(testCase)
            % 17.1 µm of walk against a 17.7 µm axial FWHM means targets at
            % opposite field edges are genuinely not in the same plane. That is
            % an experimenter-facing fact, so it has to appear in words, not only
            % as a ratio.
            dmd = struct('nRows', 800, 'nCols', 1280);

            testCase.verifyWarning( ...
                @() tfp.calibration.measureFocalPlaneTilt_mock(dmd), ...
                'tfp:calibration:measureFocalPlaneTilt:depthWalkExceedsFwhm');

            calib = tfp.calibration.measureFocalPlaneTilt_mock(dmd, ...
                struct('warnOnExpectation', false));
            testCase.verifyTrue(calib.expectationCheck.depthWalkExceedsFwhm);
            testCase.verifyTrue(contains(calib.report, 'NOT one focal plane'));
            testCase.verifyTrue(contains(calib.report, 'NOT in the same'));
            testCase.verifyTrue(contains(calib.report, 'axial FWHM'));

            % A 20× flatter field is one plane, and says so instead.
            flat = tfp.calibration.measureFocalPlaneTilt_mock(dmd, struct( ...
                'truthDepthGradientUmPerUm', [0.02174/20 0], ...
                'warnOnExpectation', false));
            testCase.verifyFalse(flat.expectationCheck.depthWalkExceedsFwhm);
            testCase.verifyTrue(contains(flat.report, 'one focal plane'));
        end

        function flatFieldFailsTheTiltExpectation(testCase)
            % No tilt at all is as wrong as the wrong tilt: the grating must
            % produce ~0.02174 µm/µm. Warn with a stable id.
            dmd  = struct('nRows', 800, 'nCols', 1280);
            opts = struct('truthTiltPlane', [0 0 7]);
            testCase.verifyWarning( ...
                @() tfp.calibration.measureFocalPlaneTilt_mock(dmd, opts), ...
                'tfp:calibration:measureFocalPlaneTilt:tiltMismatch');

            calib = tfp.calibration.measureFocalPlaneTilt_mock(dmd, ...
                struct('truthTiltPlane', [0 0 7], 'warnOnExpectation', false));
            testCase.verifyFalse(calib.expectationCheck.tiltOK);
            testCase.verifyFalse(calib.expectationCheck.passed);
            testCase.verifyEqual(calib.expectationCheck.gradientRatio, 0, 'AbsTol', 1e-12);
        end

        function expectationFollowsConfigNotHardcodedConstants(testCase)
            % Nothing in the comparison may be a literal: change the config and
            % every expected number must move with it.
            dmd = struct('nRows', 800, 'nCols', 1280);
            cfg.dmd.umPerPixelGroove     = 2.0;
            cfg.dmd.umPerPixelDispersion = 3.0;
            cfg.dmd.depthGradientUmPerUm = 0.05;
            cfg.dmd.focalPlaneTiltDeg    = atand(0.05);
            cfg.dmd.patchRadiusPx        = 200;
            cfg.dmd.axialFwhmUm          = 20;

            calib = tfp.calibration.measureFocalPlaneTilt_mock(dmd, struct( ...
                'config', cfg, 'warnOnExpectation', false));
            e = calib.expected;

            testCase.verifyEqual(e.depthGradientUmPerUm, 0.05);
            testCase.verifyEqual(e.diagonalUmPerDmdPx, 0.05 * 3.0, 'RelTol', 1e-12);
            testCase.verifyEqual(e.dispersionExtentUm, 2 * 200 * 3.0, 'RelTol', 1e-12);
            testCase.verifyEqual(e.depthWalkAcrossPatchUm, 0.05 * 2 * 200 * 3.0, 'RelTol', 1e-12);
            testCase.verifyEqual(e.axialFwhmUm, 20);

            % The default truth follows the config too, and still round-trips.
            testCase.verifyEqual(calib.sampleTilt.gradientUmPerUm, [0.05 0], 'AbsTol', 1e-10);
            testCase.verifyTrue(calib.expectationCheck.passed);
        end

        function fittedMapSupersedesDesignConstants(testCase)
            % Per handoff §9 a fitted µm-valued map always wins over the design
            % constants. Doubling the map must double the DMD-pixel slopes the
            % same sample gradient implies, and the round trip must still close.
            dmd = struct('nRows', 800, 'nCols', 1280);
            g   = [0.03 -0.01];

            designed = tfp.calibration.measureFocalPlaneTilt_mock(dmd, struct( ...
                'truthDepthGradientUmPerUm', g, 'warnOnExpectation', false));

            Mdesign = tfp.patterns.dmdToSampleOffset(eye(2)).';   % DMD px -> µm
            fitted  = tfp.calibration.measureFocalPlaneTilt_mock(dmd, struct( ...
                'truthDepthGradientUmPerUm', g, 'warnOnExpectation', false, ...
                'dmdToSampleLinear', 2 * Mdesign, 'mapUnits', 'um'));

            testCase.verifyEqual(fitted.truthTiltPlane(1:2), ...
                2 * designed.truthTiltPlane(1:2), 'RelTol', 1e-12, ...
                'the fitted map, not the design constants, set the pixel slopes');
            testCase.verifyEqual(fitted.sampleTilt.gradientUmPerUm, g, 'AbsTol', 1e-9, ...
                'round trip still closes through the fitted map');
        end

        function truthSpecErrorsAreTyped(testCase)
            dmd = struct('nRows', 800, 'nCols', 1280);

            testCase.verifyError(@() tfp.calibration.measureFocalPlaneTilt_mock(dmd, ...
                struct('truthTiltPlane', [0.01 0 0], 'truthDepthGradientUmPerUm', 0.02)), ...
                'tfp:calibration:measureFocalPlaneTilt_mock:conflictingTruth');

            testCase.verifyError(@() tfp.calibration.measureFocalPlaneTilt_mock(dmd, ...
                struct('truthDepthGradientUmPerUm', [1 2 3])), ...
                'tfp:calibration:measureFocalPlaneTilt_mock:badGradient');

            testCase.verifyError(@() tfp.calibration.measureFocalPlaneTilt_mock(dmd, ...
                struct('truthDepthGradientUmPerUm', [NaN 0])), ...
                'tfp:calibration:measureFocalPlaneTilt_mock:badGradient');

            testCase.verifyError(@() tfp.calibration.measureFocalPlaneTilt_mock(dmd, ...
                struct('umPerPixel', -1)), ...
                'tfp:calibration:measureFocalPlaneTilt_mock:badUmPerPixel');

            testCase.verifyError(@() tfp.calibration.measureFocalPlaneTilt_mock(dmd, ...
                struct('config', 42)), ...
                'tfp:calibration:measureFocalPlaneTilt:badConfig');
        end

        function liveRoundTripRecoversSampleGradient(testCase)
            % Mock and real routine must agree end-to-end: the mock synthesizes
            % the DMD-pixel plane for a known SAMPLE-plane gradient, that plane
            % drives the Z-aware mock camera, and the real routine's
            % decomposition must recover the sample gradient it started from.
            testCase.assumeTrue(logical(license('test', 'image_toolbox')), ...
                'Requires Image Processing Toolbox (findSpotCentroid / fitGaussian2D).');

            gTrue = [0.05 0.02];   % [dispersion groove] µm depth per µm sample

            dmdCfg.nRows                   = 200;
            dmdCfg.nCols                   = 320;
            dmdCfg.loadLatencyMsPerPattern = 0;
            dmd = tfp.hardware.MockDMD();
            dmd.initialize(dmdCfg);

            zstage = tfp.hardware.MockZStage();
            zstage.initialize(struct('rangeUm', [-100 100], 'startUm', 0));

            % Same synthesis path the mock uses, so the two entry points cannot
            % drift apart: ask it for the DMD-pixel plane of gTrue.
            synth = tfp.calibration.measureFocalPlaneTilt_mock( ...
                struct('nRows', dmdCfg.nRows, 'nCols', dmdCfg.nCols), struct( ...
                'truthDepthGradientUmPerUm', gTrue, 'checkExpectation', false));

            camCfg.nRows          = 256;
            camCfg.nCols          = 320;
            camCfg.dmd            = dmd;
            camCfg.truthAffine    = [0.5 0 20; 0 0.5 10; 0 0 1];
            camCfg.noiseLevel     = 0.005;
            camCfg.spotSigmaPx    = 4;
            camCfg.zStage         = zstage;
            camCfg.truthTiltPlane = synth.truthTiltPlane;
            camCfg.focusWaistZUm  = 5;
            camCfg.zRayleighUm    = 8;
            cam = tfp.hardware.MockSubstageCamera();
            cam.initialize(camCfg);

            opts.nGridPoints       = 3;
            opts.gridSpacing       = 60;
            opts.spotRadius        = 14;
            opts.exposureS         = 0;
            opts.settleS           = 0;
            opts.zSweepUm          = -12:0.5:12;
            opts.showFigure        = false;
            opts.verbose           = false;
            opts.warnOnExpectation = false;

            calib = tfp.calibration.measureFocalPlaneTilt(dmd, cam, zstage, opts);

            testCase.verifyTrue(all(calib.valid), 'All spots should focus inside the sweep');
            testCase.verifyTrue(calib.sampleTilt.valid);
            testCase.verifyEqual(calib.sampleTilt.gradientDispersionUmPerUm, gTrue(1), ...
                'AbsTol', 0.008, 'dispersion-axis gradient');
            testCase.verifyEqual(calib.sampleTilt.gradientGrooveUmPerUm, gTrue(2), ...
                'AbsTol', 0.008, 'groove-axis gradient');
            % A groove component this large is exactly what the guard exists to
            % catch, and it must be flagged rather than folded into a magnitude.
            testCase.verifyFalse(calib.expectationCheck.grooveComponentOK);
        end
    end
end
