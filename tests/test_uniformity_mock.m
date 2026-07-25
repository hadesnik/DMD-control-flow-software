classdef test_uniformity_mock < matlab.unittest.TestCase
    %test_uniformity_mock Tests for measureIlluminationUniformity[_mock].
    %   uniformFieldZeroCV        — a uniform profile gives CV 0, min/max 1,
    %                               and every grid point reachable.
    %   gaussianNonUniform        — a Gaussian profile gives clearly non-zero
    %                               CV, peak-normalised map, centre reachable.
    %   flatTopExcludesCorners    — a flat-top profile leaves the field corners
    %                               outside the illuminated footprint.
    %   extentAndCoverage         — with a DMD→scan affine + FOV box, the
    %                               reachable extent maps to scan coords and a
    %                               finite coverage fraction in (0,1] is returned.
    %   structShapeMatchesFields  — the mock returns the documented struct fields.
    %   liveRunsAgainstMocks      — the real routine runs end-to-end against
    %                               MockDMD + MockSubstageCamera and returns a
    %                               well-formed struct. Requires Image Processing
    %                               Toolbox (findSpotCentroid).

    methods (Test)
        function uniformFieldZeroCV(testCase)
            dmd  = struct('nRows', 800, 'nCols', 1280);
            opts = struct('profile', 'uniform', 'nGridPoints', 9, 'roiHalfWidthPx', 278);
            calib = tfp.calibration.measureIlluminationUniformity_mock(dmd, opts);

            testCase.verifyLessThan(calib.cv, 1e-12, 'Uniform field must have CV 0');
            testCase.verifyEqual(calib.minMaxRatio, 1.0, 'AbsTol', 1e-12);
            testCase.verifyEqual(calib.nReachable, 9^2, 'All spots reachable in a uniform field');
            testCase.verifyEqual(max(calib.intensityNorm), 1.0, 'AbsTol', 1e-12, ...
                'Peak of the normalised map must be 1');
        end

        function gaussianNonUniform(testCase)
            dmd  = struct('nRows', 800, 'nCols', 1280);
            opts = struct('profile', 'gaussian', 'sigmaFrac', 0.5, ...
                'nGridPoints', 9, 'roiHalfWidthPx', 278);
            calib = tfp.calibration.measureIlluminationUniformity_mock(dmd, opts);

            testCase.verifyGreaterThan(calib.cv, 0.1, ...
                'A Gaussian illumination profile must be clearly non-uniform');
            testCase.verifyLessThanOrEqual(calib.minMaxRatio, 1.0);

            % Peak is at the centre; normalised map peaks at 1.
            testCase.verifyEqual(max(calib.intensityNorm), 1.0, 'AbsTol', 1e-12);
            dmdCtr = [dmd.nCols/2, dmd.nRows/2];
            d = sqrt(sum((calib.dmdGridPts - dmdCtr).^2, 2));
            centerIdx = find(d == min(d), 1);
            testCase.verifyTrue(calib.reachable(centerIdx), 'Field centre must be reachable');
        end

        function flatTopExcludesCorners(testCase)
            dmd  = struct('nRows', 800, 'nCols', 1280);
            opts = struct('profile', 'flattop', 'footprintFrac', 1.0, ...
                'nGridPoints', 9, 'roiHalfWidthPx', 278);
            calib = tfp.calibration.measureIlluminationUniformity_mock(dmd, opts);

            testCase.verifyGreaterThan(calib.nReachable, 0);
            testCase.verifyLessThan(calib.nReachable, 9^2, ...
                'A flat-top footprint must leave some grid points dark');

            % The four field corners (largest radius) fall outside the footprint;
            % the centre is inside.
            dmdCtr = [dmd.nCols/2, dmd.nRows/2];
            d = sqrt(sum((calib.dmdGridPts - dmdCtr).^2, 2));
            [~, order] = sort(d, 'descend');
            corners = order(1:4);
            testCase.verifyFalse(any(calib.reachable(corners)), ...
                'Field corners must be outside the flat-top footprint');
            centerIdx = find(d == min(d), 1);
            testCase.verifyTrue(calib.reachable(centerIdx));
        end

        function extentAndCoverage(testCase)
            dmd = struct('nRows', 800, 'nCols', 1280);

            % DMD→scan affine: isotropic 0.4 scale, DMD centre (640,400) → scan
            % centre (256,128) of a 512×256 scan field.
            s  = 0.4;
            tx = 256.5 - s * 640;
            ty = 128.5 - s * 400;
            dmdToScan = [s 0 tx; 0 s ty; 0 0 1];

            opts = struct('profile', 'flattop', 'footprintFrac', 1.0, ...
                'nGridPoints', 9, 'roiHalfWidthPx', 278, ...
                'dmdToScan_affine', dmdToScan, 'scanPixels', [512, 256]);
            calib = tfp.calibration.measureIlluminationUniformity_mock(dmd, opts);

            testCase.verifyNotEmpty(calib.reachableHullScan, ...
                'Reachable hull must be mapped into scan-field coords');
            testCase.verifySize(calib.activeBoxScan, [4 2]);
            testCase.verifyEqual(calib.scanFieldBox, [0.5 0.5 512.5 256.5], 'AbsTol', 1e-9);

            testCase.verifyTrue(isfinite(calib.coverageFraction), ...
                'coverageFraction must be finite when an affine + FOV box are given');
            testCase.verifyGreaterThan(calib.coverageFraction, 0);
            testCase.verifyLessThanOrEqual(calib.coverageFraction, 1.0 + 1e-9);
        end

        function structShapeMatchesFields(testCase)
            dmd   = struct('nRows', 800, 'nCols', 1280);
            calib = tfp.calibration.measureIlluminationUniformity_mock(dmd);

            requiredFields = {'dmdGridPts', 'cameraPts', 'intensity', ...
                'intensityNorm', 'intensitySqrtNorm', 'reachable', 'cv', ...
                'minMaxRatio', 'nReachable', 'nGridPoints', 'gridSpacingPx', ...
                'roiHalfWidthPx', 'reachableHullDmd', 'activeBoxDmd', ...
                'reachableHullScan', 'activeBoxScan', 'coverageFraction', ...
                'scanFieldBox', 'umPerPixel', 'timestamp', 'notes'};
            for k = 1:numel(requiredFields)
                testCase.verifyTrue(isfield(calib, requiredFields{k}), ...
                    ['Missing field: ' requiredFields{k}]);
            end

            % No affine passed -> extent stays in DMD coords, coverage undefined.
            testCase.verifyEmpty(calib.reachableHullScan);
            testCase.verifyTrue(isnan(calib.coverageFraction));
            % sqrt map is the sqrt of the normalised map where defined.
            reach = calib.reachable;
            testCase.verifyEqual(calib.intensitySqrtNorm(reach), ...
                sqrt(calib.intensityNorm(reach)), 'AbsTol', 1e-12);
        end

        function liveRunsAgainstMocks(testCase)
            testCase.assumeTrue(logical(license('test', 'image_toolbox')), ...
                'Requires Image Processing Toolbox (findSpotCentroid).');

            % Small DMD so pattern generation is fast (mirrors liveMockCalibration).
            dmdCfg.nRows                   = 200;
            dmdCfg.nCols                   = 320;
            dmdCfg.loadLatencyMsPerPattern = 0;
            dmd = tfp.hardware.MockDMD();
            dmd.initialize(dmdCfg);

            truthAffine = [0.5 0 20; 0 0.5 10; 0 0 1];

            camCfg.nRows       = 256;
            camCfg.nCols       = 320;
            camCfg.dmd         = dmd;
            camCfg.truthAffine = truthAffine;
            camCfg.noiseLevel  = 0.02;
            camCfg.spotSigmaPx = 4;
            cam = tfp.hardware.MockSubstageCamera();
            cam.initialize(camCfg);

            opts.nGridPoints      = 3;
            opts.gridSpacing      = 50;
            opts.spotRadius       = 14;
            opts.exposureS        = 0;
            opts.showFigure       = false;
            opts.dmdToScan_affine = eye(3);        % identity: scan coords == DMD coords
            opts.scanPixels       = [320, 200];

            calib = tfp.calibration.measureIlluminationUniformity(dmd, cam, opts);

            testCase.verifyEqual(numel(calib.reachable), 9);
            testCase.verifyGreaterThan(calib.nReachable, 0, ...
                'Mock camera renders every spot, so some must be reachable');
            testCase.verifyTrue(isfinite(calib.cv), 'CV must be finite');
            testCase.verifyFalse(all(any(isnan(calib.cameraPts), 2)), ...
                'At least one spot centroid must be detected');
            testCase.verifyNotEmpty(calib.reachableHullScan);
            testCase.verifyTrue(isfinite(calib.coverageFraction), ...
                'coverageFraction must be finite with an affine + scanPixels');
        end
    end
end
