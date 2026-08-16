classdef test_locate_marks_mock < matlab.unittest.TestCase
    %test_locate_marks_mock Direct-method mark localisation on a synthetic
    %   ETL stack: dark marks at known lateral positions, each darkest in a
    %   known plane, must map back to (dzCmd, plane).

    methods (Access = private)
        function [stack, ledger, calibration] = makeSyntheticStack(~)
            % 3-plane, 2-volume interleaved stack, bright background 100.
            nR = 256; nC = 256; nPlanes = 3; nVol = 2;
            stack = 100 * ones(nR, nC, nPlanes * nVol);

            % Identity-ish lateral calibration: DMD px -> scan px (0.2 scale).
            A = [0.2 0 0; 0 0.2 0; 0 0 1];
            calibration.dmdToScan_affine = A;

            % Three marks: DMD coords chosen so scan positions are spread;
            % mark m is darkest in plane m.
            dmdCoords = [300 300; 640 400; 900 600];
            dz        = [-20, 0, 20];
            ledger = struct('dzCmdUm', {}, 'dmdCoords', {});
            for m = 1:3
                ledger(m).dzCmdUm   = dz(m);
                ledger(m).dmdCoords = dmdCoords(m, :);
                pred = A * [dmdCoords(m, :)'; 1];
                cx = round(pred(1)); cy = round(pred(2));
                for p = 1:nPlanes
                    % Darkness contrast peaks in the mark's own plane.
                    depthFactor = exp(-abs(p - m));
                    for v = 1:nVol
                        f = (v - 1) * nPlanes + p;
                        stack(cy-4:cy+4, cx-4:cx+4, f) = ...
                            100 * (1 - 0.8 * depthFactor);
                    end
                end
            end
        end
    end

    methods (Test)

        function marksMapToTheirPlanes(testCase)
            [stack, ledger, calibration] = testCase.makeSyntheticStack();
            found = tfp.calibration.locateMarksInStack(stack, ledger, ...
                calibration, struct('nPlanes', 3, 'windowPx', 6));

            testCase.verifyEqual(numel(found), 3);
            for m = 1:3
                testCase.verifyEqual(found(m).planeIdx, m, ...
                    sprintf('mark %d localised to the wrong plane', m));
                testCase.verifyEqual(found(m).dzCmdUm, ledger(m).dzCmdUm);
                % Contrast profile peaks where the mark is darkest.
                [~, iMax] = max(found(m).contrastByPlane);
                testCase.verifyEqual(iMax, m);
            end
        end

        function zcalLookupFillsDepth(testCase)
            [stack, ledger, calibration] = testCase.makeSyntheticStack();
            zcal.etlPlaneZUm = [-17, 0, 18];
            found = tfp.calibration.locateMarksInStack(stack, ledger, ...
                calibration, struct('nPlanes', 3, 'windowPx', 6, 'zcal', zcal));
            testCase.verifyEqual([found.depthUmFromPlanes], [-17, 0, 18]);
        end

        function validation(testCase)
            [stack, ledger, calibration] = testCase.makeSyntheticStack();
            testCase.verifyError(@() tfp.calibration.locateMarksInStack( ...
                'some.tif', ledger, calibration), ...
                'tfp:calibration:locateMarksInStack:pathNotSupportedYet');
            noAffine = struct('umPerPixel', 1);
            testCase.verifyError(@() tfp.calibration.locateMarksInStack( ...
                stack, ledger, noAffine), ...
                'tfp:calibration:locateMarksInStack:badCalibration');
        end
    end
end
