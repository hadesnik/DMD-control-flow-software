classdef test_alignTrialsToFrames < matlab.unittest.TestCase
    %test_alignTrialsToFrames Unit tests for tfp.io.alignTrialsToFrames.
    %   Covers the T-SYNC-5 contract documented in docs/SYNC_FRAME.md §6.2.

    properties (Constant)
        SR = 100000;                  % 100 kHz master clock
    end

    methods (Access = private)
        function tr = makeTrial(testCase, idx, onsetSample, offsetSample, preStim_s)
            tr             = tfp.trial.Trial();
            tr.trialIdx    = idx;
            tr.preStim_s   = preStim_s;
            tr.markRunning(uint64(onsetSample), testCase.SR, datetime(2026,1,1));
            tr.markComplete([], uint64(offsetSample));
        end
    end

    methods (Test)
        function emptyTrials_returnsEmptyPerTrial(testCase)
            frames = uint64([100; 200; 300]);
            [perTrial, perFrame] = tfp.io.alignTrialsToFrames( ...
                tfp.trial.Trial.empty, frames);

            testCase.verifyEqual(numel(perTrial), 0);
            testCase.verifyEqual(height(perFrame), 3);
            testCase.verifyTrue(all(isnan(perFrame.trialIdx)));
            testCase.verifyTrue(all(perFrame.phase == "none"));
            testCase.verifyEqual(perFrame.frameStartSample, frames);
            testCase.verifyEqual(perFrame.frameIdx, uint64((1:3).'));
        end

        function emptyFrames_returnsEmptyPerFrame(testCase)
            tr = testCase.makeTrial(1, 1000, 2000, 0.05);
            [perTrial, perFrame] = tfp.io.alignTrialsToFrames(tr, uint64.empty);

            testCase.verifyEqual(numel(perTrial), 1);
            testCase.verifyEqual(perTrial(1).trialIdx, 1);
            testCase.verifyEqual(perTrial(1).frame_indices_during_stim, uint64.empty(1,0));
            testCase.verifyEqual(perTrial(1).frame_indices_baseline,    uint64.empty(1,0));
            testCase.verifyEqual(height(perFrame), 0);
        end

        function basicAssignment_singleTrial(testCase)
            % 100 kHz clock, preStim=0.05s -> 5000 samples baseline
            % Trial 1: onset=10000, offset=20000.
            % Baseline window [5000, 10000); stim window [10000, 20000].
            tr = testCase.makeTrial(7, 10000, 20000, 0.05);

            frames = uint64([1000; 6000; 9999; 10000; 15000; 20000; 25000]);
            [perTrial, perFrame] = tfp.io.alignTrialsToFrames(tr, frames);

            testCase.verifyEqual(perTrial(1).trialIdx, 7);
            % Baseline: frames 2 (6000) and 3 (9999).
            testCase.verifyEqual(perTrial(1).frame_indices_baseline, uint64([2 3]));
            % Stim: frames 4 (10000), 5 (15000), 6 (20000) -- inclusive ends.
            testCase.verifyEqual(perTrial(1).frame_indices_during_stim, uint64([4 5 6]));

            testCase.verifyEqual(perFrame.phase, [ ...
                "none"; "baseline"; "baseline"; "stim"; "stim"; "stim"; "none"]);
            expectedTidx = [NaN; 7; 7; 7; 7; 7; NaN];
            testCase.verifyTrue(isequaln(perFrame.trialIdx, expectedTidx));
        end

        function twoTrials_separateAssignments(testCase)
            % preStim=0 -> no baseline window at all.
            t1 = testCase.makeTrial(11, 1000, 2000, 0);
            t2 = testCase.makeTrial(12, 5000, 6000, 0);
            frames = uint64([1500; 3000; 5500; 7000]);

            [perTrial, perFrame] = tfp.io.alignTrialsToFrames([t1 t2], frames);

            testCase.verifyEqual(perTrial(1).trialIdx, 11);
            testCase.verifyEqual(perTrial(1).frame_indices_during_stim, uint64(1));
            testCase.verifyEqual(perTrial(1).frame_indices_baseline,    uint64.empty(1,0));
            testCase.verifyEqual(perTrial(2).trialIdx, 12);
            testCase.verifyEqual(perTrial(2).frame_indices_during_stim, uint64(3));
            testCase.verifyEqual(perTrial(2).frame_indices_baseline,    uint64.empty(1,0));

            testCase.verifyTrue(isequaln(perFrame.trialIdx, [11; NaN; 12; NaN]));
            testCase.verifyEqual(perFrame.phase, ["stim"; "none"; "stim"; "none"]);
        end

        function stimOverridesBaselineOfAnotherTrial(testCase)
            % t1 stim window [10000,11000], t2 baseline starts at
            % 11000-5000=6000 and ends at onset=11000. So t1's stim
            % completely covers t2's baseline -> frame in [10000,11000]
            % must be tagged stim+t1, not baseline+t2, regardless of
            % which trial we process first.
            t1 = testCase.makeTrial(1, 10000, 11000, 0);
            t2 = testCase.makeTrial(2, 11000, 12000, 0.05);   % baseline -> [6000,11000)

            frames = uint64([6500; 10500; 11500]);
            [~, perFrame] = tfp.io.alignTrialsToFrames([t1 t2], frames);

            % Frame 6500 falls only in t2's baseline.
            testCase.verifyEqual(perFrame.trialIdx(1), 2);
            testCase.verifyEqual(perFrame.phase(1),    "baseline");
            % Frame 10500 falls in t1's stim AND t2's baseline -> stim wins.
            testCase.verifyEqual(perFrame.trialIdx(2), 1);
            testCase.verifyEqual(perFrame.phase(2),    "stim");
            % Frame 11500 is in t2's stim only.
            testCase.verifyEqual(perFrame.trialIdx(3), 2);
            testCase.verifyEqual(perFrame.phase(3),    "stim");
        end

        function overlappingStim_warnsAndEarliestWins(testCase)
            t1 = testCase.makeTrial(1, 1000, 3000, 0);
            t2 = testCase.makeTrial(2, 2000, 4000, 0);   % overlaps t1's stim
            frames = uint64([2500; 3500]);

            testCase.verifyWarning( ...
                @() tfp.io.alignTrialsToFrames([t1 t2], frames), ...
                'tfp:io:alignTrialsToFrames:overlap');

            warning('off', 'tfp:io:alignTrialsToFrames:overlap');
            cleanup = onCleanup(@() warning('on', ...
                'tfp:io:alignTrialsToFrames:overlap'));
            [perTrial, perFrame] = tfp.io.alignTrialsToFrames([t1 t2], frames);

            % Frame 1 (2500) is in both stim windows; earliest (t1) wins.
            testCase.verifyEqual(perFrame.trialIdx(1), 1);
            testCase.verifyEqual(perFrame.phase(1),    "stim");
            % Frame 2 (3500) is only in t2's stim.
            testCase.verifyEqual(perFrame.trialIdx(2), 2);
            testCase.verifyEqual(perFrame.phase(2),    "stim");

            % Per-trial lists ignore the priority rule -- each trial gets
            % every frame inside its own window.
            testCase.verifyEqual(perTrial(1).frame_indices_during_stim, uint64(1));
            testCase.verifyEqual(perTrial(2).frame_indices_during_stim, uint64([1 2]));
        end

        function trialWithoutAnchor_isSkipped(testCase)
            % Trial that never had markRunning called -> NaN onset.
            tr = tfp.trial.Trial();
            tr.trialIdx  = 99;
            tr.preStim_s = 0.01;
            tr.markRunning();          % no-arg form, anchors stay NaN
            tr.markComplete([]);

            frames = uint64([100; 200; 300]);
            [perTrial, perFrame] = tfp.io.alignTrialsToFrames(tr, frames);

            testCase.verifyEqual(perTrial(1).trialIdx, 99);
            testCase.verifyEqual(perTrial(1).frame_indices_during_stim, uint64.empty(1,0));
            testCase.verifyEqual(perTrial(1).frame_indices_baseline,    uint64.empty(1,0));
            testCase.verifyTrue(all(isnan(perFrame.trialIdx)));
            testCase.verifyTrue(all(perFrame.phase == "none"));
        end

        function zeroPreStim_givesEmptyBaseline(testCase)
            tr = testCase.makeTrial(3, 1000, 2000, 0);
            frames = uint64([500; 1000; 1500; 2000]);
            [perTrial, ~] = tfp.io.alignTrialsToFrames(tr, frames);

            testCase.verifyEqual(perTrial(1).frame_indices_baseline, uint64.empty(1,0));
            testCase.verifyEqual(perTrial(1).frame_indices_during_stim, ...
                uint64([2 3 4]));
        end

        function rowVectorOutputs_evenWithSingleFrame(testCase)
            % Single-frame results must still come back as 1xK rows,
            % per the documented schema.
            tr = testCase.makeTrial(1, 1000, 2000, 0.01);
            frames = uint64(1500);
            perTrial = tfp.io.alignTrialsToFrames(tr, frames);

            testCase.verifyEqual(size(perTrial(1).frame_indices_during_stim), [1 1]);
            testCase.verifyEqual(perTrial(1).frame_indices_during_stim, uint64(1));
        end

        function frameStartSamples_acceptsDoubleInput(testCase)
            % decodeFrameClock returns uint64, but the function shouldn't
            % refuse a double vector (common when round-tripping through
            % .mat files or older code paths).
            tr = testCase.makeTrial(1, 1000, 2000, 0);
            frames = [500 1500 2500];   % row, double
            [~, perFrame] = tfp.io.alignTrialsToFrames(tr, frames);

            testCase.verifyEqual(class(perFrame.frameStartSample), 'uint64');
            testCase.verifyEqual(perFrame.frameStartSample, uint64([500; 1500; 2500]));
            testCase.verifyEqual(perFrame.phase, ["none"; "stim"; "none"]);
        end

        function badInputs_throwTypedErrors(testCase)
            tr = testCase.makeTrial(1, 100, 200, 0);

            testCase.verifyError( ...
                @() tfp.io.alignTrialsToFrames(struct('foo',1), uint64([1 2])), ...
                'tfp:io:alignTrialsToFrames:badTrials');

            testCase.verifyError( ...
                @() tfp.io.alignTrialsToFrames(tr, 'abc'), ...
                'tfp:io:alignTrialsToFrames:badFrames');

            testCase.verifyError( ...
                @() tfp.io.alignTrialsToFrames(tr, ones(2,2)), ...
                'tfp:io:alignTrialsToFrames:badFrames');
        end

        function attachFrameAlignment_roundtrip(testCase)
            % Demonstrates that the per-trial output plugs directly into
            % Trial.attachFrameAlignment without further massaging --
            % including round-tripping a frame index list back through
            % the schema described in SYNC_FRAME.md §6.2.
            tr = testCase.makeTrial(42, 10000, 20000, 0.05);
            frames = uint64([6000; 10000; 15000; 20000; 25000]);
            perTrial = tfp.io.alignTrialsToFrames(tr, frames);

            tr.attachFrameAlignment( ...
                perTrial(1).frame_indices_during_stim, ...
                perTrial(1).frame_indices_baseline, ...
                1);   % aux edge index — synthetic for the test

            testCase.verifyEqual(tr.frame_indices_during_stim, uint64([2 3 4]));
            testCase.verifyEqual(tr.frame_indices_baseline,    uint64(1));
            testCase.verifyEqual(tr.t_onset_si_aux_edge_index, 1);
        end
    end
end
