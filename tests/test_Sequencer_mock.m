classdef test_Sequencer_mock < matlab.unittest.TestCase
    %test_Sequencer_mock Integration tests for the Sequencer rewrite (T-EP-3c).
    %
    %   Sequencer now drives a continuous, hardware-clocked DAQ session
    %   that spans the whole trial loop and arms ScanImage episodically
    %   per trial via the bridge. These tests verify:
    %
    %     * end-to-end run() against the mocks completes 3 trials,
    %       writes per-trial _meta files, and returns a result struct
    %       with the continuous-session diagnostics;
    %     * the per-trial event ordering DMD.softTrigger ->
    %       siBridge.armForExternalTrigger -> daq.sendDigitalPulse(startAcq)
    %       -> daq.queueClockedAO -> siBridge.waitForCompletion ->
    %       siBridge.getLastAcquisition (resolves T-EP-3c TODOs C1, C3,
    %       S1, S2, S3);
    %     * abort() cleans up and disarms safety; safety-abort during
    %       run() fails the in-flight trial and persists it.

    methods (TestMethodSetup)
        function armSafety(~)
            tfp.util.safetyChecks('arm');
        end
    end

    methods (Access = private)
        function [dmd, daq, sequence, sessionDir, siBridge, cleaner] = makeRig(~)
            % DMD
            dmd = tfp.hardware.MockDMD();
            dmdConfig.nRows                    = 800;
            dmdConfig.nCols                    = 1280;
            dmdConfig.maxPatternRate           = 12500;
            dmdConfig.debugFigure              = false;
            dmdConfig.loadLatencyMsPerPattern  = 0;
            dmd.initialize(dmdConfig);

            % DAQ — advertise BOTH the new start-acq DO line and the
            % frame-clock DI line so the continuous session can wire them
            % up cleanly (no warnings, exercises C1 + C4).
            daq = tfp.hardware.MockDAQ();
            daqConfig.sampleRate         = 10000;
            daqConfig.analogInChannels   = [0 1];
            daqConfig.analogOutChannels  = [0];
            daqConfig.digitalInChannels  = {'port0/line2'};
            daqConfig.digitalOutChannels = {'port0/line10'};
            daq.initialize(daqConfig);
            daq.configureAnalogInput([0 1], [-5 5]);
            daq.configureAnalogOutput([0]);
            daq.configureDigitalOutput({'port0/line10'});

            % 3-trial rapid-sequential sequence at 50 ms ISI -> 500 samples.
            % Targets sit inside the 420x420 central illuminated region
            % (DMD center (640,400); region cols [430,850], rows [190,610])
            % with a one-radius (14 px) margin. Spot radius = 14 px.
            targets  = [550, 400; 700, 400; 640, 500];
            sequence = tfp.trial.TrialSequence.generateRapidSequential( ...
                targets, 0.05, 1);
            for k = 1:numel(sequence.trials)
                pat = tfp.patterns.singleSpot(dmd, ...
                    sequence.trials(k).targetSpec.dmdCoords, 14);
                sequence.trials(k).targetSpec.patternRef = pat;
                % generateRapidSequential leaves powerMw empty; populate
                % so the AO waveform is non-trivial.
                sequence.trials(k).powerMw = 1.0;
            end

            % Spin up a mock SI bridge (no fake cells -> empty
            % synthetic-imaging output, sufficient for ordering tests).
            siCfg = struct('frameRate', 30, 'simulateLatency', false);
            siBridge = tfp.hardware.MockScanImageBridge([], siCfg);

            sessionDir = tempname();
            cleaner = onCleanup(@() rmdirSafe(sessionDir));
        end

        function seq = makeSequencer(~, dmd, daq, sequence, sessionDir, siBridge)
            opts = struct();
            if nargin >= 6 && ~isempty(siBridge)
                opts.siBridge = siBridge;
            end
            cfg = struct();
            cfg.daq.sampleRate     = 10000;
            cfg.daq.startAcqLine   = 'port0/line10';
            cfg.daq.startAcqPulseS = 0.005;
            cfg.daq.frameClockLine = 'port0/line2';
            cfg.daq.aoChannelIdx   = 1;
            cfg.imaging.frameRate  = 30;
            opts.config = cfg;
            seq = tfp.trial.Sequencer(dmd, daq, sequence, sessionDir, opts);
        end
    end

    methods (Test)
        function run_processesAllTrials(testCase)
            [dmd, daq, sequence, sessionDir, siBridge, cleaner] = testCase.makeRig(); %#ok<ASGLU>
            seq    = testCase.makeSequencer(dmd, daq, sequence, sessionDir, siBridge);
            result = seq.run();

            for k = 1:numel(sequence.trials)
                testCase.verifyEqual(sequence.trials(k).status, 'complete', ...
                    sprintf('trial %d status', k));
            end

            files = dir(fullfile(sessionDir, 'trials', 'trial_*_meta.mat'));
            testCase.verifyEqual(numel(files), numel(sequence.trials));

            % Result struct from run() carries the continuous-session bookkeeping.
            testCase.verifyTrue(isstruct(result));
            testCase.verifyTrue(isfield(result, 'sessionInfo'));
            testCase.verifyTrue(isfield(result, 'sessionData'));
            testCase.verifyTrue(isfield(result, 'frameStartSamples'));
            testCase.verifyTrue(isfield(result, 'perFrame'));
            testCase.verifyTrue(isfield(result, 'perTrialAlignment'));

            % Frame clock should produce at least a handful of edges
            % over a multi-second mock session.
            testCase.verifyGreaterThan(numel(result.frameStartSamples), 0, ...
                'Frame clock decode must produce >0 edges for an active session.');
        end

        function run_savesTrialFiles(testCase)
            [dmd, daq, sequence, sessionDir, siBridge, cleaner] = testCase.makeRig(); %#ok<ASGLU>
            seq = testCase.makeSequencer(dmd, daq, sequence, sessionDir, siBridge);
            seq.run();

            for k = 1:numel(sequence.trials)
                fname = fullfile(sessionDir, 'trials', ...
                    sprintf('trial_%04d_meta.mat', sequence.trials(k).trialIdx));
                testCase.verifyTrue(isfile(fname), sprintf('missing %s', fname));
                loaded = load(fname);
                testCase.verifyEqual(loaded.meta.trialIdx, sequence.trials(k).trialIdx);
                testCase.verifyEqual(loaded.meta.status, 'complete');

                % The new flow records sample anchors via Trial.markRunning/markComplete.
                testCase.verifyTrue(isfield(loaded.meta, 't_onset_daq_samples'));
                testCase.verifyTrue(isfield(loaded.meta, 't_offset_daq_samples'));
                testCase.verifyTrue(isfield(loaded.meta, 'daq_master_sample_rate_hz'));
                testCase.verifyEqual(loaded.meta.daq_master_sample_rate_hz, 10000);
            end
        end

        function run_perTrialEventOrdering(testCase)
            %run_perTrialEventOrdering DMD.softTrigger before DAQ AO queue (S1),
            %  no per-trial daq.start/stop (C3), frame-clock DI captured (C4),
            %  start-acq DO pulse fires per trial (C1), and no isa() check
            %  on the bridge (S3).
            [dmd, daq, sequence, sessionDir, siBridge, cleaner] = testCase.makeRig(); %#ok<ASGLU>
            seq = testCase.makeSequencer(dmd, daq, sequence, sessionDir, siBridge);
            seq.run();

            n = numel(sequence.trials);
            dmdEvents = {dmd.getLog().eventType};
            daqEvents = {daq.getLog().eventType};
            siEvents  = {siBridge.getLog().eventType};

            % DMD: per trial we expect load + arm + softTrigger.
            testCase.verifyEqual(sum(strcmp(dmdEvents, 'loadPatternSequence')), n);
            testCase.verifyEqual(sum(strcmp(dmdEvents, 'armSequence')),         n);
            testCase.verifyEqual(sum(strcmp(dmdEvents, 'softTrigger')),         n);

            % DAQ: ONE startContinuousSession + ONE stopContinuousSession (C3).
            % Per trial: queueClockedAO + sendDigitalPulse (start-acq).
            testCase.verifyEqual(sum(strcmp(daqEvents, 'startContinuousSession')), 1);
            testCase.verifyEqual(sum(strcmp(daqEvents, 'stopContinuousSession')),  1);
            testCase.verifyEqual(sum(strcmp(daqEvents, 'queueClockedAO')),         n);
            testCase.verifyEqual(sum(strcmp(daqEvents, 'sendDigitalPulse')),       n);
            % No legacy per-trial start/stop (C3 unification).
            testCase.verifyEqual(sum(strcmp(daqEvents, 'start')), 0);
            testCase.verifyEqual(sum(strcmp(daqEvents, 'stop')),  0);
            % No queueAnalogOutput / queueDigitalPulses from the old flow.
            testCase.verifyEqual(sum(strcmp(daqEvents, 'queueAnalogOutput')),  0);
            testCase.verifyEqual(sum(strcmp(daqEvents, 'queueDigitalPulses')), 0);

            % SI bridge: arm + setActivePattern + waitForCompletion + getLastAcquisition per trial.
            testCase.verifyEqual(sum(strcmp(siEvents, 'armForExternalTrigger')), n);
            testCase.verifyEqual(sum(strcmp(siEvents, 'setActivePattern')),      n);
            testCase.verifyEqual(sum(strcmp(siEvents, 'waitForCompletion')),     n);
            testCase.verifyEqual(sum(strcmp(siEvents, 'getLastAcquisition')),    n);

            % S1: every DMD.softTrigger fires before that same trial's
            % first queueClockedAO. The DAQ log is a flat session-wide
            % list; the DMD log is per-trial 3 events.  Verify by paired
            % timestamp comparison.
            dmdLog = dmd.getLog();
            daqLog = daq.getLog();
            softTimes  = [dmdLog(strcmp({dmdLog.eventType}, 'softTrigger')).timestamp];
            queueTimes = [daqLog(strcmp({daqLog.eventType}, 'queueClockedAO')).timestamp];
            testCase.verifyEqual(numel(softTimes),  n);
            testCase.verifyEqual(numel(queueTimes), n);
            for i = 1:n
                testCase.verifyLessThanOrEqual(softTimes(i), queueTimes(i), ...
                    sprintf('softTrigger trial %d must precede queueClockedAO', i));
            end
        end

        function run_frameClockDIConfigured(testCase)
            %run_frameClockDIConfigured C4: frameClockLine appears in sessionCfg.diLines.
            [dmd, daq, sequence, sessionDir, siBridge, cleaner] = testCase.makeRig(); %#ok<ASGLU>
            seq    = testCase.makeSequencer(dmd, daq, sequence, sessionDir, siBridge);
            result = seq.run();

            daqLog = daq.getLog();
            startEvent = daqLog(find(strcmp({daqLog.eventType}, 'startContinuousSession'), 1));
            testCase.verifyNotEmpty(startEvent);
            payload = startEvent.payload;
            testCase.verifyEqual(payload.frameClockLine, 'port0/line2');
            testCase.verifyTrue(any(strcmp(payload.diLines, 'port0/line2')));

            % The sessionData round-trip exposes the frame-clock column.
            testCase.verifyTrue(isfield(result.sessionData, 'lineNames'));
            testCase.verifyEqual(result.sessionData.lineNames.frameClockLine, ...
                'port0/line2');
        end

        function run_skipsSiBridgeWhenEmpty(testCase)
            [dmd, daq, sequence, sessionDir, ~, cleaner] = testCase.makeRig(); %#ok<ASGLU>
            % Explicitly omit siBridge to exercise the bridge-less path.
            seq = testCase.makeSequencer(dmd, daq, sequence, sessionDir, []);
            seq.run();

            logFile = fullfile(sessionDir, 'log.txt');
            testCase.verifyTrue(isfile(logFile));
            txt = fileread(logFile);
            testCase.verifyTrue(contains(txt, 'siBridge-skipped'));
        end

        function abort_setsFlagAndCleansUp(testCase)
            [dmd, daq, sequence, sessionDir, siBridge, cleaner] = testCase.makeRig(); %#ok<ASGLU>
            seq = testCase.makeSequencer(dmd, daq, sequence, sessionDir, siBridge);

            seq.abort();

            testCase.verifyError(@() tfp.util.safetyChecks('check'), ...
                'tfp:util:safetyAbort');
            testCase.verifyFalse(dmd.isInitialized);
        end

        function safetyAbort_duringRunFailsCleanly(testCase)
            [dmd, daq, sequence, sessionDir, siBridge, cleaner] = testCase.makeRig(); %#ok<ASGLU>
            seq = testCase.makeSequencer(dmd, daq, sequence, sessionDir, siBridge);

            % Trip the abort before run starts; safetyChecks('check') in
            % the trial loop will throw on the first iteration.
            tfp.util.safetyChecks('abort');

            testCase.verifyError(@() seq.run(), 'tfp:util:safetyAbort');

            % First trial marked failed (via the catch-block fallback
            % that transitions pending -> running -> failed); the others
            % remain pending.
            testCase.verifyEqual(sequence.trials(1).status, 'failed');
            for k = 2:numel(sequence.trials)
                testCase.verifyEqual(sequence.trials(k).status, 'pending');
            end

            fname = fullfile(sessionDir, 'trials', ...
                sprintf('trial_%04d_meta.mat', sequence.trials(1).trialIdx));
            testCase.verifyTrue(isfile(fname));
            loaded = load(fname);
            testCase.verifyEqual(loaded.meta.status, 'failed');
            testCase.verifyNotEmpty(loaded.meta.error);
            testCase.verifyEqual(loaded.meta.error.identifier, ...
                'tfp:util:safetyAbort');
        end
    end
end

% Local helper.
function rmdirSafe(d)
if isfolder(d)
    rmdir(d, 's');
end
end
