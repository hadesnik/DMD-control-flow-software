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
            r = 14;
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
            r = 14;
            % Three well-separated targets so spots don't overlap
            % (>>2r=28 px apart).
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
            offsetsUm = [0, 0; 30, 0; -20, 10];
            r = 14;
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

        function calibratedAffine_targetSpace(testCase)
            coords = [10, 20; 30, 40];

            % Default and explicit 'camera' both use dmdToSample_affine.
            cal.dmdToSample_affine = [2 0 1; 0 2 2; 0 0 1];
            expected = [21, 42; 61, 82];
            testCase.verifyEqual( ...
                tfp.patterns.calibratedAffine(coords, cal), expected, 'AbsTol', 1e-10, ...
                'Default (camera) must use dmdToSample_affine.');
            testCase.verifyEqual( ...
                tfp.patterns.calibratedAffine(coords, cal, 'camera'), expected, 'AbsTol', 1e-10, ...
                'Explicit camera must use dmdToSample_affine.');

            % 'scanfield' uses dmdToScan_affine.
            calScan.dmdToScan_affine = [3 0 0; 0 3 1; 0 0 1];
            testCase.verifyEqual( ...
                tfp.patterns.calibratedAffine(coords, calScan, 'scanfield'), ...
                [30, 61; 90, 121], 'AbsTol', 1e-10, ...
                'scanfield must use dmdToScan_affine.');

            % Unknown targetSpace throws unknownTargetSpace.
            testCase.verifyError( ...
                @() tfp.patterns.calibratedAffine(coords, cal, 'bogus'), ...
                'tfp:patterns:calibratedAffine:unknownTargetSpace');

            % Missing dmdToScan_affine throws missingAffine.
            testCase.verifyError( ...
                @() tfp.patterns.calibratedAffine(coords, cal, 'scanfield'), ...
                'tfp:patterns:calibratedAffine:missingAffine');

            % Missing dmdToSample_affine also throws missingAffine.
            testCase.verifyError( ...
                @() tfp.patterns.calibratedAffine(coords, calScan, 'camera'), ...
                'tfp:patterns:calibratedAffine:missingAffine');
        end

        function powerLUT_interpolates(testCase)
            % Build a synthetic calibration with a known linear curve:
            % power = dmdActivePx / 1000  (mW), fovArea = 1000 µm²
            % so power density = dmdActivePx / 1e6  (mW/µm²)
            fovArea = 1000;  % µm²
            cal.powerCurve.dmdActivePx   = [0, 512000, 1024000];   % 0, 40%, 80% of 1280*800
            cal.powerCurve.powerAtSample = [0, 0.512, 1.024];      % mW, linear
            cal.powerCurve.fovAreaUm2    = fovArea;

            % Midpoint: 0.256 mW / 1000 µm² = 2.56e-4 mW/µm²
            % Expected dutyCycle: 256000 / (800*1280) = 0.25
            target = 0.256 / fovArea;
            dc = tfp.patterns.powerLUT(target, cal);
            testCase.verifyEqual(dc, 0.25, 'AbsTol', 1e-9, ...
                'Interpolated dutyCycle must equal 0.25 at midpoint');

            % Clamping: target below zero should give 0
            dcLow = tfp.patterns.powerLUT(-1, cal);
            testCase.verifyEqual(dcLow, 0, 'dutyCycle must clamp to 0 at low end');

            % Clamping: very high target should clamp to 1
            dcHigh = tfp.patterns.powerLUT(1e6, cal);
            testCase.verifyEqual(dcHigh, 1, 'dutyCycle must clamp to 1 at high end');

            % Empty calibration returns fallback without error
            emptyFallback = tfp.patterns.powerLUT(0, struct('powerCurve', []));
            testCase.verifyEqual(emptyFallback, 0, ...
                'Empty calibration fallback must return 0 for zero input');

            noCurveFallback = tfp.patterns.powerLUT(0, struct());
            testCase.verifyEqual(noCurveFallback, 0, ...
                'Missing powerCurve field fallback must return 0 for zero input');
        end

        % =================================================================
        % T-BU-1b: anisotropic (45-degree-clocked chip) spot shapes.
        % The chip's optical axes are its DIAGONALS and the sample scale is
        % anisotropic, so a pixel circle lands as a 1.2588x ellipse at the
        % sample. These cases pin the opt-in ellipse mode and, first of all,
        % pin that the DEFAULT path did not move.
        % =================================================================

        function anisotropic_default_path_is_unchanged(testCase)
            % The historical 3-arg call must be byte-identical to (a) the
            % inlined pre-T-BU-1b expression, (b) a 4-arg call with an empty
            % options struct, and (c) an explicit anisotropic = false.
            dmd = testCase.makeMockDmd();
            [cols, rows] = meshgrid(1:dmd.nCols, 1:dmd.nRows);

            cases = {[640, 400], 14; [200.5, 700.25], 3; [1, 1], 40};
            for k = 1:size(cases, 1)
                c = cases{k, 1};
                r = cases{k, 2};

                % (a) verbatim copy of the original singleSpot body
                legacy = (cols - c(1)).^2 + (rows - c(2)).^2 <= r^2;

                testCase.verifyEqual(tfp.patterns.singleSpot(dmd, c, r), legacy, ...
                    'Default singleSpot must be byte-identical to the old circle.');
                testCase.verifyEqual( ...
                    tfp.patterns.singleSpot(dmd, c, r, struct()), legacy);
                testCase.verifyEqual( ...
                    tfp.patterns.singleSpot(dmd, c, r, ...
                        struct('anisotropic', false)), legacy);
                testCase.verifyEqual( ...
                    tfp.patterns.singleSpot(dmd, c, r, []), legacy);

                % multiSpot's default path likewise
                testCase.verifyEqual(tfp.patterns.multiSpot(dmd, c, r), legacy, ...
                    'Default multiSpot must be byte-identical to the old circle.');
                testCase.verifyEqual( ...
                    tfp.patterns.multiSpot(dmd, c, r, ...
                        struct('anisotropic', false)), legacy);
            end
        end

        function anisotropic_sample_spot_is_round(testCase)
            % The defining property: map every ON pixel through the handoff
            % §5 coordinate map and the spot must be a DISC in sample um.
            % Derived here from the two axis scales independently of the
            % implementation (which works in px with the ratio).
            dmd = testCase.makeMockDmd();
            model = tfp.util.opticalModel();
            c = [640, 400];
            r = 60;   % groove-axis semi-axis, px

            mask = tfp.patterns.singleSpot(dmd, c, r, ...
                struct('anisotropic', true));

            [cols, rows] = meshgrid(1:dmd.nCols, 1:dmd.nRows);
            dDisp   = ((cols - c(1)) + (rows - c(2))) / sqrt(2);
            dGroove = ((cols - c(1)) - (rows - c(2))) / sqrt(2);
            xDispUm   = dDisp   * model.umPerPixelDispersion;
            yGrooveUm = dGroove * model.umPerPixelGroove;

            rUm = r * model.umPerPixelGroove;         % round-spot radius, um
            dUm = hypot(xDispUm, yGrooveUm);
            expected = dUm <= rUm;

            % Pixels sitting exactly on the boundary can land either way under
            % a different-but-equivalent floating-point grouping; everything
            % else must match exactly.
            offBoundary = abs(dUm - rUm) > 1e-6;
            testCase.verifyEqual(mask(offBoundary), expected(offBoundary), ...
                'Anisotropic mask must be a disc of radius r*umPerPixelGroove at the sample.');
            testCase.verifyLessThanOrEqual(nnz(xor(mask, expected)), nnz(~offBoundary), ...
                'The only permitted disagreements are exact-boundary pixels.');
        end

        function anisotropic_axis_ratio_and_orientation(testCase)
            % (1) the pixel-space ellipse's axis ratio equals model.anisotropy
            % (2) its LONG axis is the (1,-1) groove diagonal, not (1,1)
            dmd = testCase.makeMockDmd();
            model = tfp.util.opticalModel();
            c = [640, 400];
            r = 60;

            mask = tfp.patterns.singleSpot(dmd, c, r, ...
                struct('anisotropic', true));

            [rIdx, cIdx] = find(mask);
            dc = cIdx - c(1);
            dr = rIdx - c(2);
            extDisp   = max(abs((dc + dr) / sqrt(2)));   % along (1, 1)
            extGroove = max(abs((dc - dr) / sqrt(2)));   % along (1,-1)

            testCase.verifyGreaterThan(extGroove, extDisp, ...
                'Long axis must lie along the (1,-1) GROOVE diagonal.');
            testCase.verifyEqual(extGroove / extDisp, model.anisotropy, ...
                'RelTol', 0.02, ...
                'Pixel-space axis ratio must equal the anisotropy (1.2588).');
            testCase.verifyEqual(extGroove, r, 'RelTol', 0.02);
            testCase.verifyEqual(extDisp, r / model.anisotropy, 'RelTol', 0.02);

            % Explicit probe pixels, ~55 px out along each diagonal. Both are
            % inside the r = 60 circle, so a sign error flips exactly these.
            m = 39;                                     % 39*sqrt(2) = 55.2 px
            testCase.verifyTrue(mask(c(2) - m, c(1) + m), ...
                'A point 55 px out along the groove diagonal must be ON.');
            testCase.verifyFalse(mask(c(2) + m, c(1) + m), ...
                'A point 55 px out along the dispersion diagonal must be OFF.');
            % ...but 42 px out along dispersion is still inside.
            n = 30;                                     % 30*sqrt(2) = 42.4 px
            testCase.verifyTrue(mask(c(2) + n, c(1) + n));

            % The ellipse is inscribed in the same-radius circle.
            circle = tfp.patterns.singleSpot(dmd, c, r);
            testCase.verifyEqual(mask & circle, mask, ...
                'The anisotropic ellipse must be a subset of the r-px circle.');
            testCase.verifyLessThan(nnz(mask), nnz(circle));

            % Area matches pi*a*b for the two semi-axes.
            testCase.verifyEqual(nnz(mask), pi * r * (r / model.anisotropy), ...
                'RelTol', 0.05);
        end

        function anisotropic_soma_sized_spot_is_sane(testCase)
            % The real operating point: a ~12.7 um soma is only ~80 DMD px,
            % semi-axes ~5.7 x 4.5. Verify the coarse rasterisation still
            % behaves, and that the SAMPLE spot is near-round (a pixel circle
            % of the same radius would be 26% out).
            dmd = testCase.makeMockDmd();
            model = tfp.util.opticalModel();
            c = [640, 400];
            r = 5.7;

            mask = tfp.patterns.singleSpot(dmd, c, r, ...
                struct('anisotropic', true));

            testCase.verifyEqual(nnz(mask), pi * r * (r / model.anisotropy), ...
                'RelTol', 0.25, ...
                'A soma-sized anisotropic spot should be ~80 DMD pixels.');

            [rIdx, cIdx] = find(mask);
            dc = cIdx - c(1);
            dr = rIdx - c(2);
            extDispUm   = max(abs((dc + dr) / sqrt(2))) * model.umPerPixelDispersion;
            extGrooveUm = max(abs((dc - dr) / sqrt(2))) * model.umPerPixelGroove;
            testCase.verifyEqual(extDispUm, extGrooveUm, 'RelTol', 0.12, ...
                'Sample-plane extents must be near-equal even at soma size.');

            % Contrast: the isotropic circle is elongated at the sample by
            % ~anisotropy along dispersion. This is the bug being fixed.
            circle = tfp.patterns.singleSpot(dmd, c, r);
            [rIdxC, cIdxC] = find(circle);
            dcC = cIdxC - c(1);
            drC = rIdxC - c(2);
            circDispUm   = max(abs((dcC + drC) / sqrt(2))) * model.umPerPixelDispersion;
            circGrooveUm = max(abs((dcC - drC) / sqrt(2))) * model.umPerPixelGroove;
            testCase.verifyGreaterThan(circDispUm / circGrooveUm, 1.15, ...
                'A pixel circle must still be elongated along dispersion at the sample.');
        end

        function anisotropic_dispersionSign_does_not_change_the_spot(testCase)
            % dispersionAxisSign is honoured (it is read and applied), but the
            % ellipse is centrosymmetric and the sign enters only squared, so
            % the mask must be identical for +1 and -1. This pins that a future
            % edit cannot smuggle an orientation change in through the sign.
            dmd = testCase.makeMockDmd();
            c = [640, 400];
            r = 30;

            mPlus  = tfp.util.opticalModel(struct('dispersionAxisSign',  1));
            mMinus = tfp.util.opticalModel(struct('dispersionAxisSign', -1));
            maskPlus = tfp.patterns.singleSpot(dmd, c, r, ...
                struct('anisotropic', true, 'model', mPlus));
            maskMinus = tfp.patterns.singleSpot(dmd, c, r, ...
                struct('anisotropic', true, 'model', mMinus));
            testCase.verifyEqual(maskMinus, maskPlus);

            % A config struct is an accepted alternative to a model struct,
            % and a different anisotropy must actually change the shape.
            maskCfg = tfp.patterns.singleSpot(dmd, c, r, struct( ...
                'anisotropic', true, 'config', ...
                struct('umPerPixelGroove', 1.0, 'umPerPixelDispersion', 2.0)));
            testCase.verifyLessThan(nnz(maskCfg), nnz(maskPlus), ...
                'A larger configured anisotropy must compress the ellipse further.');
        end

        function anisotropic_degenerate_radius_still_lights_a_pixel(testCase)
            % A few-pixel ellipse can fall entirely between sample points. That
            % must not silently produce an all-OFF (skipped) stimulus.
            dmd = testCase.makeMockDmd();
            opts = struct('anisotropic', true);

            % Integer centre: exactly the centre pixel.
            maskInt = tfp.patterns.singleSpot(dmd, [640, 400], 0.2, opts);
            testCase.verifyEqual(nnz(maskInt), 1);
            testCase.verifyTrue(maskInt(400, 640));

            % Sub-pixel offset centre: nothing satisfies the ellipse, so the
            % rounded target pixel is forced ON.
            maskOff = tfp.patterns.singleSpot(dmd, [640.4, 400.6], 0.2, opts);
            testCase.verifyGreaterThanOrEqual(nnz(maskOff), 1, ...
                'A degenerate radius must still command at least one mirror.');
            testCase.verifyTrue(maskOff(401, 640));

            % Same guarantee per target in multiSpot.
            targets = [200.4, 200.6; 800.4, 400.6; 1100.5, 700.5];
            maskMulti = tfp.patterns.multiSpot(dmd, targets, 0.2, opts);
            testCase.verifyGreaterThanOrEqual(nnz(maskMulti), size(targets, 1), ...
                'Every target must contribute at least one ON pixel.');

            % Sweeping radius from degenerate up to soma size, the count never
            % drops to zero and is monotonically non-decreasing.
            counts = arrayfun(@(rr) nnz(tfp.patterns.singleSpot( ...
                dmd, [640.4, 400.6], rr, opts)), 0.1:0.4:6.5);
            testCase.verifyGreaterThanOrEqual(min(counts), 1);
            testCase.verifyGreaterThanOrEqual(min(diff(counts)), 0, ...
                'Spot area must not shrink as the radius grows.');
        end

        function anisotropic_multiSpot_matches_singleSpot_union(testCase)
            % multiSpot carries a verbatim copy of singleSpot's ellipse helper
            % (local functions cannot be shared across files); this locks the
            % two together so they cannot drift.
            dmd = testCase.makeMockDmd();
            opts = struct('anisotropic', true);
            targets = [200, 200; 800, 400; 1100, 700; 640.5, 399.5];

            for r = [5.7, 14, 60]
                mask = tfp.patterns.multiSpot(dmd, targets, r, opts);
                expected = false(dmd.nRows, dmd.nCols);
                for k = 1:size(targets, 1)
                    expected = expected | tfp.patterns.singleSpot( ...
                        dmd, targets(k, :), r, opts);
                end
                testCase.verifyEqual(mask, expected, ...
                    sprintf('multiSpot must equal the singleSpot union (r = %g).', r));
            end

            % And multiSpot's ellipses are likewise a subset of its circles.
            circles = tfp.patterns.multiSpot(dmd, targets, 60);
            ellipses = tfp.patterns.multiSpot(dmd, targets, 60, opts);
            testCase.verifyEqual(ellipses & circles, ellipses);
        end

        function anisotropic_option_validation(testCase)
            dmd = testCase.makeMockDmd();
            c = [640, 400];
            targets = [640, 400; 700, 500];
            r = 14;

            testCase.verifyError( ...
                @() tfp.patterns.singleSpot(dmd, c, r, 5), ...
                'tfp:patterns:singleSpot:badOptions');
            testCase.verifyError( ...
                @() tfp.patterns.singleSpot(dmd, c, r, struct('anisotropic', 'yes')), ...
                'tfp:patterns:singleSpot:badAnisotropic');
            testCase.verifyError( ...
                @() tfp.patterns.singleSpot(dmd, c, r, ...
                    struct('anisotropic', true, 'model', struct('foo', 1))), ...
                'tfp:patterns:singleSpot:badModel');

            testCase.verifyError( ...
                @() tfp.patterns.multiSpot(dmd, targets, r, 5), ...
                'tfp:patterns:multiSpot:badOptions');
            testCase.verifyError( ...
                @() tfp.patterns.multiSpot(dmd, targets, r, struct('anisotropic', 'yes')), ...
                'tfp:patterns:multiSpot:badAnisotropic');
            testCase.verifyError( ...
                @() tfp.patterns.multiSpot(dmd, targets, r, ...
                    struct('anisotropic', true, 'model', struct('foo', 1))), ...
                'tfp:patterns:multiSpot:badModel');

            % Options must not disturb the existing argument checks.
            testCase.verifyError( ...
                @() tfp.patterns.singleSpot(dmd, c, -1, struct('anisotropic', true)), ...
                'tfp:patterns:singleSpot:badRadius');
            testCase.verifyEqual( ...
                tfp.patterns.multiSpot(dmd, zeros(0, 2), r, ...
                    struct('anisotropic', true)), ...
                false(dmd.nRows, dmd.nCols), ...
                'An empty target list must still give an all-OFF mask.');
        end
    end
end
