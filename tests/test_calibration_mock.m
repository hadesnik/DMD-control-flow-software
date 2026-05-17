classdef test_calibration_mock < matlab.unittest.TestCase
    %test_calibration_mock Phase 1 calibration round-trip test.
    %   Placeholder: the tfp.calibration package is Phase 2/3 work and
    %   is not yet scaffolded. This file exists so the test plan is
    %   complete; the single method below will be wired up when
    %   alignDMDtoCamera/measurePSF/powerMeterSweep land.

    methods (Test)
        function fakeAffineRoundTrip(testCase)
            %TODO Fake affine, verify round-trip. Requires tfp.calibration (Phase 2/3, not yet scaffolded).
            testCase.verifyFail('stub - not implemented; tfp.calibration not yet scaffolded');
        end
    end
end
