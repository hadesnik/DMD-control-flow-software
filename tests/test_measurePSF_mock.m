classdef test_measurePSF_mock < matlab.unittest.TestCase
    %test_measurePSF_mock Lateral PSF measurement against mock hardware.
    %   lateralRecoversMockSpotSigma — runs measurePSF end-to-end with
    %                                  MockDMD + MockSubstageCamera and a known
    %                                  rendered spot sigma; verifies the
    %                                  recovered lateral sigma/FWHM and struct.
    %   axialThrowsDeferred          — measureAxial=true raises the scoped
    %                                  axialDeferred error (axial path not built).
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
    end
end
