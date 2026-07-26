classdef test_somaSpotGeometry < matlab.unittest.TestCase
    %test_somaSpotGeometry Soma-sized spot geometry (TASK-BU T-BU-1e).
    %
    %   Pins the "a soma is ~80 DMD pixels, not ~900" corollary of the
    %   corrected optical model (TASKS.md TASK-BU, docs/dmd_control_handoff.md
    %   §5). The numbers matter twice over: they set the physical spot size
    %   (single-cell resolution is the central claim of the hero figure) and
    %   they set the per-neuron power resolution available to
    %   tfp.patterns.fillFactorEnsemble.
    %
    %   Reference values, from R/umPerPixel with the design constants
    %   (1.1250 um/px groove, 1.4162 um/px dispersion):
    %
    %     diameter | semi-axes (groove x disp) | pixels
    %      10.0 um |  4.44 x 3.53             |  ~47
    %      12.7 um |  5.64 x 4.48             |  ~81
    %      15.0 um |  6.67 x 5.30             | ~111

    properties (Constant)
        SomaDiameterUm = 12.7;
    end

    methods (Test)

        % --- The headline claim -----------------------------------------

        function somaIsAboutEightyPixelsAndEightyPowerLevels(tc)
            geom = tfp.patterns.somaSpotGeometry();
            tc.verifyEqual(geom.diameterUm, tc.SomaDiameterUm, ...
                'Default diameter should be the soma-sized 12.7 um.');
            tc.verifyGreaterThanOrEqual(geom.nPixels, 70);
            tc.verifyLessThanOrEqual(geom.nPixels, 92, ...
                'A soma-sized spot must be ~80 DMD pixels, not ~900.');
            tc.verifyEqual(geom.nPowerLevels, geom.nPixels, ...
                'Power levels are exactly the pixels in the spot.');
            tc.verifyEqual(geom.powerStepPct, 100 / geom.nPixels, ...
                'AbsTol', 1e-12);
            tc.verifyLessThan(geom.powerStepPct, 2, ...
                'Finest power step should be ~1.25%, comfortably under 2%.');
            tc.verifyEqual(geom.minFillFractionStep, 1 / geom.nPixels, ...
                'AbsTol', 1e-12);
        end

        function pixelCountIsNowherNearTheNineHundredPilotAssumption(tc)
            % The pilot's ~900-px spot corresponds to radiusPx ~ 17, which at
            % the real scale is a ~38 x 48 um patch covering several cells.
            geom = tfp.patterns.somaSpotGeometry();
            tc.verifyLessThan(geom.nPixels, 200, ...
                ['If this ever returns ~900 again, the optical constants ' ...
                 'have regressed to the pre-optics 0.270 um/px guess.']);
        end

        % --- Semi-axes ---------------------------------------------------

        function semiAxesMatchHandoffArithmetic(tc)
            geom = tfp.patterns.somaSpotGeometry(tc.SomaDiameterUm);
            tc.verifyEqual(geom.semiAxisGroovePx,     5.6444, 'AbsTol', 0.01);
            tc.verifyEqual(geom.semiAxisDispersionPx, 4.4838, 'AbsTol', 0.01);
            tc.verifyEqual(geom.semiAxesPx, ...
                [geom.semiAxisGroovePx, geom.semiAxisDispersionPx], ...
                'AbsTol', 1e-12);
        end

        function grooveAxisIsTheLongerOne(tc)
            % The groove axis is more finely sampled (1.1250 < 1.4162 um/px),
            % so spanning the same micron distance takes MORE pixels there.
            geom = tfp.patterns.somaSpotGeometry();
            tc.verifyGreaterThan(geom.semiAxisGroovePx, geom.semiAxisDispersionPx);
            tc.verifyEqual(geom.semiAxisGroovePx / geom.semiAxisDispersionPx, ...
                geom.anisotropy, 'AbsTol', 1e-12, ...
                'Semi-axis ratio must be exactly the model anisotropy.');
        end

        function referenceTableHolds(tc)
            expected = { ...
                10.0,  4.4444, 3.5306,  47; ...
                12.7,  5.6444, 4.4838,  81; ...
                15.0,  6.6667, 5.2959, 111};
            for k = 1:size(expected, 1)
                geom = tfp.patterns.somaSpotGeometry(expected{k, 1});
                tc.verifyEqual(geom.semiAxisGroovePx, expected{k, 2}, ...
                    'AbsTol', 0.01, sprintf('groove semi-axis at %g um', expected{k,1}));
                tc.verifyEqual(geom.semiAxisDispersionPx, expected{k, 3}, ...
                    'AbsTol', 0.01, sprintf('dispersion semi-axis at %g um', expected{k,1}));
                tc.verifyEqual(geom.nPixels, expected{k, 4}, 'AbsTol', 3, ...
                    sprintf('pixel count at %g um', expected{k, 1}));
            end
        end

        function pixelCountGrowsMonotonicallyWithDiameter(tc)
            diameters = [6 8 10 12.7 15 20 30];
            counts = zeros(size(diameters));
            for k = 1:numel(diameters)
                g = tfp.patterns.somaSpotGeometry(diameters(k));
                counts(k) = g.nPixels;
            end
            tc.verifyTrue(all(diff(counts) > 0), ...
                'Pixel count must increase with requested diameter.');
        end

        % --- Constants come from opticalModel, not from literals ---------

        function constantsAreReadFromTheOpticalModel(tc)
            % Doubling both um/px scales must halve both semi-axes. If the
            % function hardcoded 1.1250 / 1.4162 this fails.
            cfg = struct('dmd', struct( ...
                'umPerPixelGroove',     2.2500, ...
                'umPerPixelDispersion', 2.8324));
            ref = tfp.patterns.somaSpotGeometry(tc.SomaDiameterUm);
            alt = tfp.patterns.somaSpotGeometry(tc.SomaDiameterUm, cfg);
            tc.verifyEqual(alt.semiAxisGroovePx, ref.semiAxisGroovePx / 2, ...
                'AbsTol', 1e-9);
            tc.verifyEqual(alt.semiAxisDispersionPx, ...
                ref.semiAxisDispersionPx / 2, 'AbsTol', 1e-9);
            tc.verifyLessThan(alt.nPixels, ref.nPixels);
            tc.verifyEqual(alt.umPerPixelGroove, 2.2500, 'AbsTol', 1e-12);
        end

        function acceptsABareDmdSubStruct(tc)
            % opticalModel takes either a full config or a bare field struct;
            % callers holding only the dmd block must not have to re-wrap it.
            bare = struct('umPerPixelGroove', 2.2500, ...
                          'umPerPixelDispersion', 2.8324);
            wrapped = tfp.patterns.somaSpotGeometry(tc.SomaDiameterUm, ...
                struct('dmd', bare));
            direct  = tfp.patterns.somaSpotGeometry(tc.SomaDiameterUm, bare);
            tc.verifyEqual(direct.semiAxesPx, wrapped.semiAxesPx, 'AbsTol', 1e-12);
        end

        function echoedConstantsMatchTheModel(tc)
            geom  = tfp.patterns.somaSpotGeometry();
            model = tfp.util.opticalModel();
            tc.verifyEqual(geom.umPerPixelGroove,     model.umPerPixelGroove);
            tc.verifyEqual(geom.umPerPixelDispersion, model.umPerPixelDispersion);
            tc.verifyEqual(geom.anisotropy,           model.anisotropy);
            tc.verifyEqual(geom.clockingDeg,          model.clockingDeg);
            tc.verifyEqual(geom.model.patchRadiusPx,  model.patchRadiusPx);
        end

        % --- Area, rasterization, and the mask ---------------------------

        function analyticAreaMatchesPiRSquaredOverTheScaleProduct(tc)
            geom = tfp.patterns.somaSpotGeometry();
            R = geom.radiusUm;
            expectedArea = pi * R^2 / ...
                (geom.umPerPixelGroove * geom.umPerPixelDispersion);
            tc.verifyEqual(geom.areaPx, expectedArea, 'RelTol', 1e-12);
            % 1.5932 is the scale product quoted in TASKS.md.
            tc.verifyEqual(geom.umPerPixelGroove * geom.umPerPixelDispersion, ...
                1.5932, 'AbsTol', 1e-3);
        end

        function rasterizedCountIsCloseToButNotEqualToTheAnalyticArea(tc)
            % The whole point of counting pixels: at ~80 px the raster and the
            % analytic area differ, and the raster is what the mirrors do.
            geom = tfp.patterns.somaSpotGeometry();
            tc.verifyEqual(double(geom.nPixels), geom.areaPx, 'RelTol', 0.10, ...
                'Rasterized count should track the analytic area to ~10%.');
            tc.verifyClass(geom.nPixels, 'double');
        end

        function maskAndOffsetsAgree(tc)
            geom = tfp.patterns.somaSpotGeometry();
            tc.verifyEqual(nnz(geom.localMask), geom.nPixels);
            tc.verifyEqual(size(geom.offsetsPx, 1), geom.nPixels);
            tc.verifyEqual(size(geom.offsetsPx, 2), 2);
            tc.verifyClass(geom.localMask, 'logical');
            % The centre pixel is always ON, and the mask is centrosymmetric.
            tc.verifyTrue(any(all(geom.offsetsPx == 0, 2)), ...
                'The spot centre must be an ON pixel.');
            tc.verifyEqual(geom.localMask, rot90(geom.localMask, 2), ...
                'A centred ellipse must be symmetric under 180 deg rotation.');
        end

        function maskIsElongatedAlongTheGrooveDiagonal(tc)
            % The chip is clocked 45 deg, so the ellipse axes are the pixel
            % DIAGONALS: the mask must reach further along (1,-1) than (1,1).
            geom = tfp.patterns.somaSpotGeometry();
            dCol = geom.offsetsPx(:, 1);
            dRow = geom.offsetsPx(:, 2);
            grooveExtent = max(abs(dCol - dRow)) / sqrt(2);
            dispExtent   = max(abs(dCol + dRow)) / sqrt(2);
            tc.verifyGreaterThan(grooveExtent, dispExtent, ...
                ['The DMD ellipse must be longer along the groove diagonal ' ...
                 'so the SAMPLE spot comes out round.']);
        end

        function everyOnPixelSatisfiesTheEllipseInequality(tc)
            geom = tfp.patterns.somaSpotGeometry(15);
            dCol = geom.offsetsPx(:, 1);
            dRow = geom.offsetsPx(:, 2);
            dDisp   = (dCol + dRow) / sqrt(2);
            dGroove = (dCol - dRow) / sqrt(2);
            r2 = (dGroove / geom.semiAxisGroovePx).^2 + ...
                 (dDisp   / geom.semiAxisDispersionPx).^2;
            tc.verifyLessThanOrEqual(max(r2), 1 + 1e-12);
        end

        % --- Isotropic fallback ------------------------------------------

        function isotropicFallbackIsAreaMatchedAndBetweenTheSemiAxes(tc)
            geom = tfp.patterns.somaSpotGeometry();
            tc.verifyEqual(pi * geom.radiusPx^2, geom.areaPx, 'RelTol', 1e-12, ...
                'The scalar fallback radius must preserve the pixel budget.');
            tc.verifyGreaterThan(geom.radiusPx, geom.semiAxisDispersionPx);
            tc.verifyLessThan(geom.radiusPx,    geom.semiAxisGroovePx);
        end

        function isotropicFallbackReportsItsOwnDistortion(tc)
            geom = tfp.patterns.somaSpotGeometry();
            tc.verifyEqual(numel(geom.isotropicExtentUm), 2);
            ratio = geom.isotropicExtentUm(2) / geom.isotropicExtentUm(1);
            tc.verifyEqual(ratio, geom.anisotropy, 'AbsTol', 1e-12, ...
                'A pixel circle lands 1.2588x longer along the dispersion axis.');
            % The area-matched circle straddles the requested diameter.
            tc.verifyLessThan(geom.isotropicExtentUm(1), geom.diameterUm);
            tc.verifyGreaterThan(geom.isotropicExtentUm(2), geom.diameterUm);
        end

        function isotropicFallbackGivesTheSamePowerBudgetAsTheEllipse(tc)
            % A circle-only call site (e.g. fillFactorEnsemble today) still
            % gets ~80 pixels, hence ~80 power levels.
            geom = tfp.patterns.somaSpotGeometry();
            r = geom.radiusPx;
            span = -ceil(r) - 1 : ceil(r) + 1;
            [dc, dr] = meshgrid(span, span);
            nCircle = nnz(dc.^2 + dr.^2 <= r^2);
            tc.verifyEqual(nCircle, geom.nPixels, 'AbsTol', 5, ...
                'Fallback circle and the true ellipse must agree on pixel count.');
        end

        % --- Hand-off struct ---------------------------------------------

        function spotOptionsCarriesWhatPatternBuildersNeed(tc)
            geom = tfp.patterns.somaSpotGeometry();
            opts = geom.spotOptions;
            tc.verifyClass(opts, 'struct');
            tc.verifyTrue(opts.anisotropic);
            tc.verifyEqual(opts.semiAxisGroovePx,     geom.semiAxisGroovePx);
            tc.verifyEqual(opts.semiAxisDispersionPx, geom.semiAxisDispersionPx);
            tc.verifyEqual(opts.radiusPx,             geom.radiusPx);
            tc.verifyEqual(opts.anisotropy,           geom.anisotropy);
            tc.verifyEqual(opts.clockingDeg,          geom.clockingDeg);
        end

        function descriptionMentionsTheSizeAndTheLevels(tc)
            geom = tfp.patterns.somaSpotGeometry();
            tc.verifyClass(geom.description, 'char');
            tc.verifySubstring(geom.description, 'power levels');
            tc.verifySubstring(geom.description, '12.7');
        end

        % --- Defaults and validation -------------------------------------

        function emptyDiameterUsesTheSomaDefault(tc)
            tc.verifyEqual(tfp.patterns.somaSpotGeometry([]).diameterUm, ...
                tc.SomaDiameterUm);
            tc.verifyEqual(tfp.patterns.somaSpotGeometry().nPixels, ...
                tfp.patterns.somaSpotGeometry(tc.SomaDiameterUm).nPixels);
        end

        function rejectsNonPositiveOrNonScalarDiameters(tc)
            bad = {0, -5, [10 12], NaN, Inf, 'soma', {12.7}};
            for k = 1:numel(bad)
                tc.verifyError(@() tfp.patterns.somaSpotGeometry(bad{k}), ...
                    'tfp:patterns:somaSpotGeometry:badDiameter', ...
                    sprintf('Input %d should have been rejected.', k));
            end
        end

        function badConfigPropagatesTheOpticalModelError(tc)
            tc.verifyError(@() tfp.patterns.somaSpotGeometry(12.7, 42), ...
                'tfp:util:opticalModel:badConfig');
        end

        % --- Advisories ---------------------------------------------------

        function warnsBelowTheRasterizationFloor(tc)
            % 1.5 um diameter -> semi-axes 0.67 x 0.53 px: a few mirrors.
            % measurePSF legitimately lands here, so it is a warning.
            tc.verifyWarning(@() tfp.patterns.somaSpotGeometry(1.5), ...
                'tfp:patterns:somaSpotGeometry:belowRasterFloor');
        end

        function warnsWhenTheSpotExceedsTheIlluminatedPatch(tc)
            % Patch radius is 278 px; a 1 mm spot needs a 444 px semi-axis.
            tc.verifyWarning(@() tfp.patterns.somaSpotGeometry(1000), ...
                'tfp:patterns:somaSpotGeometry:largerThanPatch');
        end

        function ordinaryCellSizedRequestsAreWarningFree(tc)
            for d = [8 10 12.7 15 20]
                tc.verifyWarningFree(@() tfp.patterns.somaSpotGeometry(d), ...
                    sprintf('%g um should be an unremarkable request.', d));
            end
        end

    end
end
