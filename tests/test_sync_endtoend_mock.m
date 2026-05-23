classdef test_sync_endtoend_mock < matlab.unittest.TestCase
    %test_sync_endtoend_mock T-SYNC-13 end-to-end mock integration.
    %
    %   Runs a full mock session against MockDAQ's continuous-session API,
    %   persists trials via tfp.io.saveTrial, reloads them, reconstructs the
    %   frame->condition table via tfp.io.alignTrialsToFrames, and asserts
    %   that a synthetic GCaMP trace bins correctly by condition. This is
    %   the integration test that the four sync subsystems (T-SYNC-2..6) must
    %   compose to support: DAQ sample anchors -> saved schema fields ->
    %   reloaded Trial objects -> per-frame condition assignment.
    %
    %   See docs/SYNC_FRAME.md for the contracts being exercised.

    properties
        TmpDir
    end

    methods (TestMethodSetup)
        function makeTmp(testCase)
            testCase.TmpDir = tempname();
            mkdir(testCase.TmpDir);
            testCase.addTeardown(@() rmIfPresent(testCase.TmpDir));
        end
    end

    methods (Test)
        function fullMockSession_binsGCaMPByCondition(testCase)
            % --- 1. Start a continuous mock DAQ session. ----------------
            frameClockLine = 'port0/line2';
            sampleRate     = 1000;       % Hz; low enough that pause()s
                                          % give well-defined sample counts
            syntheticFsHz  = 30;         % synthetic ScanImage frame rate

            daq = tfp.hardware.MockDAQ();
            testCase.addTeardown(@() safeCleanup(daq));

            cfg = struct( ...
                'sampleRate',           sampleRate, ...
                'aiChannels',           [], ...
                'aoChannels',           [], ...
                'diLines',              {{frameClockLine}}, ...
                'doLines',              {{}}, ...
                'frameClockLine',       frameClockLine, ...
                'syntheticFrameRateHz', syntheticFsHz);
            daq.startContinuousSession(cfg);
            sessionStart = datetime('now');

            % --- 2. Run a small alternating-condition trial sequence. ---
            conditions    = {'A', 'B', 'A', 'B', 'A', 'B'};
            nTrials       = numel(conditions);
            preStim_s     = 0.05;
            duration_s    = 0.20;
            interTrial_s  = 0.05;

            % Initial baseline so the first trial has a clean pre-window.
            pause(preStim_s);

            for i = 1:nTrials
                t            = tfp.trial.Trial();
                t.trialIdx   = i;
                t.preStim_s  = preStim_s;
                t.duration_s = duration_s;
                t.postStim_s = 0;
                t.pulseTrain = struct('nPulses', 1, ...
                                      'interPulse_s', 0, ...
                                      'pulseWidth_s', duration_s);
                t.targetSpec = struct('cellIds', i, 'dmdCoords', [0 0]);
                t.powerMw    = 5.0;
                t.metadata   = struct('condition', conditions{i});

                onset = daq.currentSampleIndex();
                t.markRunning(onset, daq.sampleRate, sessionStart);
                pause(duration_s);
                offset = daq.currentSampleIndex();
                t.markComplete(struct(), offset);

                tfp.io.saveTrial(t, testCase.TmpDir, ...
                    struct('saveRawData', false));

                pause(preStim_s + interTrial_s);  % baseline for next trial
            end

            result = daq.stopContinuousSession();

            % --- 3. Decode frame clock from captured DI. ----------------
            fcCol = find(strcmp(result.lineNames.diLines, ...
                result.lineNames.frameClockLine), 1);
            testCase.assertNotEmpty(fcCol, ...
                'frameClockLine missing from result.lineNames.diLines');
            [frameStartSamples, frameRateHz] = tfp.io.decodeFrameClock( ...
                result.diData(:, fcCol), result.sampleRate);
            testCase.assertGreaterThan(numel(frameStartSamples), nTrials, ...
                'synthetic frame clock decoded too few frames for a meaningful test');
            testCase.verifyEqual(frameRateHz, syntheticFsHz, 'RelTol', 0.05);

            % --- 4. Reload trials from saved meta files. -----------------
            trialsDir = fullfile(testCase.TmpDir, 'trials');
            metaFiles = dir(fullfile(trialsDir, 'trial_*_meta.mat'));
            testCase.assertEqual(numel(metaFiles), nTrials);

            reloaded         = tfp.trial.Trial.empty;
            conditionByIdx   = repmat({''}, 1, nTrials);
            for k = 1:numel(metaFiles)
                S = load(fullfile(metaFiles(k).folder, metaFiles(k).name), ...
                    'meta');
                m  = S.meta;
                tr = tfp.trial.Trial();
                tr.trialIdx  = m.trialIdx;
                tr.preStim_s = m.timingSpec.preStim_s;
                tr.markRunning(m.t_onset_daq_samples, ...
                               m.daq_master_sample_rate_hz, ...
                               m.session_start_datetime);
                tr.markComplete(struct(), m.t_offset_daq_samples);
                reloaded(end+1) = tr; %#ok<AGROW>
                conditionByIdx{double(m.trialIdx)} = m.metadata.condition;
            end

            % dir() order isn't guaranteed: sort by trialIdx for stable
            % downstream behaviour.
            [~, sortOrd] = sort(arrayfun(@(x) x.trialIdx, reloaded));
            reloaded     = reloaded(sortOrd);

            % Sanity-check round-trip of the schema anchors.
            for i = 1:nTrials
                testCase.verifyEqual(reloaded(i).daq_master_sample_rate_hz, ...
                    sampleRate);
                testCase.verifyEqual(reloaded(i).session_start_datetime, ...
                    sessionStart);
                testCase.verifyGreaterThan( ...
                    double(reloaded(i).t_offset_daq_samples), ...
                    double(reloaded(i).t_onset_daq_samples));
            end

            % --- 5. Reconstruct the frame->condition table. -------------
            [perTrial, perFrame] = tfp.io.alignTrialsToFrames( ...
                reloaded, frameStartSamples);
            testCase.verifyEqual(numel(perTrial), nTrials);
            testCase.assertGreaterThan(sum(perFrame.phase == "stim"), 0, ...
                'no stim frames were assigned; alignment is empty');

            % Each trial must claim at least one stim frame (otherwise the
            % binning assertion below tests nothing).
            for i = 1:nTrials
                testCase.verifyNotEmpty( ...
                    perTrial(i).frame_indices_during_stim, ...
                    sprintf('trial %d got zero stim frames', i));
            end

            % --- 6. Synthetic GCaMP trace + condition binning. ----------
            % Construct a per-frame dF/F where condition A's stim frames
            % carry a large signal (+1.0) and condition B's stim frames
            % carry a small one (+0.05). Baseline / inter-trial frames are
            % near zero. The binner is verified to recover this contrast.
            nFrames = height(perFrame);
            rng(42);
            dff = randn(nFrames, 1) * 0.02;
            for f = 1:nFrames
                if perFrame.phase(f) ~= "stim", continue, end
                tidx = double(perFrame.trialIdx(f));
                switch conditionByIdx{tidx}
                    case 'A', dff(f) = dff(f) + 1.0;
                    case 'B', dff(f) = dff(f) + 0.05;
                end
            end

            % Bin per condition by walking perFrame and looking up the
            % stored condition for each frame's assigned trialIdx.
            condAFrames = false(nFrames, 1);
            condBFrames = false(nFrames, 1);
            for f = 1:nFrames
                if perFrame.phase(f) ~= "stim", continue, end
                tidx = double(perFrame.trialIdx(f));
                switch conditionByIdx{tidx}
                    case 'A', condAFrames(f) = true;
                    case 'B', condBFrames(f) = true;
                end
            end

            testCase.assertGreaterThan(sum(condAFrames), 0);
            testCase.assertGreaterThan(sum(condBFrames), 0);

            meanA = mean(dff(condAFrames));
            meanB = mean(dff(condBFrames));

            % A's stim frames carry ~1.0, B's carry ~0.05, noise ~0.02:
            % the difference must be unmistakable.
            testCase.verifyGreaterThan(meanA - meanB, 0.5);
            testCase.verifyEqual(meanA, 1.0, 'AbsTol', 0.1);
            testCase.verifyEqual(meanB, 0.05, 'AbsTol', 0.1);
        end
    end
end

function safeCleanup(daq)
try
    if daq.isRunning
        try, daq.stopContinuousSession(); catch, end %#ok<CTCH>
    end
    try, daq.cleanup(); catch, end %#ok<CTCH>
catch
end
end

function rmIfPresent(d)
if isfolder(d)
    rmdir(d, 's');
end
end
