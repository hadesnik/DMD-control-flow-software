classdef test_patterns < matlab.unittest.TestCase
    %test_patterns Phase 1 pattern-generation tests.
    %   Uses a plain struct as a MockDMD stand-in (just needs .nRows and
    %   .nCols). tfp.hardware.MockDMD itself is not yet implemented.

    properties (Constant)
        DMD_ROWS = 800;
        DMD_COLS = 1280;
    end

    methods (Access = private)
        function dmd = makeMockDmd(~)
            dmd = struct('nRows', test_patterns.DMD_ROWS, ...
                         'nCols', test_patterns.DMD_COLS);
        end

        function cal = identityCalibration(~)
            cal.dmdToSample_affine = eye(3);
            cal.pixelsPerUm = 1;   % 1 um = 1 DMD px (clean test math)
            cal.umPerPixel  = 1;
        end
    end

    methods (Test)
        function singleSpot_circle_geometry(testCase)
            dmd = testCase.makeMockDmd();
            cal = testCase.identityCalibration();
            center = [640, 400];   % [col row], middle of frame
            r = 10;
            mask = tfp.patterns.singleSpot(dmd, center, r);

            testCase.verifyEqual(size(mask), [dmd.nRows, dmd.nCols], ...
                'mask must match DMD dimensions');
            testCase.verifyTrue(islogical(mask), 'mask must be logical');

            % center pixel on
            testCase.verifyTrue(mask(center(2), center(1)));
            % pixel exactly at radius is on (boundary inclusive)
            testCase.verifyTrue(mask(center(2), center(1) + r));
            % pixel one past radius is off
            testCase.verifyFalse(mask(center(2), center(1) + r + 1));
            % far corner is off
            testCase.verifyFalse(mask(1, 1));

            % filled-disc area within 20% of pi*r^2 (discretization slack)
            actualArea = nnz(mask);
            expectedArea = pi * r^2;
            relErr = abs(actualArea - expectedArea) / expectedArea;
            testCase.verifyLessThan(relErr, 0.2);
        end

        function multiSpot_union_equals_sum_when_disjoint(testCase)
            dmd = testCase.makeMockDmd();
            cal = testCase.identityCalibration();
            r = 5;
            % Three well-separated targets so spots don't overlap.
            targets = [200, 200; 800, 400; 1100, 700];
            mask = tfp.patterns.multiSpot(dmd, targets, r);

            testCase.verifyEqual(size(mask), [dmd.nRows, dmd.nCols]);
            testCase.verifyTrue(islogical(mask));

            % Union of per-target singleSpot should equal multiSpot.
            singleUnion = false(dmd.nRows, dmd.nCols);
            for k = 1:size(targets, 1)
                singleUnion = singleUnion | ...
                    tfp.patterns.singleSpot(dmd, targets(k, :), r);
            end
            testCase.verifyEqual(mask, singleUnion);

            % Disjoint => nnz of union == sum of individual nnz.
            singleAreas = arrayfun(@(k) ...
                nnz(tfp.patterns.singleSpot(dmd, targets(k, :), r)), ...
                1:size(targets, 1));
            testCase.verifyEqual(nnz(mask), sum(singleAreas));

            % Each target center pixel on.
            for k = 1:size(targets, 1)
                testCase.verifyTrue(mask(targets(k, 2), targets(k, 1)));
            end
        end

        function ppsfPattern_offsets_shift_in_dmd_pixels(testCase)
            dmd = testCase.makeMockDmd();
            cal = testCase.identityCalibration();   % pixelsPerUm = 1
            center = [640, 400];
            offsetsUm = [0, 0; 20, 0; -10, 5];
            r = 3;
            patterns = tfp.patterns.ppsfPattern(dmd, center, offsetsUm, r, cal);

            testCase.verifyEqual(size(patterns), ...
                [dmd.nRows, dmd.nCols, size(offsetsUm, 1)]);
            testCase.verifyTrue(islogical(patterns));

            for k = 1:size(offsetsUm, 1)
                slice = patterns(:, :, k);
                expectedCol = center(1) + offsetsUm(k, 1) * cal.pixelsPerUm;
                expectedRow = center(2) + offsetsUm(k, 2) * cal.pixelsPerUm;

                testCase.verifyTrue(slice(expectedRow, expectedCol), ...
                    sprintf('Slice %d: expected center pixel must be on', k));

                % A pixel just past the radius along +x must be off.
                offCol = expectedCol + r + 1;
                if offCol <= dmd.nCols
                    testCase.verifyFalse(slice(expectedRow, offCol), ...
                        sprintf('Slice %d: pixel past radius must be off', k));
                end
            end
        end

        function calibratedAffine_identity_and_known_transform(testCase)
            % Identity should round-trip coords unchanged.
            cal.dmdToSample_affine = eye(3);
            coords = [10, 20; 30, 40; 0, 0];
            out = tfp.patterns.calibratedAffine(coords, cal);
            testCase.verifyEqual(out, coords, ...
                'Identity affine must return coords unchanged.');

            % 2x scale + translate by (5, -5). Hand-computed expected outputs.
            cal2.dmdToSample_affine = [2 0 5; 0 2 -5; 0 0 1];
            coords2 = [0, 0; 1, 1; 10, 20];
            expected = [5, -5; 7, -3; 25, 35];
            actual = tfp.patterns.calibratedAffine(coords2, cal2);
            testCase.verifyEqual(actual, expected, 'AbsTol', 1e-10);

            % Single-row input also works.
            single = tfp.patterns.calibratedAffine([3, 4], cal);
            testCase.verifyEqual(single, [3, 4]);
        end
    end
end
