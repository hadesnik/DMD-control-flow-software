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
    end
end
