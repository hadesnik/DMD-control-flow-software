classdef test_calibrate_slm_defocus_mock < matlab.unittest.TestCase
    %test_calibrate_slm_defocus_mock The indirect SLM z-calibration must
    %   recover the truth slope wired into MockSubstageCamera's defocus
    %   blur model. Requires Image Processing Toolbox.

    methods (Test)

        function recoversTruthSlope(testCase)
            [calib, truth] = tfp.calibration.calibrateSlmDefocus_mock();

            testCase.verifyEqual(calib.kind, 'slm_defocus');
            testCase.verifyEqual(numel(calib.dzCmdUm), numel(calib.zPhysUm));

            % The fitted slope IS the calibration; must match the truth
            % wired into the mock camera. z steps are 4 um so vertex
            % interpolation noise is ~1 um; over +/-60 um that bounds the
            % slope error well under 0.08.
            testCase.verifyEqual(calib.fit.slopeUmPerCmd, truth.slmUmPerCmd, ...
                'AbsTol', 0.08);
            testCase.verifyEqual(calib.fit.interceptUm, truth.interceptUm, ...
                'AbsTol', 4.0);
            testCase.verifyGreaterThan(calib.fit.r2, 0.98);

            % Provenance fields the composition relies on.
            testCase.verifyEqual(calib.zRuler, 'tfp.hardware.MockZStage');
            testCase.verifyEqual(calib.objective, 'nikon10x045');
        end

        function warnsWhenSlopeOutOfBand(testCase)
            % A truth slope far from 1 must trip the sanity-band WARNING
            % (never an error — the fit is the calibration).
            testCase.verifyWarning( ...
                @() tfp.calibration.calibrateSlmDefocus_mock( ...
                    struct('truthSlmUmPerCmd', 0.5, 'dzCmdUm', -40:20:40)), ...
                'tfp:calibration:calibrateSlmDefocus:slopeOutOfBand');
        end

        function requiresSequenceCapableDevice(testCase)
            dmd = tfp.hardware.MockDMD();
            dmd.initialize(struct('loadLatencyMsPerPattern', 0));
            plm = tfp.hardware.MockPLM();   % legacy: no sequence support
            plm.initialize(struct());
            cam = tfp.hardware.MockSubstageCamera();
            cam.initialize(struct());
            z = tfp.hardware.MockZStage();
            z.initialize(struct());
            cfg.objective = struct('name', 'nikon10x045');
            cfg.slm = struct('enabled', true, 'm_relay', 1.2);
            testCase.verifyError( ...
                @() tfp.calibration.calibrateSlmDefocus(dmd, plm, cam, z, cfg), ...
                'tfp:calibration:calibrateSlmDefocus:needsSequenceDevice');
        end
    end
end
