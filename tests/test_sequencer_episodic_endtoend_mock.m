classdef test_sequencer_episodic_endtoend_mock < matlab.unittest.TestCase
    %test_sequencer_episodic_endtoend_mock End-to-end coverage of the
    %T-EP-3c Sequencer rewrite against the mock stack.
    %
    %   Exercises a 3-trial session through MockDMD + MockDAQ +
    %   MockScanImageBridge and verifies, beyond the per-trial event
    %   ordering covered in test_Sequencer_mock:
    %
    %     * the continuous DAQ session captures aiData and a non-empty
    %       frame-clock DI column;
    %     * decodeFrameClock + alignTrialsToFrames produce a perFrame
    %       table with as many rows as there were frame edges;
    %     * each completed trial carries the sample anchors, imaging
    %       struct (from getSyntheticResult on the mock), and the
    %       siTiffPath public property (3-arg markComplete; mock returns
    %       the .mat sidecar path via getLastTiffPath);
    %     * attachFrameAlignment populates frame_indices_during_stim
    %       on each trial whose stim window overlapped a frame.

    methods (TestMethodSetup)
        function armSafety(~)
            tfp.util.safetyChecks('arm');
        end
    end

    methods (Test)
        function full3TrialSessionFlows(testCase)
            tempDir = tempname();
            cleaner = onCleanup(@() rmdirSafe(tempDir)); %#ok<NASGU>

            % --- DMD ---
            dmd = tfp.hardware.MockDMD();
            dmdCfg.nRows                   = 800;
            dmdCfg.nCols                   = 1280;
            dmdCfg.maxPatternRate          = 12500;
            dmdCfg.loadLatencyMsPerPattern = 0;
            dmdCfg.debugFigure             = false;
            dmd.initialize(dmdCfg);

            % --- DAQ (advertises start-acq DO + frame-clock DI) ---
            daq = tfp.hardware.MockDAQ();
            daqCfg.sampleRate         = 10000;
            daqCfg.analogInChannels   = [0 1];
            daqCfg.analogOutChannels  = [0];
            daqCfg.digitalInChannels  = {'port0/line2'};
            daqCfg.digitalOutChannels = {'port0/line10'};
            daq.initialize(daqCfg);
            daq.configureAnalogInput([0 1], [-5 5]);
            daq.configureAnalogOutput([0]);
            daq.configureDigitalOutput({'port0/line10'});

            % --- Sequence (PPSF; positions inside the FOV; non-zero powerMw) ---
            targets    = [400, 400; 600, 400];
            offsets    = [0 0; 5 0];
            seq        = tfp.trial.TrialSequence.generatePPSF(targets, offsets, 1, 2.5);
            for k = 1:numel(seq.trials)
                tr = seq.trials(k);
                tr.targetSpec.patternRef = tfp.patterns.singleSpot( ...
                    dmd, tr.targetSpec.dmdCoords, 5);
            end

            % --- SI bridge (one fake cell so getSyntheticResult is non-empty) ---
            fakeCells = { tfp.sim.CellResponseModel([400, 400], 8, ...
                'amplitude', 1.5, 'sigma', 10, 'aiChannel', 0, ...
                'responseTag', 'cell_01') };
            siCfg = struct('frameRate', 30, 'simulateLatency', false);
            siBridge = tfp.hardware.MockScanImageBridge(fakeCells, siCfg);

            % --- Sequencer ---
            opts = struct();
            opts.siBridge = siBridge;
            opts.config = struct( ...
                'daq', struct('sampleRate', 10000, ...
                              'startAcqLine',   'port0/line10', ...
                              'startAcqPulseS', 0.005, ...
                              'frameClockLine', 'port0/line2', ...
                              'aoChannelIdx',   1), ...
                'imaging', struct('frameRate', 30));

            sessionDir = fullfile(tempDir, 'session');
            mkdir(sessionDir);
            sequencer = tfp.trial.Sequencer(dmd, daq, seq, sessionDir, opts);
            result    = sequencer.run();

            % --- Session-level result struct ---
            testCase.verifyTrue(isfield(result, 'sessionData'));
            testCase.verifyTrue(isfield(result, 'frameStartSamples'));
            testCase.verifyTrue(isfield(result, 'perFrame'));
            testCase.verifyTrue(isfield(result, 'perTrialAlignment'));

            sessionData = result.sessionData;
            testCase.verifyTrue(isstruct(sessionData));
            testCase.verifyGreaterThan(size(sessionData.aiData, 1), 0);
            testCase.verifyEqual(size(sessionData.aiData, 2), 2);
            testCase.verifyEqual(sessionData.lineNames.frameClockLine, 'port0/line2');

            % --- Frame edges & perFrame table ---
            testCase.verifyGreaterThan(numel(result.frameStartSamples), 0);
            testCase.verifyEqual(height(result.perFrame), numel(result.frameStartSamples));

            % --- Per-trial verification ---
            for k = 1:numel(seq.trials)
                tr = seq.trials(k);
                testCase.verifyEqual(tr.status, 'complete', ...
                    sprintf('trial %d not complete', k));

                % Sample anchors set by markRunning + markComplete in the
                % new flow.
                testCase.verifyClass(tr.t_onset_daq_samples,  'uint64');
                testCase.verifyClass(tr.t_offset_daq_samples, 'uint64');
                testCase.verifyGreaterThan(double(tr.t_offset_daq_samples), ...
                                            double(tr.t_onset_daq_samples));
                testCase.verifyEqual(tr.daq_master_sample_rate_hz, 10000);

                % siTiffPath: the mock bridge returns the .mat sidecar
                % path on the public Trial.siTiffPath property (3-arg
                % markComplete; see SYNC_EPISODIC.md §6).
                testCase.verifyClass(tr.siTiffPath, 'char');
                testCase.verifyTrue(endsWith(tr.siTiffPath, '.mat'));

                % imaging struct populated by the mock bridge.
                testCase.verifyTrue(isfield(tr.data, 'imaging'));
                testCase.verifyNotEmpty(tr.data.imaging);
                testCase.verifyTrue(isfield(tr.data.imaging, 'F'));

                % AI slice present (non-empty for non-zero pre/post-stim
                % windows on a multi-second mock session).
                testCase.verifyTrue(isfield(tr.data, 'aiData'));
                testCase.verifyGreaterThan(size(tr.data.aiData, 1), 0);
            end

            % --- Trial whose stim window straddles at least one frame
            % must have a populated frame_indices_during_stim row.
            haveStimFrames = false;
            for k = 1:numel(seq.trials)
                if ~isempty(seq.trials(k).frame_indices_during_stim)
                    haveStimFrames = true;
                    break
                end
            end
            testCase.verifyTrue(haveStimFrames, ...
                'At least one trial must have frame_indices_during_stim populated.');

            % --- Per-trial meta files written ---
            metaFiles = dir(fullfile(sessionDir, 'trials', 'trial_*_meta.mat'));
            testCase.verifyEqual(numel(metaFiles), numel(seq.trials));

            % --- Cleanup ---
            try, dmd.cleanup(); catch, end %#ok<CTCH>
            try, daq.cleanup(); catch, end %#ok<CTCH>
        end
    end
end

% Local helper.
function rmdirSafe(d)
if isfolder(d)
    rmdir(d, 's');
end
end
