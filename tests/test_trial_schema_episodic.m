classdef test_trial_schema_episodic < matlab.unittest.TestCase
    %test_trial_schema_episodic T-EP-1a coverage for episodic-alignment
    %   schema fields and the attachEpisodicAlignment state transition on
    %   tfp.trial.Trial. See SYNC_EPISODIC.md §6 and §13.

    methods (Static)
        function t = makeTrial()
            t = tfp.trial.Trial();
            t.trialIdx   = 1;
            t.sessionId  = 'sess_episodic';
            t.duration_s = 0.1;
            t.preStim_s  = 0.1;
            t.postStim_s = 0.2;
        end
    end

    methods (Test)
        function defaultValues(testCase)
            t = test_trial_schema_episodic.makeTrial();
            testCase.verifyEqual(t.siTiffPath, '');
            testCase.verifyTrue(isnumeric(t.alignmentDiscrepancy));
            testCase.verifyTrue(isnan(t.alignmentDiscrepancy));
            testCase.verifyEqual(t.alignmentConfidence, "none");
        end

        function markComplete_withSiTiffPath(testCase)
            t = test_trial_schema_episodic.makeTrial();
            t.markRunning();
            t.markComplete(struct('foo', 1), uint64(2000), '/tmp/x.tif');
            testCase.verifyEqual(t.siTiffPath, '/tmp/x.tif');
            testCase.verifyEqual(t.status, 'complete');
            testCase.verifyEqual(t.t_offset_daq_samples, uint64(2000));
        end

        function markComplete_withoutSiTiffPath_backwardCompatible(testCase)
            t = test_trial_schema_episodic.makeTrial();
            t.markRunning();
            t.markComplete(struct('foo', 1), uint64(2000));
            testCase.verifyEqual(t.siTiffPath, '');
            testCase.verifyEqual(t.status, 'complete');

            % Also verify the 2-arg form leaves siTiffPath at default.
            t2 = test_trial_schema_episodic.makeTrial();
            t2.markRunning();
            t2.markComplete(struct('foo', 2));
            testCase.verifyEqual(t2.siTiffPath, '');
        end

        function attachEpisodicAlignment_happyPath(testCase)
            t = test_trial_schema_episodic.makeTrial();
            t.markRunning();
            t.markComplete(struct(), uint64(2000), '/tmp/x.tif');

            during   = uint64([10 11 12]);
            baseline = uint64([5 6 7 8 9]);
            t.attachEpisodicAlignment(during, baseline, 0, "high");

            testCase.verifyEqual(t.frame_indices_during_stim, during);
            testCase.verifyEqual(t.frame_indices_baseline,    baseline);
            testCase.verifyEqual(t.alignmentDiscrepancy, 0);
            testCase.verifyEqual(t.alignmentConfidence, "high");
        end

        function attachEpisodicAlignment_beforeMarkComplete_throws(testCase)
            t = test_trial_schema_episodic.makeTrial();
            testCase.verifyError( ...
                @() t.attachEpisodicAlignment(uint64([]), uint64([]), NaN, "none"), ...
                'tfp:trial:Trial:badTransition');

            t.markRunning();
            testCase.verifyError( ...
                @() t.attachEpisodicAlignment(uint64([]), uint64([]), NaN, "none"), ...
                'tfp:trial:Trial:badTransition');
        end

        function attachEpisodicAlignment_badConfidence_throws(testCase)
            t = test_trial_schema_episodic.makeTrial();
            t.markRunning();
            t.markComplete(struct());
            testCase.verifyError( ...
                @() t.attachEpisodicAlignment(uint64([]), uint64([]), 0, "bogus"), ...
                'tfp:trial:Trial:badConfidence');
            testCase.verifyError( ...
                @() t.attachEpisodicAlignment(uint64([]), uint64([]), 0, ["high" "low"]), ...
                'tfp:trial:Trial:badConfidence');
        end

        function attachEpisodicAlignment_nonUint64FrameIndices_throws(testCase)
            t = test_trial_schema_episodic.makeTrial();
            t.markRunning();
            t.markComplete(struct());

            % double row vector should be rejected
            testCase.verifyError( ...
                @() t.attachEpisodicAlignment([1 2 3], uint64([]), 0, "high"), ...
                'tfp:trial:Trial:badFrameIndices');
            testCase.verifyError( ...
                @() t.attachEpisodicAlignment(uint64([]), [1 2], 0, "high"), ...
                'tfp:trial:Trial:badFrameIndices');
            % column vector should be rejected (not a row vector)
            testCase.verifyError( ...
                @() t.attachEpisodicAlignment(uint64([1;2;3]), uint64([]), 0, "high"), ...
                'tfp:trial:Trial:badFrameIndices');
        end

        function attachEpisodicAlignment_idempotent(testCase)
            t = test_trial_schema_episodic.makeTrial();
            t.markRunning();
            t.markComplete(struct());

            during   = uint64([10 11 12]);
            baseline = uint64([5 6 7]);
            t.attachEpisodicAlignment(during, baseline, 1, "low");
            % Identical second call must succeed silently.
            t.attachEpisodicAlignment(during, baseline, 1, "low");

            testCase.verifyEqual(t.frame_indices_during_stim, during);
            testCase.verifyEqual(t.frame_indices_baseline,    baseline);
            testCase.verifyEqual(t.alignmentDiscrepancy, 1);
            testCase.verifyEqual(t.alignmentConfidence, "low");
        end

        function attachEpisodicAlignment_mismatch_throws(testCase)
            t = test_trial_schema_episodic.makeTrial();
            t.markRunning();
            t.markComplete(struct());

            during   = uint64([10 11 12]);
            baseline = uint64([5 6 7]);
            t.attachEpisodicAlignment(during, baseline, 0, "high");

            % Different discrepancy
            testCase.verifyError( ...
                @() t.attachEpisodicAlignment(during, baseline, 1, "high"), ...
                'tfp:trial:Trial:alignmentMismatch');
            % Different confidence
            testCase.verifyError( ...
                @() t.attachEpisodicAlignment(during, baseline, 0, "low"), ...
                'tfp:trial:Trial:alignmentMismatch');
            % Different frame indices
            testCase.verifyError( ...
                @() t.attachEpisodicAlignment(uint64([10 11]), baseline, 0, "high"), ...
                'tfp:trial:Trial:alignmentMismatch');
        end

        function attachFrameAlignment_deprecationWarning_oneShot(testCase)
            % Verify the deprecation warning is emitted on the FIRST call
            % to attachFrameAlignment, and that subsequent calls in the
            % same session are silent (one-shot semantic).
            %
            % The warning lives behind a `persistent` flag in a hidden
            % static helper, so a previous test (e.g. test_alignTrialsToFrames)
            % may have already tripped it. Reset the one-shot flag so this
            % test deterministically observes the first-call warning.
            tfp.trial.Trial.attachFrameAlignmentDeprecationGuard_(true);

            t = test_trial_schema_episodic.makeTrial();
            t.markRunning();
            t.markComplete(struct());

            testCase.verifyWarning( ...
                @() t.attachFrameAlignment(uint64([2 3 4]), uint64(1), 1), ...
                'tfp:trial:Trial:attachFrameAlignment:deprecated');

            % Second call (identical idempotent args) must NOT re-emit
            % the deprecation warning.
            testCase.verifyWarningFree( ...
                @() t.attachFrameAlignment(uint64([2 3 4]), uint64(1), 1));
        end
    end
end
