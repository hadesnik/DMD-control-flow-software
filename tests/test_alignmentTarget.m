classdef test_alignmentTarget < matlab.unittest.TestCase
    %test_alignmentTarget The patch-confined downstream-alignment target.

    methods (Access = private)
        function dmd = bareDmd(~)
            % +patterns convention: any struct with nRows/nCols works.
            dmd = struct('nRows', 800, 'nCols', 1280);
        end
    end

    methods (Test)

        function shapeTypeAndDefaultPatch(testCase)
            dmd  = testCase.bareDmd();
            mask = tfp.patterns.alignmentTarget(dmd);
            testCase.verifyClass(mask, 'logical');
            testCase.verifySize(mask, [800, 1280]);

            % Default patch diameter comes from the handoff at runtime.
            c = tfp.util.readHandoffConstants();
            R = c.patch_diameter_px / 2;

            % Nothing outside the patch disc (ring outer edge + rounding).
            [rr, cc] = find(mask);
            cx = (1280 + 1) / 2; cy = (800 + 1) / 2;
            rOn = sqrt((cc - cx).^2 + (rr - cy).^2);
            testCase.verifyLessThanOrEqual(max(rOn), R + 3.5, ...
                'alignment target leaks beyond the design patch disc');
        end

        function ringCrossAndTicksPresent(testCase)
            dmd  = testCase.bareDmd();
            mask = tfp.patterns.alignmentTarget(dmd);
            c  = tfp.util.readHandoffConstants();
            R  = c.patch_diameter_px / 2;
            cx = round((1280 + 1) / 2); cy = round((800 + 1) / 2);

            % Ring: ON at patch radius along the chip axes.
            testCase.verifyTrue(mask(cy, cx + round(R)), 'ring missing (+x)');
            testCase.verifyTrue(mask(cy, cx - round(R)), 'ring missing (-x)');
            testCase.verifyTrue(mask(cy + round(R), cx), 'ring missing (+y)');

            % Cross: ON at centre and along both arms; OFF beyond arm length.
            testCase.verifyTrue(mask(cy, cx));
            testCase.verifyTrue(mask(cy, cx + 40));
            testCase.verifyTrue(mask(cy + 40, cx));
            testCase.verifyFalse(mask(cy, cx + 100), ...
                'cross arm longer than crossHalfPx');

            % Dispersion ticks (long, along +col+row diagonal), sitting just
            % inside the ring: probe at |u| = R - ringW - 20 on the diagonal.
            d = (R - 5 - 20) / sqrt(2);
            testCase.verifyTrue(mask(cy + round(d), cx + round(d)), ...
                'dispersion tick missing');
            % Groove diagonal at the same radius is OUTSIDE the short groove
            % tick (length 20 ends at inner-3): probe deeper where only the
            % long dispersion tick reaches.
            dFar = (R - 5 - 35) / sqrt(2);
            testCase.verifyTrue(mask(cy + round(dFar), cx + round(dFar)), ...
                'dispersion tick shorter than spec');
            testCase.verifyFalse(mask(cy - round(dFar), cx + round(dFar)), ...
                'groove tick should be shorter than dispersion tick');
        end

        function safeByConstruction(testCase)
            dmd  = testCase.bareDmd();
            mask = tfp.patterns.alignmentTarget(dmd);

            % Far under the 50% ON-fraction cap.
            onFrac = nnz(mask) / numel(mask);
            testCase.verifyLessThan(onFrac, 0.05);

            % Largest contiguous blob (the ring) stays under the SLM
            % near-uniform discriminator, so the LC power cap passes
            % honestly at any power.
            config.slm = struct('enabled', true, 'uniform_blob_fraction', 0.02);
            tfp.util.assertSlmPowerSafe(mask, 1000, config);   % no throw
            testCase.verifyTrue(true);

            % And a MockDMD load runs the real on-fraction assert.
            mock = tfp.hardware.MockDMD();
            mock.initialize(struct('nRows', 800, 'nCols', 1280, ...
                'loadLatencyMsPerPattern', 0));
            mock.loadPatternSequence(mask, struct('exposureUs', 1000, ...
                'darkTimeUs', 0));
            testCase.verifyTrue(true);
        end

        function optionsOverride(testCase)
            dmd  = testCase.bareDmd();
            mask = tfp.patterns.alignmentTarget(dmd, ...
                struct('patchDiameterPx', 200, 'crossHalfPx', 30));
            [rr, cc] = find(mask);
            cx = (1280 + 1) / 2; cy = (800 + 1) / 2;
            rOn = sqrt((cc - cx).^2 + (rr - cy).^2);
            testCase.verifyLessThanOrEqual(max(rOn), 100 + 3.5);

            % Degenerate / oversized patches refuse.
            testCase.verifyError(@() tfp.patterns.alignmentTarget(dmd, ...
                struct('patchDiameterPx', 900)), ...
                'tfp:patterns:alignmentTarget:badPatch');
        end
    end
end
