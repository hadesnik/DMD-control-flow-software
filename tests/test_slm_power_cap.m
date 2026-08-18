classdef test_slm_power_cap < matlab.unittest.TestCase
    %test_slm_power_cap tfp.util.assertSlmPowerSafe — the §7b LC alignment
    %   cap, live. Requires Image Processing Toolbox (bwconncomp).

    methods (Access = private)
        function config = slmOnConfig(~)
            config.slm = struct('enabled', true, 'uniform_blob_fraction', 0.02);
        end
    end

    methods (Test)

        function sparsePatternPassesAtHighPower(testCase)
            % Many small spots: each blob far below the blob-fraction
            % limit, so full power is allowed (handoff §7b: sparse is
            % benign).
            frame = false(200, 200);
            for cx = 20:40:180
                for cy = 20:40:180
                    frame(cy-2:cy+2, cx-2:cx+2) = true;
                end
            end
            tfp.util.assertSlmPowerSafe(frame, 5000, testCase.slmOnConfig());
            testCase.verifyTrue(true);   % no throw = pass
        end

        function uniformBlobAtHighPowerThrows(testCase)
            frame = false(200, 200);
            frame(50:150, 50:150) = true;   % one blob, 25% of chip
            caps = tfp.util.readHandoffConstants();
            testCase.verifyError(@() tfp.util.assertSlmPowerSafe( ...
                frame, caps.slm_alignment_cap_mW + 1, testCase.slmOnConfig()), ...
                'tfp:util:assertSlmPowerSafe:slmAlignmentCapExceeded');
        end

        function uniformBlobUnderCapPasses(testCase)
            frame = false(200, 200);
            frame(50:150, 50:150) = true;
            caps = tfp.util.readHandoffConstants();
            tfp.util.assertSlmPowerSafe(frame, caps.slm_alignment_cap_mW - 1, ...
                testCase.slmOnConfig());
            testCase.verifyTrue(true);
        end

        function slmDisabledSkipsCheck(testCase)
            frame = true(200, 200);
            config.slm = struct('enabled', false);
            tfp.util.assertSlmPowerSafe(frame, 40000, config);
            tfp.util.assertSlmPowerSafe(frame, 40000, struct());   % no slm section
            testCase.verifyTrue(true);
        end

        function unknownPowerPasses(testCase)
            frame = true(200, 200);
            tfp.util.assertSlmPowerSafe(frame, [], testCase.slmOnConfig());
            tfp.util.assertSlmPowerSafe(frame, NaN, testCase.slmOnConfig());
            testCase.verifyTrue(true);
        end

        function checksEveryFrameInStack(testCase)
            frames = false(200, 200, 3);
            frames(90:110, 90:110, 1) = true;          % small blob: fine
            frames(30:180, 30:180, 3) = true;          % big blob in frame 3
            caps = tfp.util.readHandoffConstants();
            testCase.verifyError(@() tfp.util.assertSlmPowerSafe( ...
                frames, caps.slm_alignment_cap_mW * 2, testCase.slmOnConfig()), ...
                'tfp:util:assertSlmPowerSafe:slmAlignmentCapExceeded');
        end
    end
end
