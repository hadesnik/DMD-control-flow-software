classdef test_measurePSF_mock < matlab.unittest.TestCase
    %test_measurePSF_mock Lateral PSF measurement against mock hardware.
    %   lateralRecoversMockSpotSigma — runs measurePSF end-to-end with
    %                                  MockDMD + MockSubstageCamera and a known
    %                                  rendered spot sigma; verifies the
    %                                  recovered lateral sigma/FWHM and struct.
    %   axialThrowsDeferred          — measureAxial=true raises the scoped
    %                                  axialDeferred error (axial path not built).
    %
    %   T-BU-3e additions (stale spot-size default + the rasterization floor):
    %   defaultSpotIsAtRasterFloor   — the default 7 µm probe is inside the
    %                                  floor, is drawn as the deterministic
    %                                  area-matched CIRCLE, and reports a
    %                                  sample aspect of exactly the
    %                                  uncorrected model.anisotropy. The
    %                                  correction is not pretended to help.
    %   floorWarningFiresAndIsSuppressible — the honest warning is emitted by
    %                                  default and silenceable.
    %   aboveFloorDrawsRoundEllipse  — a 20 µm request clears the floor, so the
    %                                  ellipse is drawn and the mirror count
    %                                  matches somaSpotGeometry.nPixels exactly
    %                                  (the T-BU-1f seam check).
    %   legacySpotRadiusPxUnchanged  — a supplied .spotRadiusPx still draws the
    %                                  historical isotropic pixel circle.
    %
    %   Requires Image Processing Toolbox (findSpotCentroid → graythresh etc.).

    methods (Test)
        function lateralRecoversMockSpotSigma(testCase)
            % --- small DMD so pattern generation is fast ---
            dmdCfg.nRows                   = 200;
            dmdCfg.nCols                   = 320;
            dmdCfg.loadLatencyMsPerPattern = 0;
            dmd = tfp.hardware.MockDMD();
            dmd.initialize(dmdCfg);

            % --- mock camera renders a Gaussian spot of known sigma (camera px) ---
            mockSpotSigmaPx     = 5;
            camCfg.nRows        = 256;
            camCfg.nCols        = 320;
            camCfg.dmd          = dmd;
            camCfg.truthAffine  = eye(3);        % DMD spot centre maps 1:1 to camera
            camCfg.noiseLevel   = 0.01;          % low noise for a clean fit
            camCfg.spotSigmaPx  = mockSpotSigmaPx;
            cam = tfp.hardware.MockSubstageCamera();
            cam.initialize(camCfg);

            opts.spotRadiusPx = 4;
            opts.exposureS    = 0;               % no real pause needed in mock
            opts.umPerPixel   = 1.0;             % so sigma in µm == sigma in camera px
            opts.nAverages    = 3;
            opts.showFigure   = false;

            calib = tfp.calibration.measurePSF(dmd, cam, struct(), opts);

            % --- documented fields present ---
            fields = {'sigmaXUm','sigmaYUm','fwhmXUm','fwhmYUm','sigmaZUm', ...
                'fwhmZUm','zPositionsUm','integratedF','spotCenterDMD', ...
                'gaussFitFocus','umPerPixel','timestamp','notes','images'};
            for k = 1:numel(fields)
                testCase.verifyTrue(isfield(calib, fields{k}), ...
                    ['Missing field: ' fields{k}]);
            end

            % --- lateral widths finite and positive ---
            testCase.verifyTrue(isfinite(calib.sigmaXUm) && calib.sigmaXUm > 0);
            testCase.verifyTrue(isfinite(calib.sigmaYUm) && calib.sigmaYUm > 0);

            % --- recovered sigma matches the rendered mock spot sigma ---
            testCase.verifyEqual(calib.sigmaXUm, mockSpotSigmaPx, 'RelTol', 0.4, ...
                'Recovered sigma_x should match the mock rendered spot sigma');
            testCase.verifyEqual(calib.sigmaYUm, mockSpotSigmaPx, 'RelTol', 0.4, ...
                'Recovered sigma_y should match the mock rendered spot sigma');

            % --- FWHM = 2*sqrt(2*ln2) * sigma ---
            fwhmFactor = 2 * sqrt(2 * log(2));
            testCase.verifyEqual(calib.fwhmXUm, fwhmFactor * calib.sigmaXUm, ...
                'RelTol', 1e-9);
            testCase.verifyEqual(calib.fwhmYUm, fwhmFactor * calib.sigmaYUm, ...
                'RelTol', 1e-9);

            % --- gaussFitFocus is [A x0 y0 sx sy B] ---
            testCase.verifySize(calib.gaussFitFocus, [1 6]);

            % --- axial fields empty (lateral-only) ---
            testCase.verifyEmpty(calib.sigmaZUm);
            testCase.verifyEmpty(calib.zPositionsUm);

            % --- spotCenterDMD is the DMD centre [col row] ---
            testCase.verifyEqual(calib.spotCenterDMD, ...
                [round(dmd.nCols/2), round(dmd.nRows/2)]);
        end

        function axialThrowsDeferred(testCase)
            dmdCfg.nRows                   = 200;
            dmdCfg.nCols                   = 320;
            dmdCfg.loadLatencyMsPerPattern = 0;
            dmd = tfp.hardware.MockDMD();
            dmd.initialize(dmdCfg);

            camCfg.nRows       = 256;
            camCfg.nCols       = 320;
            camCfg.dmd         = dmd;
            camCfg.truthAffine = eye(3);
            cam = tfp.hardware.MockSubstageCamera();
            cam.initialize(camCfg);

            opts.measureAxial = true;
            testCase.verifyError( ...
                @() tfp.calibration.measurePSF(dmd, cam, struct(), opts), ...
                'tfp:calibration:measurePSF:axialDeferred');
        end

        % =================================================================
        % T-BU-3e — spot sizing at the rasterization floor
        % =================================================================

        function defaultSpotIsAtRasterFloor(testCase)
            %defaultSpotIsAtRasterFloor The default probe is honestly elongated.
            %   measurePSF deliberately wants a near-minimal spot, which puts it
            %   inside the DMD rasterization floor: below ~3 px semi-axis the
            %   anisotropic ellipse rasterizes to the SAME pixel set as an
            %   area-matched circle and the sample aspect stays at the fully
            %   uncorrected 1.2588. The routine must therefore draw the
            %   deterministic circle and SAY the spot is elongated, not imply a
            %   roundness it cannot deliver.
            [dmd, cam] = testCase.makeRig();

            opts = testCase.fastOpts();
            calib = tfp.calibration.measurePSF(dmd, cam, struct(), opts);

            testCase.verifyTrue(calib.atRasterFloor, ...
                'The default near-minimal probe must be inside the floor');
            testCase.verifyTrue(calib.spotIsotropic, ...
                'Inside the floor the spot must be the area-matched circle');

            % The aspect is the UNCORRECTED anisotropy — that is the point.
            model = tfp.util.opticalModel();
            testCase.verifyEqual(calib.spotAspectRatio, model.anisotropy, ...
                'AbsTol', 1e-12, ...
                'A floor-sized spot cannot be made round; aspect stays 1.2588');

            % The delivered extents are somaSpotGeometry's own isotropic
            % report, so a caption can quote them without re-deriving anything.
            geom = tfp.patterns.somaSpotGeometry(calib.spotDiameterUm);
            testCase.verifyEqual(calib.spotExtentUm, geom.isotropicExtentUm, ...
                'AbsTol', 1e-12);
            testCase.verifyEqual(calib.spotExtentUm(2) / calib.spotExtentUm(1), ...
                model.anisotropy, 'AbsTol', 1e-9, ...
                'Dispersion extent must exceed groove extent by the anisotropy');

            % And the mirrors actually commanded are the circle's, not an
            % ellipse's — measured, not assumed.
            circle = tfp.patterns.singleSpot(dmd, ...
                [round(dmd.nCols/2), round(dmd.nRows/2)], geom.radiusPx);
            testCase.verifyEqual(calib.spotPixels, nnz(circle), ...
                'Drawn mirror count must equal the area-matched circle');
            testCase.verifyGreaterThan(calib.spotPixels, 10, ...
                'Still enough mirrors to be a usable spot, not a lattice artefact');
        end

        function floorWarningFiresAndIsSuppressible(testCase)
            %floorWarningFiresAndIsSuppressible Honest by default, quiet on request.
            [dmd, cam] = testCase.makeRig();

            noisy = testCase.fastOpts();
            noisy = rmfield(noisy, 'suppressFloorWarning');
            testCase.verifyWarning( ...
                @() tfp.calibration.measurePSF(dmd, cam, struct(), noisy), ...
                'tfp:calibration:measurePSF:spotAtRasterFloor');

            [dmd2, cam2] = testCase.makeRig();
            testCase.verifyWarningFree( ...
                @() tfp.calibration.measurePSF(dmd2, cam2, struct(), ...
                    testCase.fastOpts()));
        end

        function aboveFloorDrawsRoundEllipse(testCase)
            %aboveFloorDrawsRoundEllipse Above the floor the correction is applied.
            %   Also the T-BU-1f seam check: somaSpotGeometry's .spotOptions
            %   route must yield exactly geom.nPixels mirrors. Passing the
            %   area-matched .radiusPx into anisotropic mode instead silently
            %   paints ~17% fewer.
            [dmd, cam] = testCase.makeRig();

            opts = testCase.fastOpts();
            opts.spotDiameterUm = 20;
            calib = tfp.calibration.measurePSF(dmd, cam, struct(), opts);

            testCase.verifyFalse(calib.atRasterFloor, ...
                'A 20 um spot has ~8.9 px semi-axes — well clear of the floor');
            testCase.verifyFalse(calib.spotIsotropic);
            testCase.verifyEqual(calib.spotAspectRatio, 1, 'AbsTol', 1e-12, ...
                'Above the floor the spot is nominally round at the sample');

            geom = tfp.patterns.somaSpotGeometry(20);
            testCase.verifyEqual(calib.spotPixels, geom.nPixels, ...
                'Mirror count must match somaSpotGeometry.nPixels exactly');

            badOpts = rmfield(geom.spotOptions, 'semiAxisGroovePx');
            badMask = tfp.patterns.singleSpot(dmd, ...
                [round(dmd.nCols/2), round(dmd.nRows/2)], geom.radiusPx, badOpts);
            testCase.verifyLessThan(nnz(badMask), 0.9 * geom.nPixels, ...
                'The wrong hand-off route must be measurably short on pixels');
        end

        function legacySpotRadiusPxUnchanged(testCase)
            %legacySpotRadiusPxUnchanged .spotRadiusPx still draws the old circle.
            [dmd, cam] = testCase.makeRig();

            opts = testCase.fastOpts();
            opts.spotRadiusPx = 3;               % the retired default
            calib = tfp.calibration.measurePSF(dmd, cam, struct(), opts);

            expected = tfp.patterns.singleSpot(dmd, ...
                [round(dmd.nCols/2), round(dmd.nRows/2)], 3);
            testCase.verifyEqual(calib.spotPixels, nnz(expected), ...
                'Deprecated .spotRadiusPx must reproduce the historical circle');
            testCase.verifyTrue(isnan(calib.spotDiameterUm), ...
                'A pixel-radius probe has no stated sample-plane diameter');
            testCase.verifyEmpty(calib.spotGeometry);

            % Even the legacy path reports the true sample-plane size, because
            % a 3 px circle is a 6.75 x 8.50 um ellipse at the real scale.
            model = tfp.util.opticalModel();
            testCase.verifyEqual(calib.spotExtentUm, ...
                6 * [model.umPerPixelGroove, model.umPerPixelDispersion], ...
                'AbsTol', 1e-12);
        end
    end

    % =====================================================================
    % Shared fixtures for the T-BU-3e cases
    % =====================================================================
    methods (Access = private)
        function [dmd, cam] = makeRig(~)
            %makeRig Full-size MockDMD + MockSubstageCamera.
            %   Full chip size matters: the spot assertions compare against
            %   tfp.patterns.somaSpotGeometry, which knows nothing about a
            %   shrunken test array.
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
            %fastOpts No pauses, no figure, floor warning silenced.
            opts = struct('exposureS', 0, 'nAverages', 1, ...
                'showFigure', false, 'suppressFloorWarning', true);
        end
    end
end
