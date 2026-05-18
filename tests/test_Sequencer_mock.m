classdef test_Sequencer_mock < matlab.unittest.TestCase
    %test_Sequencer_mock Phase 1 Sequencer integration tests.

    methods (TestMethodSetup)
        function armSafety(~)
            tfp.util.safetyChecks('arm');
        end
    end

    methods (Access = private)
        function [dmd, daq, sequence, sessionDir, cleaner] = makeRig(~)
            % DMD
            dmd = tfp.hardware.MockDMD();
            dmdConfig.nRows                    = 800;
            dmdConfig.nCols                    = 1280;
            dmdConfig.maxPatternRate           = 12500;
            dmdConfig.debugFigure              = false;
            dmdConfig.loadLatencyMsPerPattern  = 0;
            dmd.initialize(dmdConfig);

            % DAQ - configure all available channels.
            daq = tfp.hardware.MockDAQ();
            daqConfig.sampleRate         = 10000;
            daqConfig.analogInChannels   = [0 1];
            daqConfig.analogOutChannels  = [0];
            daqConfig.digitalOutChannels = {'port0/line0'};
            daq.initialize(daqConfig);
            daq.configureAnalogInput([0 1], [-5 5]);
            daq.configureAnalogOutput([0]);
            daq.configureDigitalOutput({'port0/line0'});

            % 3-trial rapid-sequential sequence at 50 ms ISI -> 500 samples.
            targets  = [400, 400; 600, 400; 500, 500];
            sequence = tfp.trial.TrialSequence.generateRapidSequential( ...
                targets, 0.05, 1);
            for k = 1:numel(sequence.trials)
                pat = tfp.patterns.singleSpot(dmd, ...
                    sequence.trials(k).targetSpec.dmdCoords, 5);
                sequence.trials(k).targetSpec.patternRef = pat;
            end

            sessionDir = tempname();
            cleaner = onCleanup(@() rmdirSafe(sessionDir));
        end
    end

    methods (Test)
        function run_processesAllTrials(testCase)
            [dmd, daq, sequence, sessionDir, cleaner] = testCase.makeRig(); %#ok<ASGLU>
            seq = tfp.trial.Sequencer(dmd, daq, sequence, sessionDir);
            seq.run();

            for k = 1:numel(sequence.trials)
                testCase.verifyEqual(sequence.trials(k).status, 'complete', ...
                    sprintf('trial %d status', k));
            end

            files = dir(fullfile(sessionDir, 'trials', 'trial_*.mat'));
            testCase.verifyEqual(numel(files), numel(sequence.trials));
        end

        function run_savesTrialFiles(testCase)
            [dmd, daq, sequence, sessionDir, cleaner] = testCase.makeRig(); %#ok<ASGLU>
            seq = tfp.trial.Sequencer(dmd, daq, sequence, sessionDir);
            seq.run();

            for k = 1:numel(sequence.trials)
                fname = fullfile(sessionDir, 'trials', ...
                    sprintf('trial_%04d.mat', sequence.trials(k).trialIdx));
                testCase.verifyTrue(isfile(fname), sprintf('missing %s', fname));
                loaded = load(fname);
                testCase.verifyEqual(loaded.trial.trialIdx, sequence.trials(k).trialIdx);
                testCase.verifyEqual(loaded.trial.status, 'complete');
            end
        end

        function run_callsDmdAndDaqInOrder(testCase)
            [dmd, daq, sequence, sessionDir, cleaner] = testCase.makeRig(); %#ok<ASGLU>
            seq = tfp.trial.Sequencer(dmd, daq, sequence, sessionDir);
            seq.run();

            n = numel(sequence.trials);
            dmdEvents = {dmd.getLog().eventType};
            testCase.verifyEqual(sum(strcmp(dmdEvents, 'loadPatternSequence')), n);
            testCase.verifyEqual(sum(strcmp(dmdEvents, 'armSequence')), n);
            testCase.verifyEqual(sum(strcmp(dmdEvents, 'softTrigger')), n);

            daqEvents = {daq.getLog().eventType};
            testCase.verifyEqual(sum(strcmp(daqEvents, 'queueAnalogOutput')), n);
            testCase.verifyEqual(sum(strcmp(daqEvents, 'queueDigitalPulses')), n);
            testCase.verifyEqual(sum(strcmp(daqEvents, 'start')), n);
            testCase.verifyEqual(sum(strcmp(daqEvents, 'stop')), n);
        end

        function run_skipsSiBridgeWhenEmpty(testCase)
            [dmd, daq, sequence, sessionDir, cleaner] = testCase.makeRig(); %#ok<ASGLU>
            seq = tfp.trial.Sequencer(dmd, daq, sequence, sessionDir);
            seq.run();

            logFile = fullfile(sessionDir, 'log.txt');
            testCase.verifyTrue(isfile(logFile));
            txt = fileread(logFile);
            testCase.verifyTrue(contains(txt, 'siBridge-skipped'));
        end

        function abort_setsFlagAndCleansUp(testCase)
            [dmd, daq, sequence, sessionDir, cleaner] = testCase.makeRig(); %#ok<ASGLU>
            seq = tfp.trial.Sequencer(dmd, daq, sequence, sessionDir);

            seq.abort();

            testCase.verifyError(@() tfp.util.safetyChecks('check'), ...
                'tfp:util:safetyAbort');
            testCase.verifyFalse(dmd.isInitialized);
        end

        function safetyAbort_duringRunFailsCleanly(testCase)
            [dmd, daq, sequence, sessionDir, cleaner] = testCase.makeRig(); %#ok<ASGLU>
            seq = tfp.trial.Sequencer(dmd, daq, sequence, sessionDir);

            % Trip the abort before run starts.
            tfp.util.safetyChecks('abort');

            testCase.verifyError(@() seq.run(), 'tfp:util:safetyAbort');

            % First trial marked failed, rest still pending.
            testCase.verifyEqual(sequence.trials(1).status, 'failed');
            for k = 2:numel(sequence.trials)
                testCase.verifyEqual(sequence.trials(k).status, 'pending');
            end

            % Failed trial's .mat file: exists, loadable, status=failed,
            % carries the safety-abort error in data.error.
            fname = fullfile(sessionDir, 'trials', ...
                sprintf('trial_%04d.mat', sequence.trials(1).trialIdx));
            testCase.verifyTrue(isfile(fname));
            loaded = load(fname);
            testCase.verifyEqual(loaded.trial.status, 'failed');
            testCase.verifyTrue(isfield(loaded.trial.data, 'error'));
            testCase.verifyEqual(loaded.trial.data.error.identifier, ...
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
