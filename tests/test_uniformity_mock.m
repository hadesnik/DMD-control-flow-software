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
    %
    %   T-BU-3e additions (stale spot-size defaults):
    %   defaultProbeIsSomaSized      — the default probe is somaSpotGeometry's
    %                                  soma diameter, not the old 15 px blob.
    %   probeMatchesSomaPixelCount   — THE T-BU-1f SEAM CHECK. The pattern the
    %                                  routine actually loads has exactly
    %                                  geom.nPixels ON mirrors, and the wrong
    %                                  hand-off route (.radiusPx into
    %                                  anisotropic mode) is shown to be ~17%
    %                                  short, so a regression back to it fails.
    %   legacySpotRadiusUnchanged    — a supplied .spotRadius still draws the
    %                                  historical isotropic pixel circle
    %                                  bit-for-bit.
    %   spotDiameterUmHonouredInUm   — asking in µm changes the pixel geometry.
    %   intensityNormMeaningPreserved — .intensityNorm is still the raw 2p
    %                                  response map that dwellCorrection
    %                                  consumes; T-BU-3e changed only the probe
    %                                  SIZE, never these two fields' meanings.

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

        % =================================================================
        % T-BU-3e — probe-spot sizing
        % =================================================================

        function defaultProbeIsSomaSized(testCase)
            %defaultProbeIsSomaSized Default probe = somaSpotGeometry's soma.
            %   The old default was spotRadius = 15 DMD px with a comment
            %   claiming "cell-sized". At the real bring-up scale that is a
            %   33.8 x 42.5 um ellipse — three to four cells wide.
            testCase.assumeTrue(logical(license('test', 'image_toolbox')), ...
                'Requires Image Processing Toolbox (findSpotCentroid).');
            [dmd, cam] = testCase.makeRig();

            calib = tfp.calibration.measureIlluminationUniformity(dmd, cam, ...
                testCase.fastOpts());

            geom = tfp.patterns.somaSpotGeometry();
            testCase.verifyEqual(calib.spotDiameterUm, geom.diameterUm, ...
                'AbsTol', 1e-12, ...
                'Default probe must be the soma diameter somaSpotGeometry states');
            testCase.verifyNotEmpty(calib.spotGeometry, ...
                'The geometry used must be recorded for the figure caption');

            % The legacy 15 px circle is ~9x the mirror budget of a soma.
            legacy = tfp.patterns.singleSpot(dmd, [dmd.nCols/2, dmd.nRows/2], 15);
            testCase.verifyLessThan(geom.nPixels, nnz(legacy) / 5, ...
                'A soma-sized probe must be far smaller than the retired 15 px default');
        end

        function probeMatchesSomaPixelCount(testCase)
            %probeMatchesSomaPixelCount T-BU-1f seam check, measured not assumed.
            %   somaSpotGeometry hands out three NON-interchangeable routes.
            %   The routine must use .spotOptions/.semiAxisGroovePx; feeding the
            %   area-matched isotropic .radiusPx into anisotropic mode silently
            %   paints ~17% fewer mirrors (67 rather than 81 for a soma), i.e.
            %   17% less delivered power, with no error anywhere.
            testCase.assumeTrue(logical(license('test', 'image_toolbox')), ...
                'Requires Image Processing Toolbox (findSpotCentroid).');
            [dmd, cam] = testCase.makeRig();

            tfp.calibration.measureIlluminationUniformity(dmd, cam, ...
                testCase.fastOpts());

            geom  = tfp.patterns.somaSpotGeometry();
            drawn = nnz(dmd.getActivePattern());
            testCase.verifyEqual(drawn, geom.nPixels, ...
                'Loaded probe pattern must have exactly geom.nPixels ON mirrors');

            % Pin the failure mode itself, so a regression to the broken route
            % cannot pass by coincidence.
            badOpts = rmfield(geom.spotOptions, 'semiAxisGroovePx');
            badMask = tfp.patterns.singleSpot(dmd, [dmd.nCols/2, dmd.nRows/2], ...
                geom.radiusPx, badOpts);
            testCase.verifyLessThan(nnz(badMask), 0.9 * geom.nPixels, ...
                'The wrong hand-off route must be measurably short on pixels');
        end

        function legacySpotRadiusUnchanged(testCase)
            %legacySpotRadiusUnchanged .spotRadius still draws the old circle.
            testCase.assumeTrue(logical(license('test', 'image_toolbox')), ...
                'Requires Image Processing Toolbox (findSpotCentroid).');
            [dmd, cam] = testCase.makeRig();

            opts = testCase.fastOpts();
            opts.spotRadius = 15;
            calib = tfp.calibration.measureIlluminationUniformity(dmd, cam, opts);

            expected = tfp.patterns.singleSpot(dmd, [dmd.nCols/2, dmd.nRows/2], 15);
            testCase.verifyEqual(nnz(dmd.getActivePattern()), nnz(expected), ...
                'Deprecated .spotRadius must reproduce the historical pixel circle');
            testCase.verifyTrue(isnan(calib.spotDiameterUm), ...
                'A pixel-radius probe has no stated sample-plane diameter');
            testCase.verifyEmpty(calib.spotGeometry);
        end

        function spotDiameterUmHonouredInUm(testCase)
            %spotDiameterUmHonouredInUm Asking in µm changes the pixel geometry.
            testCase.assumeTrue(logical(license('test', 'image_toolbox')), ...
                'Requires Image Processing Toolbox (findSpotCentroid).');
            [dmd, cam] = testCase.makeRig();

            opts = testCase.fastOpts();
            opts.spotDiameterUm = 20;
            calib = tfp.calibration.measureIlluminationUniformity(dmd, cam, opts);

            geom20 = tfp.patterns.somaSpotGeometry(20);
            testCase.verifyEqual(calib.spotDiameterUm, 20, 'AbsTol', 1e-12);
            testCase.verifyEqual(nnz(dmd.getActivePattern()), geom20.nPixels, ...
                'A 20 um request must draw the 20 um ellipse');
            testCase.verifyGreaterThan(geom20.nPixels, ...
                tfp.patterns.somaSpotGeometry().nPixels, ...
                'Sanity: 20 um is bigger than a soma');
        end

        function intensityNormMeaningPreserved(testCase)
            %intensityNormMeaningPreserved The dwellCorrection contract holds.
            %   .intensityNorm is the RAW integrated 2p signal (prop I^2) and
            %   .intensitySqrtNorm is its square root (prop I). dwellCorrection
            %   consumes the former and treats it as g^2; swapping them would
            %   silently drop the 2p correction (2.72x at the patch edge) to
            %   the energy-equalising linear one (1.65x). T-BU-3e touched only
            %   the probe SIZE, so this must still hold.
            testCase.assumeTrue(logical(license('test', 'image_toolbox')), ...
                'Requires Image Processing Toolbox (findSpotCentroid).');
            [dmd, cam] = testCase.makeRig();

            calib = tfp.calibration.measureIlluminationUniformity(dmd, cam, ...
                testCase.fastOpts());

            reach = calib.reachable;
            testCase.assumeTrue(any(reach), 'Need at least one reachable spot');
            testCase.verifyEqual(calib.intensitySqrtNorm(reach), ...
                sqrt(calib.intensityNorm(reach)), 'AbsTol', 1e-12, ...
                'intensitySqrtNorm must remain sqrt(intensityNorm)');
            testCase.verifyLessThanOrEqual(max(calib.intensityNorm(reach)), ...
                1 + 1e-12, 'intensityNorm stays peak-normalised');

            % The whole struct is still consumable by dwellCorrection in its
            % default (two-photon) mode — the end-to-end T-BU-3d contract.
            dwell = tfp.patterns.dwellCorrection([dmd.nCols/2, dmd.nRows/2], ...
                struct('uniformityCalib', calib));
            testCase.verifyNotEmpty(dwell.equalises);
            testCase.verifySubstring(lower(dwell.equalises), '2p', ...
                'Default dwell correction must still equalise 2p dose');
            testCase.verifyTrue(all(isfinite(dwell.dwellFrames)) && ...
                all(dwell.dwellFrames > 0), ...
                'Dwell frames from the measured map must be finite and positive');
        end
    end

    % =====================================================================
    % Shared fixtures for the T-BU-3e cases
    % =====================================================================
    methods (Access = private)
        function [dmd, cam] = makeRig(~)
            %makeRig Full-size MockDMD + MockSubstageCamera.
            %   Full chip size matters here: the spot-geometry assertions are
            %   compared against tfp.patterns.somaSpotGeometry, which knows
            %   nothing about a shrunken test array.
            dmdCfg.nRows                   = 800;
            dmdCfg.nCols                   = 1280;
            dmdCfg.loadLatencyMsPerPattern = 0;
            dmd = tfp.hardware.MockDMD();
            dmd.initialize(dmdCfg);

            camCfg.nRows       = 256;
            camCfg.nCols       = 320;
            camCfg.dmd         = dmd;
            camCfg.truthAffine = [0.2 0 20; 0 0.2 10; 0 0 1];
            camCfg.noiseLevel  = 0.01;
            camCfg.spotSigmaPx = 4;
            cam = tfp.hardware.MockSubstageCamera();
            cam.initialize(camCfg);
        end

        function opts = fastOpts(~)
            %fastOpts A 3x3 grid with no pauses and no figure.
            opts = struct('nGridPoints', 3, 'gridSpacing', 50, ...
                'exposureS', 0, 'showFigure', false);
        end
    end
end
