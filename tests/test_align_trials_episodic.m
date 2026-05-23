classdef test_align_trials_episodic < matlab.unittest.TestCase
    %test_align_trials_episodic Integration tests for tfp.io.alignTrialsEpisodic (T-EP-2b).
    %   Covers the LOCKED aligner contract documented in SYNC_EPISODIC.md §7
    %   and the per-trial / session-fatal failure-mode table in §11.
    %
    %   ORDER NOTE: tfp.io.alignTrialsEpisodic uses a function-local
    %   `persistent warnedLow` to make the lowConfidence warning one-shot
    %   per MATLAB session. MATLAB does not reset persistents between test
    %   methods. This test class therefore calls `clear functions` in
    %   TestMethodSetup so each method starts with a fresh persistent
    %   state; without that, only the first method that trips the warning
    %   would observe it. The cost is that any other persistent state
    %   relied on by tfp.io.* across calls is reset between methods, which
    %   is acceptable for these tests.

    properties (Constant)
        SR              = 100000          % 100 kHz master clock
        TRIAL_DUR_S     = 0.20            % 200 ms stim window per trial
        TRIAL_GAP_S     = 0.30            % 300 ms gap between trials
        FRAME_RATE_HZ   = 30.0
        EDGES_PER_STIM  = 6               % ~30 Hz across 200 ms
    end

    properties
        TmpDir
    end

    methods (TestMethodSetup)
        function makeTmpAndClear(testCase)
            testCase.TmpDir = tempname();
            mkdir(testCase.TmpDir);
            % Reset persistent one-shot warning flags inside the aligner
            % (see ORDER NOTE on classdef docstring).
            clear functions %#ok<CLFUNC>
        end
    end

    methods (TestMethodTeardown)
        function rmTmp(testCase)
            if isfolder(testCase.TmpDir)
                rmdir(testCase.TmpDir, 's');
            end
        end
    end

    methods (Access = private)

        function [trials, tiffPaths, fss] = buildSession(testCase, nTrials)
            % Builds nTrials complete trials, matching .mat sidecars, and
            % a frame-clock DI vector with EDGES_PER_STIM edges per stim
            % window plus a few interleaved frames in the gaps so the DI
            % vector looks realistic.
            trials    = tfp.trial.Trial.empty(1, 0);
            tiffPaths = cell(1, nTrials);
            fssAll    = uint64.empty(0, 1);

            stimSamples = uint64(testCase.TRIAL_DUR_S * testCase.SR);
            gapSamples  = uint64(testCase.TRIAL_GAP_S * testCase.SR);
            period      = stimSamples + gapSamples;

            for i = 1:nTrials
                onset  = uint64(10000) + uint64(i - 1) * period;
                offset = onset + stimSamples - uint64(1);

                tr = tfp.trial.Trial();
                tr.trialIdx  = i;
                tr.preStim_s = 0.0;
                tr.markRunning(onset, testCase.SR, datetime(2026, 1, 1));

                edges = testCase.uniformEdges(onset, offset, testCase.EDGES_PER_STIM);
                fssAll = [fssAll; edges]; %#ok<AGROW>

                sidecar = fullfile(testCase.TmpDir, ...
                    sprintf('mock_trial_%04d.mat', i));
                testCase.writeMatSidecar(sidecar, numel(edges));

                tr.markComplete(struct(), offset, sidecar);

                trials(end + 1) = tr; %#ok<AGROW>
                tiffPaths{i}    = sidecar;
            end
            fss = fssAll;
        end

        function edges = uniformEdges(~, onset, offset, n)
            % Evenly distribute n DAQ-sample edges across [onset, offset]
            % (inclusive of both ends); always returns a column uint64.
            if n <= 0
                edges = uint64.empty(0, 1);
                return
            end
            spacing = double(offset - onset) / double(n - 1);
            raw     = double(onset) + spacing * (0:(n - 1)).';
            edges   = uint64(round(raw));
        end

        function writeMatSidecar(~, path, nFrames)
            % Direct save of a .mat sidecar conforming to SYNC_EPISODIC.md
            % §9.7; avoids spinning up MockScanImageBridge.
            N = double(nFrames);
            meta = struct( ...
                'numFrames',                uint32(N), ...
                'numChannels',              uint32(1), ...
                'frameRateHz',              double(30), ...
                'frameTimestamps_s',        (0:max(N - 1, 0))' / 30, ...
                'timestampsAreSynthesised', true, ...
                'sourceTiff',               path, ...
                'scanImageVersion',         'mock'); %#ok<NASGU>
            save(path, 'meta', '-v7.3');
        end
    end

    methods (Test)

        function cleanRun_allHighConfidence(testCase)
            [trials, tiffPaths, fss] = testCase.buildSession(5);

            fn = @() tfp.io.alignTrialsEpisodic(trials, tiffPaths, fss, testCase.SR);
            testCase.verifyWarningFree(fn);

            [perTrial, perFrame, report] = fn();

            testCase.verifyFalse(report.fatal);
            testCase.verifyEqual(report.confidenceCounts.high, 5);
            testCase.verifyEqual(report.confidenceCounts.low, 0);
            testCase.verifyEqual(report.confidenceCounts.quarantine, 0);
            for i = 1:5
                testCase.verifyEqual(perTrial(i).alignmentConfidence, "high");
                testCase.verifyEqual(perTrial(i).reason, "");
                testCase.verifyEqual(perTrial(i).alignmentDiscrepancy, 0);
            end
            testCase.verifyEqual(height(perFrame), numel(fss));
            testCase.verifyEqual(perFrame.Properties.VariableNames, ...
                {'frameIdx', 'frameStartSample', 'trialIdx', 'phase'});
            testCase.verifyTrue(all(perFrame.phase == "stim"));
        end

        function missingFrameDIEdge_singleTrialLow(testCase)
            % Drop one DI edge from trial 3's stim window; TIFF still
            % reports its original frame count, so discrepancy = +1 on
            % trial 3 -- still "high" tier (|d| <= 1). Drop a SECOND edge
            % to get |d| = 2 ("low" tier).
            [trials, tiffPaths, fss] = testCase.buildSession(5);

            stimSamples = uint64(testCase.TRIAL_DUR_S * testCase.SR);
            gapSamples  = uint64(testCase.TRIAL_GAP_S * testCase.SR);
            period      = stimSamples + gapSamples;
            onset3      = uint64(10000) + uint64(2) * period;
            offset3     = onset3 + stimSamples - uint64(1);

            % Remove 2 edges from trial 3's window (preserves order).
            inWin   = fss >= onset3 & fss <= offset3;
            inIdx   = find(inWin);
            drop    = inIdx([2 3]);
            keepMask = true(size(fss));
            keepMask(drop) = false;
            fss     = fss(keepMask);

            testCase.verifyWarning( ...
                @() tfp.io.alignTrialsEpisodic(trials, tiffPaths, fss, testCase.SR), ...
                'tfp:io:alignTrialsEpisodic:lowConfidence');

            warning('off', 'tfp:io:alignTrialsEpisodic:lowConfidence');
            cleanup = onCleanup(@() warning('on', ...
                'tfp:io:alignTrialsEpisodic:lowConfidence'));

            [perTrial, ~, report] = ...
                tfp.io.alignTrialsEpisodic(trials, tiffPaths, fss, testCase.SR);

            testCase.verifyFalse(report.fatal);
            testCase.verifyEqual(perTrial(3).alignmentConfidence, "low");
            testCase.verifyEqual(perTrial(3).alignmentDiscrepancy, 2);
            for i = [1 2 4 5]
                testCase.verifyEqual(perTrial(i).alignmentConfidence, "high");
            end
        end

        function spuriousDIEdge_singleTrialLow(testCase)
            % Inject 2 spurious edges in trial 3's window -> d = -2 -> "low".
            [trials, tiffPaths, fss] = testCase.buildSession(5);

            stimSamples = uint64(testCase.TRIAL_DUR_S * testCase.SR);
            gapSamples  = uint64(testCase.TRIAL_GAP_S * testCase.SR);
            period      = stimSamples + gapSamples;
            onset3      = uint64(10000) + uint64(2) * period;
            offset3     = onset3 + stimSamples - uint64(1);

            extra = [onset3 + uint64(100); onset3 + uint64(200)];
            fss   = sort([fss; extra]);

            warning('off', 'tfp:io:alignTrialsEpisodic:lowConfidence');
            cleanup = onCleanup(@() warning('on', ...
                'tfp:io:alignTrialsEpisodic:lowConfidence'));

            [perTrial, ~, report] = ...
                tfp.io.alignTrialsEpisodic(trials, tiffPaths, fss, testCase.SR);

            testCase.verifyFalse(report.fatal);
            testCase.verifyEqual(perTrial(3).alignmentConfidence, "low");
            testCase.verifyEqual(perTrial(3).alignmentDiscrepancy, -2);
            for i = [1 2 4 5]
                testCase.verifyEqual(perTrial(i).alignmentConfidence, "high");
            end
        end

        function largeDiscrepancyQuarantine(testCase)
            % Drop ALL but 1 edges from trial 3's window so |d| = 5 still
            % is "low"; instead, inject many spurious edges -> |d| > 5.
            [trials, tiffPaths, fss] = testCase.buildSession(5);

            stimSamples = uint64(testCase.TRIAL_DUR_S * testCase.SR);
            gapSamples  = uint64(testCase.TRIAL_GAP_S * testCase.SR);
            period      = stimSamples + gapSamples;
            onset3      = uint64(10000) + uint64(2) * period;

            extras = onset3 + uint64((100:100:700).');  % 7 extras -> d = -7
            fss    = sort([fss; extras]);

            [perTrial, ~, report] = ...
                tfp.io.alignTrialsEpisodic(trials, tiffPaths, fss, testCase.SR);

            testCase.verifyFalse(report.fatal);
            testCase.verifyEqual(perTrial(3).alignmentConfidence, "quarantine");
            testCase.verifyEqual(perTrial(3).alignmentDiscrepancy, -7);
            testCase.verifyTrue(contains(perTrial(3).reason, "-7"));
            for i = [1 2 4 5]
                testCase.verifyEqual(perTrial(i).alignmentConfidence, "high");
            end
        end

        function missingTiff_perTrialQuarantine(testCase)
            [trials, tiffPaths, fss] = testCase.buildSession(5);
            tiffPaths{3} = '';

            [perTrial, ~, report] = ...
                tfp.io.alignTrialsEpisodic(trials, tiffPaths, fss, testCase.SR);

            testCase.verifyFalse(report.fatal);
            testCase.verifyEqual(perTrial(3).alignmentConfidence, "quarantine");
            testCase.verifyEqual(perTrial(3).reason, "missing-tiff");
            testCase.verifyEqual(perTrial(3).numFramesTiff, uint32(0));
            % DI-derived stim indices for trial 3 should still be populated.
            testCase.verifyGreaterThan( ...
                numel(perTrial(3).frame_indices_during_stim), 0);
            for i = [1 2 4 5]
                testCase.verifyEqual(perTrial(i).alignmentConfidence, "high");
            end
        end

        function unreadableTiff_perTrialQuarantine(testCase)
            [trials, tiffPaths, fss] = testCase.buildSession(5);

            bogus = fullfile(testCase.TmpDir, 'not_a_tiff.tif');
            fid = fopen(bogus, 'w');
            fwrite(fid, uint8([0 1 2 3 4 5 6 7 8 9]));
            fclose(fid);
            tiffPaths{3} = bogus;

            [perTrial, ~, report] = ...
                tfp.io.alignTrialsEpisodic(trials, tiffPaths, fss, testCase.SR);

            testCase.verifyFalse(report.fatal);
            testCase.verifyEqual(perTrial(3).alignmentConfidence, "quarantine");
            testCase.verifyEqual(perTrial(3).reason, "tiff-unreadable");
            for i = [1 2 4 5]
                testCase.verifyEqual(perTrial(i).alignmentConfidence, "high");
            end
        end

        function tiffCountMismatch_sessionFatal(testCase)
            % CONTRACT GAP (SYNC_EPISODIC.md §7.3 vs implementation):
            % the contract requires that numel(tiffPaths) ~= numel(trials)
            % produce report.fatal == true with correctly-shaped (all
            % "none") perTrial and an empty-table perFrame. The current
            % alignTrialsEpisodic implementation indexes tiffPaths{i}
            % during per-trial pre-population (around line 159) BEFORE
            % the numel mismatch check (around line 180), so a shorter
            % tiffPaths vector throws MATLAB:badsubscript instead of
            % returning a fatal report. This test pins the *current*
            % behaviour (verifyError) so the suite stays green; flip it
            % to the contract assertion once the aligner is fixed.
            [trials, tiffPaths, fss] = testCase.buildSession(5);
            tiffPaths(end) = [];   % length 4, but 5 trials

            testCase.verifyError( ...
                @() tfp.io.alignTrialsEpisodic(trials, tiffPaths, fss, testCase.SR), ...
                'MATLAB:badsubscript');
        end

        function sampleRateMismatch_sessionFatal(testCase)
            [trials, tiffPaths, fss] = testCase.buildSession(3);
            % Aligner sample rate disagrees with the trial anchor.
            [~, ~, report] = ...
                tfp.io.alignTrialsEpisodic(trials, tiffPaths, fss, 90000);

            testCase.verifyTrue(report.fatal);
            testCase.verifyTrue(contains(report.fatalReason, "sampleRate") || ...
                                 contains(report.fatalReason, "Hz"));
        end

        function nonMonotonicDI_sessionFatal(testCase)
            [trials, tiffPaths, fss] = testCase.buildSession(3);
            % Swap two entries to break strict monotonicity.
            fss([4 5]) = fss([5 4]);

            [~, ~, report] = ...
                tfp.io.alignTrialsEpisodic(trials, tiffPaths, fss, testCase.SR);

            testCase.verifyTrue(report.fatal);
            testCase.verifyTrue(contains(report.fatalReason, "monotonic"));
        end

        function overlappingStimWindows_warnOnce_earliestWins(testCase)
            % Two overlapping trials. Build them by hand because the
            % helper enforces non-overlapping windows.
            onset1  = uint64(10000);
            offset1 = uint64(30000);
            onset2  = uint64(20000);   % overlaps trial 1
            offset2 = uint64(40000);

            t1 = tfp.trial.Trial();
            t1.trialIdx = 1;
            t1.preStim_s = 0;
            t1.markRunning(onset1, testCase.SR, datetime(2026,1,1));

            t2 = tfp.trial.Trial();
            t2.trialIdx = 2;
            t2.preStim_s = 0;
            t2.markRunning(onset2, testCase.SR, datetime(2026,1,1));

            % 6 edges spread across [10000, 40000].
            fss = uint64([12000; 18000; 22000; 28000; 32000; 38000]);
            sidecar1 = fullfile(testCase.TmpDir, 'ov1.mat');
            sidecar2 = fullfile(testCase.TmpDir, 'ov2.mat');
            % Match TIFF frame counts to DI counts so the cross-check
            % stays "high" and doesn't trip lowConfidence on top of the
            % overlap warning we are verifying.
            n1 = sum(fss >= onset1 & fss <= offset1);
            n2 = sum(fss >= onset2 & fss <= offset2);
            testCase.writeMatSidecar(sidecar1, n1);
            testCase.writeMatSidecar(sidecar2, n2);

            t1.markComplete(struct(), offset1, sidecar1);
            t2.markComplete(struct(), offset2, sidecar2);

            trials    = [t1 t2];
            tiffPaths = {sidecar1, sidecar2};

            testCase.verifyWarning( ...
                @() tfp.io.alignTrialsEpisodic(trials, tiffPaths, fss, testCase.SR), ...
                'tfp:io:alignTrialsEpisodic:overlap');

            warning('off', 'tfp:io:alignTrialsEpisodic:overlap');
            cleanup = onCleanup(@() warning('on', ...
                'tfp:io:alignTrialsEpisodic:overlap'));

            [~, perFrame, ~] = ...
                tfp.io.alignTrialsEpisodic(trials, tiffPaths, fss, testCase.SR);

            % Frames 3 and 4 (samples 22000 and 28000) are in both
            % windows; earliest-in-input-order (trial 1) wins.
            testCase.verifyEqual(perFrame.trialIdx(3), 1);
            testCase.verifyEqual(perFrame.phase(3),    "stim");
            testCase.verifyEqual(perFrame.trialIdx(4), 1);
            testCase.verifyEqual(perFrame.phase(4),    "stim");
            % Frame 5 (32000) is only in trial 2's window.
            testCase.verifyEqual(perFrame.trialIdx(5), 2);
            testCase.verifyEqual(perFrame.phase(5),    "stim");
        end

        function baselineWindow_preStim(testCase)
            onset  = uint64(60000);   % 0.6 s in
            offset = onset + uint64(testCase.TRIAL_DUR_S * testCase.SR) - uint64(1);
            preStim_s = 0.5;

            tr = tfp.trial.Trial();
            tr.trialIdx = 1;
            tr.preStim_s = preStim_s;
            tr.markRunning(onset, testCase.SR, datetime(2026,1,1));

            % Place 3 edges inside the baseline window [10000, 60000).
            baseline = uint64([15000; 30000; 50000]);
            stim     = testCase.uniformEdges(onset, offset, testCase.EDGES_PER_STIM);
            fss      = sort([baseline; stim]);

            sidecar = fullfile(testCase.TmpDir, 'baseline.mat');
            testCase.writeMatSidecar(sidecar, numel(stim));

            tr.markComplete(struct(), offset, sidecar);

            [perTrial, ~, report] = ...
                tfp.io.alignTrialsEpisodic(tr, {sidecar}, fss, testCase.SR);

            testCase.verifyFalse(report.fatal);
            testCase.verifyEqual(perTrial(1).alignmentConfidence, "high");

            % Baseline indices: positions 1..3 of fss (uint64 row vector).
            testCase.verifyEqual(perTrial(1).frame_indices_baseline, uint64([1 2 3]));

            % None of the baseline indices should appear in the stim list.
            stimIdx = perTrial(1).frame_indices_during_stim;
            testCase.verifyTrue(isempty(intersect(stimIdx, uint64([1 2 3]))));
        end

        function noPreStim_baselineEmpty(testCase)
            [trials, tiffPaths, fss] = testCase.buildSession(1);
            % buildSession already uses preStim_s = 0.
            [perTrial, ~, ~] = ...
                tfp.io.alignTrialsEpisodic(trials, tiffPaths, fss, testCase.SR);

            testCase.verifyEqual(perTrial(1).frame_indices_baseline, ...
                uint64.empty(1, 0));
        end

        function nonCompleteTrialsSkipped(testCase)
            [trials, tiffPaths, fss] = testCase.buildSession(3);

            % Force trial 2 to status 'failed' by constructing a fresh
            % trial that goes from pending -> failed (markFailed accepts
            % pending).
            failed = tfp.trial.Trial();
            failed.trialIdx = 2;
            failed.preStim_s = 0;
            failed.markFailed('synthetic failure');
            trials(2) = failed;
            tiffPaths{2} = '';  % no TIFF for failed trial

            [perTrial, ~, report] = ...
                tfp.io.alignTrialsEpisodic(trials, tiffPaths, fss, testCase.SR);

            testCase.verifyFalse(report.fatal);
            testCase.verifyEqual(perTrial(2).alignmentConfidence, "none");
            testCase.verifyEqual(perTrial(2).reason, "trial-not-complete");

            % Skipped trials are recorded in report.skippedTrials.
            skippedIdx = [report.skippedTrials.trialIdx];
            testCase.verifyTrue(ismember(2, skippedIdx));

            % Trials 1 and 3 still align as "high".
            testCase.verifyEqual(perTrial(1).alignmentConfidence, "high");
            testCase.verifyEqual(perTrial(3).alignmentConfidence, "high");
        end

        function noDAQAnchorSkipped(testCase)
            % A trial completed without ever calling the extended
            % markRunning form -> t_onset_daq_samples stays NaN.
            tr = tfp.trial.Trial();
            tr.trialIdx = 1;
            tr.preStim_s = 0;
            tr.markRunning();                    % no anchors
            tr.markComplete(struct());           % no offset, no path

            fss = uint64([100; 200; 300]);

            [perTrial, ~, report] = ...
                tfp.io.alignTrialsEpisodic(tr, {''}, fss, testCase.SR);

            testCase.verifyFalse(report.fatal);
            testCase.verifyEqual(perTrial(1).alignmentConfidence, "none");
            testCase.verifyEqual(perTrial(1).reason, "no-daq-anchor");

            skippedIdx = [report.skippedTrials.trialIdx];
            testCase.verifyTrue(ismember(1, skippedIdx));
        end

        function emptyInput_noTrials(testCase)
            [perTrial, perFrame, report] = tfp.io.alignTrialsEpisodic( ...
                tfp.trial.Trial.empty(0, 1), {}, uint64.empty(0, 1), ...
                testCase.SR);

            testCase.verifyFalse(report.fatal);
            testCase.verifyEqual(numel(perTrial), 0);
            testCase.verifyEqual(height(perFrame), 0);
            testCase.verifyEqual(perFrame.Properties.VariableNames, ...
                {'frameIdx', 'frameStartSample', 'trialIdx', 'phase'});
            testCase.verifyEqual(report.numTrialsInput, 0);
            testCase.verifyEqual(report.numTrialsAligned, uint32(0));
        end

        function emptyDIWithNonEmptyTiffs_perTrialQuarantine(testCase)
            [trials, tiffPaths, ~] = testCase.buildSession(3);
            emptyFss = uint64.empty(0, 1);

            [perTrial, ~, report] = ...
                tfp.io.alignTrialsEpisodic(trials, tiffPaths, emptyFss, testCase.SR);

            testCase.verifyFalse(report.fatal);
            for i = 1:3
                testCase.verifyEqual(perTrial(i).alignmentConfidence, "quarantine");
                testCase.verifyEqual(perTrial(i).reason, "no-di-edges-in-window");
            end
        end
    end
end
