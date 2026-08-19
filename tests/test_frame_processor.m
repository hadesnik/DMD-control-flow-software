classdef test_frame_processor < matlab.unittest.TestCase
    %test_frame_processor tfp.gui.FrameProcessor — the live-display image math.
    %
    %   All of it is static and graphics-free, which is the point: the display
    %   pipeline is fully tested under -nodisplay even though
    %   tfp.gui.CalibrationApp can never be constructed there.
    %
    %   Methods:
    %     averagesAStack / rejectsEmptyStack
    %     darkSubtractionClampsAtZero — negative pixels drag centroids inward.
    %     darkSizeMismatchThrows
    %     percentilesWithoutStatsToolbox — pinned against known quantiles.
    %     autoscaleIgnoresHotPixels — the reason the top limit is not 100%.
    %     saturationMaskCountsClippedPixels
    %     histogramBinsAndCounts
    %     lineProfileLengthAndValues
    %     gaussianSigmaRecoversAKnownWidth
    %     focusMetricIsExposureInvariant — so the number moves for the right
    %                                      reason when the operator focuses.

    methods (Test)

        function averagesAStack(testCase)
            stack = cat(3, ones(4), 3 * ones(4));
            testCase.verifyEqual(tfp.gui.FrameProcessor.averageFrames(stack), ...
                2 * ones(4));
        end

        function rejectsEmptyStack(testCase)
            testCase.verifyError(@() tfp.gui.FrameProcessor.averageFrames([]), ...
                'tfp:gui:FrameProcessor:emptyStack');
        end

        function darkSubtractionClampsAtZero(testCase)
            frame = [0.1 0.5; 0.9 0.2];
            dark  = [0.3 0.1; 0.1 0.3];
            out   = tfp.gui.FrameProcessor.subtractDark(frame, dark);
            testCase.verifyEqual(out, [0 0.4; 0.8 0], 'AbsTol', 1e-12);
            testCase.verifyGreaterThanOrEqual(min(out(:)), 0);
        end

        function darkSizeMismatchThrows(testCase)
            testCase.verifyError(@() tfp.gui.FrameProcessor.subtractDark( ...
                zeros(4), zeros(3)), 'tfp:gui:FrameProcessor:darkSizeMismatch');
        end

        function percentilesWithoutStatsToolbox(testCase)
            v = 1:100;
            q = tfp.gui.FrameProcessor.percentile(v, [0 50 100]);
            testCase.verifyEqual(q(1), 1,   'AbsTol', 1e-9);
            testCase.verifyEqual(q(2), 50.5, 'AbsTol', 1e-9);
            testCase.verifyEqual(q(3), 100, 'AbsTol', 1e-9);
            testCase.verifySize(tfp.gui.FrameProcessor.percentile(v, [1 2 3]), [1 3]);
        end

        function autoscaleIgnoresHotPixels(testCase)
            % A handful of hot pixels must not set the display ceiling, which
            % is exactly what a plain max() would do — and would black out the
            % dim spot the operator is trying to see.
            frame = 0.2 * ones(100, 100);
            frame(1:5) = 1000;
            lims = tfp.gui.FrameProcessor.autoscaleLimits(frame, [0.5 99.9]);
            testCase.verifyLessThan(lims(2), 1000);
            testCase.verifyGreaterThan(lims(2), 0.1);
        end

        function autoscaleHandlesFlatFrame(testCase)
            lims = tfp.gui.FrameProcessor.autoscaleLimits(0.5 * ones(8));
            testCase.verifyGreaterThan(lims(2), lims(1), ...
                'limits must never collapse to a zero-width range');
        end

        function saturationMaskCountsClippedPixels(testCase)
            frame = zeros(10, 10);
            frame(1:7) = 1.0;
            [mask, frac] = tfp.gui.FrameProcessor.saturationMask(frame);
            testCase.verifyEqual(nnz(mask), 7);
            testCase.verifyEqual(frac, 0.07, 'AbsTol', 1e-12);
        end

        function histogramBinsAndCounts(testCase)
            frame = repmat(linspace(0, 1, 100), 10, 1);
            [counts, centres] = tfp.gui.FrameProcessor.histogramCounts(frame, 10);
            testCase.verifyNumElements(counts,  10);
            testCase.verifyNumElements(centres, 10);
            testCase.verifyEqual(sum(counts), numel(frame));
        end

        function lineProfileLengthAndValues(testCase)
            frame = repmat(1:10, 10, 1);         % ramps along x
            [p, d] = tfp.gui.FrameProcessor.lineProfile(frame, [1 5], [10 5], 10);
            testCase.verifyNumElements(p, 10);
            testCase.verifyEqual(p, 1:10, 'AbsTol', 1e-9);
            testCase.verifyEqual(d(end), 9, 'AbsTol', 1e-9);
        end

        function gaussianSigmaRecoversAKnownWidth(testCase)
            x     = -50:50;
            sigma = 6.5;
            prof  = exp(-x.^2 / (2 * sigma^2));
            [s, c] = tfp.gui.FrameProcessor.gaussianSigma(prof, x);
            testCase.verifyEqual(s, sigma, 'RelTol', 0.05);
            testCase.verifyEqual(c, 0, 'AbsTol', 0.2);
        end

        function gaussianSigmaHandlesFlatInput(testCase)
            [s, ~, ~] = tfp.gui.FrameProcessor.gaussianSigma(ones(1, 20));
            testCase.verifyTrue(isnan(s), ...
                'a flat profile has no meaningful width; NaN, not zero');
        end

        function focusMetricIsExposureInvariant(testCase)
            frame  = rand(64) + 0.5;
            m1 = tfp.gui.FrameProcessor.focusMetric(frame);
            m2 = tfp.gui.FrameProcessor.focusMetric(frame * 3);
            testCase.verifyEqual(m2, m1, 'RelTol', 1e-9, ...
                'normalised variance must not move when only exposure changes');
        end

        function focusMetricRewardsSharpness(testCase)
            [xx, yy] = meshgrid(-32:31, -32:31);
            sharp = exp(-(xx.^2 + yy.^2) / (2 * 3^2))  + 0.01;
            blur  = exp(-(xx.^2 + yy.^2) / (2 * 12^2)) + 0.01;
            testCase.verifyGreaterThan( ...
                tfp.gui.FrameProcessor.focusMetric(sharp), ...
                tfp.gui.FrameProcessor.focusMetric(blur));
        end
    end
end
