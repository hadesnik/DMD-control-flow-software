classdef test_calibrate_etl_planes_mock < matlab.unittest.TestCase
    %test_calibrate_etl_planes_mock ETL-plane depth recovery, the
    %   SLM<->ETL composition, and the verify report.

    methods (Test)

        function recoversPlaneDepths(testCase)
            [calib, truth] = tfp.calibration.calibrateEtlPlanes_mock();
            testCase.verifyEqual(calib.kind, 'etl_planes');
            testCase.verifyEqual(calib.nPlanes, numel(truth.planeZUm));
            % Parabolic peak localisation on a 2.5 um grid: sub-um accuracy.
            testCase.verifyEqual(calib.planeZUm, truth.planeZUm, 'AbsTol', 1.0);
        end

        function composition(testCase)
            slmCalib = struct('kind', 'slm_defocus', ...
                'fit', struct('slopeUmPerCmd', 0.9, 'interceptUm', 2.0, 'r2', 1), ...
                'zRuler', 'tfp.hardware.MockZStage', ...
                'timestamp', datetime('now'), 'notes', 't', ...
                'objective', 'nikon10x045');
            etlCalib = struct('kind', 'etl_planes', ...
                'planeZUm', [-16, 0, 17], 'nPlanes', 3, ...
                'zRuler', 'tfp.hardware.MockZStage', ...
                'timestamp', datetime('now'), 'notes', 't');

            zcal = tfp.calibration.composeZCalibration(slmCalib, etlCalib);
            testCase.verifyEqual(zcal.kind, 'z_composed');
            % dzCmd(p) = (planeZ - b) / a
            testCase.verifyEqual(zcal.dzCmdForPlane, ...
                ([-16, 0, 17] - 2.0) / 0.9, 'AbsTol', 1e-12);
            testCase.verifyEqual(zcal.etlPlaneZUm, [-16, 0, 17]);
            testCase.verifyTrue(isfield(zcal.provenance, 'slmTimestamp'));

            % Kind validation both ways.
            testCase.verifyError( ...
                @() tfp.calibration.composeZCalibration(etlCalib, etlCalib), ...
                'tfp:calibration:composeZCalibration:badInput');

            % Degenerate slope refuses to compose.
            bad = slmCalib; bad.fit.slopeUmPerCmd = 0;
            testCase.verifyError( ...
                @() tfp.calibration.composeZCalibration(bad, etlCalib), ...
                'tfp:calibration:composeZCalibration:degenerateSlope');

            % Mismatched rulers warn (one common z axis is the whole point).
            other = etlCalib; other.zRuler = 'tfp.hardware.ManualZStage';
            testCase.verifyWarning( ...
                @() tfp.calibration.composeZCalibration(slmCalib, other), ...
                'tfp:calibration:composeZCalibration:rulerMismatch');
        end

        function verifyReportAgreesOnConsistentData(testCase)
            zcal = struct('kind', 'z_composed', 'slmUmPerCmd', 1.0, ...
                'slmInterceptUm', 0, 'etlPlaneZUm', [-15, 0, 15], ...
                'nPlanes', 3, 'dzCmdForPlane', [-15, 0, 15]);
            % Marks whose observed plane matches the indirect prediction.
            found = struct('dzCmdUm', {-15, 0, 15}, 'planeIdx', {1, 2, 3});
            [~, report] = evalc(['tfp.calibration.verifyZCalibration(' ...
                'zcal, found, struct(''mockResponse'', true))']);
            testCase.verifyTrue(report.pass);
            testCase.verifyEqual(report.nAgree, 3);
            testCase.verifyTrue(report.acknowledged);

            % A disagreeing mark fails the report (and warns).
            foundBad = found;
            foundBad(2).planeIdx = 3;
            testCase.verifyWarning( ...
                @() runVerifyQuiet(zcal, foundBad), ...
                'tfp:calibration:verifyZCalibration:disagreement');
        end
    end
end

% --- Local helper ---

function runVerifyQuiet(zcal, found)
[~] = evalc(['tfp.calibration.verifyZCalibration(' ...
    'zcal, found, struct(''mockResponse'', true))']);
end
