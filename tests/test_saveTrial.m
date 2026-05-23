classdef test_saveTrial < matlab.unittest.TestCase
    %test_saveTrial T-SYNC-6 coverage for tfp.io.saveTrial.
    %   Verifies that the meta file persists the TASK-SYNC-ALIGN schema
    %   fields documented in docs/SYNC_FRAME.md §6, mirrors the Trial-class
    %   defaults for unanchored trials, and preserves the pre-existing
    %   schema-v2 meta layout.

    properties
        TmpDir   % per-test temp session dir, cleaned up in TestMethodTeardown
    end

    methods (TestMethodSetup)
        function makeTmp(testCase)
            testCase.TmpDir = tempname();
            mkdir(testCase.TmpDir);
        end
    end

    methods (TestMethodTeardown)
        function rmTmp(testCase)
            if isfolder(testCase.TmpDir)
                rmdir(testCase.TmpDir, 's');
            end
        end
    end

    methods (Test)
        function unanchoredTrial_persistsDefaults(testCase)
            % A trial that never ran through a continuous DAQ session
            % must round-trip with the Trial-class defaults (NaN / NaT /
            % empty uint64) for every new sync field.
            t = makeBasicTrial(7);
            t.markComplete(struct('imaging', struct('F', 1000)));

            [metaPath, ~] = tfp.io.saveTrial(t, testCase.TmpDir, ...
                struct('saveRawData', false));
            S = load(metaPath, 'meta');

            % All seven sync fields must be present.
            testCase.verifyTrue(isfield(S.meta, 't_onset_daq_samples'));
            testCase.verifyTrue(isfield(S.meta, 't_offset_daq_samples'));
            testCase.verifyTrue(isfield(S.meta, 'daq_master_sample_rate_hz'));
            testCase.verifyTrue(isfield(S.meta, 'session_start_datetime'));
            testCase.verifyTrue(isfield(S.meta, 't_onset_si_aux_edge_index'));
            testCase.verifyTrue(isfield(S.meta, 'frame_indices_during_stim'));
            testCase.verifyTrue(isfield(S.meta, 'frame_indices_baseline'));

            % Defaults match Trial-class defaults.
            testCase.verifyTrue(isnan(S.meta.t_onset_daq_samples));
            testCase.verifyTrue(isnan(S.meta.t_offset_daq_samples));
            testCase.verifyTrue(isnan(S.meta.daq_master_sample_rate_hz));
            testCase.verifyTrue(isnat(S.meta.session_start_datetime));
            testCase.verifyTrue(isnan(S.meta.t_onset_si_aux_edge_index));
            testCase.verifyEqual(S.meta.frame_indices_during_stim, uint64([]));
            testCase.verifyEqual(S.meta.frame_indices_baseline,    uint64([]));
        end

        function anchoredTrial_persistsSampleAnchors(testCase)
            % markRunning(..., onsetSample, sampleRate, sessionStart) +
            % markComplete(data, offsetSample) must surface verbatim in the
            % saved meta file.
            onset  = uint64(123456);
            offset = uint64(123456 + 50000);  % 0.5 s @ 100 kHz
            fs     = 100000;
            t0     = datetime(2026, 5, 22, 14, 30, 0);

            t = makeBasicTrial(3);
            t.markRunning(onset, fs, t0);
            t.markComplete(struct(), offset);

            [metaPath, ~] = tfp.io.saveTrial(t, testCase.TmpDir, ...
                struct('saveRawData', false));
            S = load(metaPath, 'meta');

            testCase.verifyEqual(S.meta.t_onset_daq_samples,        onset);
            testCase.verifyEqual(S.meta.t_offset_daq_samples,       offset);
            testCase.verifyEqual(S.meta.daq_master_sample_rate_hz,  fs);
            testCase.verifyEqual(S.meta.session_start_datetime,     t0);

            % Post-hoc fields still at defaults since attachFrameAlignment
            % was not called.
            testCase.verifyTrue(isnan(S.meta.t_onset_si_aux_edge_index));
            testCase.verifyEqual(S.meta.frame_indices_during_stim, uint64([]));
            testCase.verifyEqual(S.meta.frame_indices_baseline,    uint64([]));
        end

        function alignedTrial_persistsFrameIndices(testCase)
            % After attachFrameAlignment the three post-hoc fields must
            % round-trip with exact types (uint64 row vectors, double
            % scalar edge index).
            t = makeBasicTrial(11);
            t.markRunning(uint64(1000), 100000, datetime(2026,5,22,0,0,0));
            t.markComplete(struct(), uint64(2000));

            during   = uint64([42 43 44 45]);
            baseline = uint64([38 39 40 41]);
            edgeIdx  = 17;
            t.attachFrameAlignment(during, baseline, edgeIdx);

            [metaPath, ~] = tfp.io.saveTrial(t, testCase.TmpDir, ...
                struct('saveRawData', false));
            S = load(metaPath, 'meta');

            testCase.verifyEqual(S.meta.frame_indices_during_stim, during);
            testCase.verifyEqual(S.meta.frame_indices_baseline,    baseline);
            testCase.verifyEqual(S.meta.t_onset_si_aux_edge_index, edgeIdx);
            testCase.verifyClass(S.meta.frame_indices_during_stim, 'uint64');
            testCase.verifyClass(S.meta.frame_indices_baseline,    'uint64');
        end

        function preExistingMetaFields_preserved(testCase)
            % T-SYNC-6 must not regress the schema-v2 meta layout. Spot
            % check the pre-existing fields after a normal save.
            t = makeBasicTrial(2);
            t.metadata = struct('foo', 'bar');
            t.markComplete(struct('imaging', struct('F', 1234)));

            [metaPath, rawPath] = tfp.io.saveTrial(t, testCase.TmpDir);
            S = load(metaPath, 'meta');

            testCase.verifyEqual(S.meta.trialIdx, 2);
            testCase.verifyEqual(S.meta.status,   'complete');
            testCase.verifyEqual(S.meta.powerMw,  5.0);
            testCase.verifyEqual(S.meta.metadata.foo, 'bar');
            testCase.verifyTrue(isstruct(S.meta.timingSpec));
            testCase.verifyTrue(isfield(S.meta.timingSpec, 'duration_s'));
            testCase.verifyTrue(isfield(S.meta, 'responseSummary'));
            testCase.verifyTrue(isfield(S.meta, 'fileRef'));
            testCase.verifyEqual(S.meta.fileRef, rawPath);
            testCase.verifyTrue(isfile(rawPath));
        end

        function failedTrial_persistsErrorAndSyncDefaults(testCase)
            % Failed trials must keep the error payload AND still carry the
            % new sync fields at their defaults.
            t = makeBasicTrial(9);
            t.markFailed(MException('my:err', 'boom'));

            [metaPath, ~] = tfp.io.saveTrial(t, testCase.TmpDir, ...
                struct('saveRawData', false));
            S = load(metaPath, 'meta');

            testCase.verifyEqual(S.meta.status, 'failed');
            testCase.verifyEqual(S.meta.error.identifier, 'my:err');
            testCase.verifyEqual(S.meta.error.message,    'boom');

            % Sync fields still present with defaults.
            testCase.verifyTrue(isnan(S.meta.t_onset_daq_samples));
            testCase.verifyTrue(isnat(S.meta.session_start_datetime));
            testCase.verifyEqual(S.meta.frame_indices_during_stim, uint64([]));
        end
    end
end

function t = makeBasicTrial(idx)
%makeBasicTrial Minimal Trial with the planning fields the test needs.
t = tfp.trial.Trial();
t.trialIdx   = idx;
t.targetSpec = struct('cellIds', idx, 'dmdCoords', [100 100]);
t.powerMw    = 5.0;
t.duration_s = 0.1;
t.preStim_s  = 0.5;
t.postStim_s = 1.0;
t.pulseTrain = struct('nPulses', 1, 'interPulse_s', 0, 'pulseWidth_s', 0.1);
t.metadata   = struct();
end
