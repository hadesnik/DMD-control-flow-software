classdef test_assign_frame_planes < matlab.unittest.TestCase
    %test_assign_frame_planes The frame->plane interleave formula, its
    %   volume anchor, and the dropped-frame gap handling.

    methods (Test)

        function plainModularAssignment(testCase)
            p = tfp.io.assignFramePlanes(1:7, 3);
            testCase.verifyEqual(p, [1 2 3 1 2 3 1]);

            % Volume anchor: frame 3 begins plane 1.
            p = tfp.io.assignFramePlanes(3:8, 3, ...
                struct('volumeStartFrame', 3));
            testCase.verifyEqual(p, [1 2 3 1 2 3]);
        end

        function clockModeCleanTrain(testCase)
            samples = 1000:100:1900;   % 10 evenly spaced edges
            [p, rep] = tfp.io.assignFramePlanes(samples, 3, ...
                struct('fromClockSamples', true));
            testCase.verifyEqual(p, [1 2 3 1 2 3 1 2 3 1]);
            testCase.verifyTrue(all(rep.confidence == "exact"));
            testCase.verifyEqual(rep.nGaps, 0);
        end

        function droppedFrameIsCorrectedThrough(testCase)
            % Edge train missing exactly one frame between edges 4 and 5:
            % without correction every later plane tag would shift by one.
            samples = [1000 1100 1200 1300 1500 1600 1700];
            [p, rep] = tfp.io.assignFramePlanes(samples, 3, ...
                struct('fromClockSamples', true));
            % Frames 1..4 exact: planes 1 2 3 1. The missing frame WAS
            % plane 2, so the recorded 5th edge is plane 3, not 2.
            testCase.verifyEqual(p(1:4), [1 2 3 1]);
            testCase.verifyEqual(p(5:7), [3 1 2]);
            testCase.verifyEqual(rep.nGaps, 1);
            testCase.verifyEqual(rep.firstGapFrame, 5);
            testCase.verifyTrue(all(rep.confidence(1:4) == "exact"));
            testCase.verifyTrue(all(rep.confidence(5:7) == "corrected"));
        end

        function nonIntegerGapQuarantines(testCase)
            % A gap of 1.6 frame intervals cannot be a whole number of
            % dropped frames — the record is suspect from there on.
            samples = [1000 1100 1200 1360 1460 1560];
            [~, rep] = tfp.io.assignFramePlanes(samples, 3, ...
                struct('fromClockSamples', true));
            testCase.verifyTrue(all(rep.confidence(4:end) == "quarantined"));
            testCase.verifyTrue(all(rep.confidence(1:3) == "exact"));
        end

        function badNPlanes(testCase)
            testCase.verifyError(@() tfp.io.assignFramePlanes(1:5, 0), ...
                'tfp:io:assignFramePlanes:badNPlanes');
        end
    end
end
