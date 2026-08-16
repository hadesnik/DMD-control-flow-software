classdef test_sequencer_slm_grouping_mock < matlab.unittest.TestCase
    %test_sequencer_slm_grouping_mock Sequencer 3D mode: SLM depth-group
    %   advances (count, dedupe, order), the free-run bridge session, and
    %   free-run alignment plumbing.

    methods (TestMethodSetup)
        function armSafety(~)
            tfp.util.safetyChecks('arm');
        end
    end

    methods (Access = private)
        function [dmd, daq, slm, sequence, groups, sessionDir, cleaner] = makeRig(~, nReps)
            dmd = tfp.hardware.MockDMD();
            dmd.initialize(struct('nRows', 800, 'nCols', 1280, ...
                'maxPatternRate', 12500, 'debugFigure', false, ...
                'loadLatencyMsPerPattern', 0));

            daq = tfp.hardware.MockDAQ();
            daqConfig.sampleRate         = 10000;
            daqConfig.analogInChannels   = [0 1];
            daqConfig.analogOutChannels  = [0];
            daqConfig.digitalInChannels  = {'port0/line2'};
            daqConfig.digitalOutChannels = {'port0/line10', 'port0/line8'};
            daq.initialize(daqConfig);
            daq.configureAnalogInput([0 1], [-5 5]);
            daq.configureAnalogOutput([0]);
            daq.configureDigitalOutput({'port0/line10', 'port0/line8'});

            slm = tfp.hardware.MockSLM();
            slm.initialize(struct('nRows', 64, 'nCols', 64, 'settle_s', 0));

            targets3D = [500, 400, 1, -15; 640, 400, 2, 0; 800, 400, 3, 15];
            [sequence, groups] = tfp.trial.TrialSequence.generate3DEnsemble( ...
                targets3D, struct('dmdSize', [800, 1280], 'dzBinUm', 10, ...
                'nReps', nReps, 'powerMw', 1));
            for k = 1:numel(sequence.trials)
                tr = sequence.trials(k);
                tr.targetSpec.patternRef = tfp.patterns.multiSpot( ...
                    dmd, tr.targetSpec.dmdCoords, 10);
                tr.duration_s = 0.05;
                tr.preStim_s  = 0.0;
                tr.postStim_s = 0.05;
            end

            sys = struct('mRelay', 1.2, 'nImm', 1.0, 'fObjUm', 20000, ...
                'NA', 0.45, 'wrapPhaseRad', 2 * pi);
            slm.prepareDefocusSequence([groups.dzUm], sys);
            slm.armSequenceTrigger('software');

            sessionDir = tempname();
            cleaner = onCleanup(@() rmdirSafe(sessionDir));
        end

        function cfg = threeDConfig(~)
            cfg = struct();
            cfg.daq.sampleRate     = 10000;
            cfg.daq.startAcqLine   = 'port0/line10';
            cfg.daq.startAcqPulseS = 0.005;
            cfg.daq.frameClockLine = 'port0/line2';
            cfg.daq.aoChannelIdx   = 1;
            cfg.imaging.frameRate  = 30;
            cfg.threeD = struct('enabled', true, 'pace_trials', false, ...
                'depth_gradient_sign', 1);
            cfg.etl    = struct('n_planes', 3);
            cfg.slm    = struct('enabled', true, ...
                'uniform_blob_fraction', 0.02);
        end
    end

    methods (Test)

        function advancesOncePerGroupChange(testCase)
            nReps = 2;
            [dmd, daq, slm, sequence, groups, sessionDir, cleaner] = ...
                testCase.makeRig(nReps); %#ok<ASGLU>
            siBridge = tfp.hardware.MockScanImageBridge([], ...
                struct('frameRate', 30, 'simulateLatency', false));

            opts = struct('slm', slm, 'siBridge', siBridge, ...
                'config', testCase.threeDConfig());
            sequencer = tfp.trial.Sequencer(dmd, daq, sequence, sessionDir, opts);
            result = sequencer.run();

            % All trials complete.
            statuses = {sequence.trials.status};
            testCase.verifyTrue(all(strcmp(statuses, 'complete')));

            % One settle per group CHANGE: G groups x nReps (rep
            % boundaries wrap G -> 1, which is a change too).
            G = numel(groups);
            entries = slm.getLog();
            nSettle = sum(strcmp({entries.eventType}, 'settle'));
            testCase.verifyEqual(nSettle, G * nReps);

            % The device walked the groups in sequence order.
            settleIdx = find(strcmp({entries.eventType}, 'settle'));
            walked = arrayfun(@(i) entries(i).payload.index, settleIdx);
            testCase.verifyEqual(walked, repmat(1:G, 1, nReps));

            % Free-run session: bridge saw beginFreeRunSession, never
            % beginSession/armForExternalTrigger.
            bLog = siBridge.getLog();
            types = {bLog.eventType};
            testCase.verifyTrue(any(strcmp(types, 'beginFreeRunSession')));
            testCase.verifyFalse(any(strcmp(types, 'beginSession')));
            testCase.verifyFalse(any(strcmp(types, 'armForExternalTrigger')));
            testCase.verifyTrue(any(strcmp(types, 'noteTrialFrames')));
            testCase.verifyTrue(any(strcmp(types, 'setActiveDefocus')));

            % Free-run alignment ran and produced plane-tagged frames.
            testCase.verifyTrue(isfield(result, 'perFrame'));
            testCase.verifyTrue(any(strcmp('planeIdx', ...
                result.perFrame.Properties.VariableNames)));

            % Per-trial slmLog + group index persisted in trial data.
            tr1 = sequence.trials(1);
            testCase.verifyTrue(isfield(tr1.data, 'slmGroupIdx'));
            testCase.verifyEqual(tr1.data.slmGroupIdx, ...
                tr1.metadata.slmGroupIdx);
        end

        function dedupesConsecutiveSameGroup(testCase)
            % nReps=1 with a single group: every trial same group -> exactly
            % one advance for the whole session.
            [dmd, daq, slm, ~, ~, sessionDir, cleaner] = testCase.makeRig(1); %#ok<ASGLU>
            targets3D = [640, 400, 2, 0; 660, 420, 2, 0];   % same depth bin
            [sequence, groups] = tfp.trial.TrialSequence.generate3DEnsemble( ...
                targets3D, struct('dmdSize', [800, 1280], 'dzBinUm', 50, ...
                'nReps', 3, 'powerMw', 1));
            testCase.assertEqual(numel(groups), 1);
            for k = 1:numel(sequence.trials)
                tr = sequence.trials(k);
                tr.targetSpec.patternRef = tfp.patterns.multiSpot( ...
                    dmd, tr.targetSpec.dmdCoords, 10);
                tr.duration_s = 0.05; tr.preStim_s = 0; tr.postStim_s = 0.05;
            end
            sys = struct('mRelay', 1.2, 'nImm', 1.0, 'fObjUm', 20000, ...
                'NA', 0.45, 'wrapPhaseRad', 2 * pi);
            slm.prepareDefocusSequence([groups.dzUm], sys);
            slm.armSequenceTrigger('software');

            opts = struct('slm', slm, 'config', testCase.threeDConfig());
            sequencer = tfp.trial.Sequencer(dmd, daq, sequence, sessionDir, opts);
            sequencer.run();

            entries = slm.getLog();
            nSettle = sum(strcmp({entries.eventType}, 'settle'));
            testCase.verifyEqual(nSettle, 1, ...
                'consecutive same-group trials must not re-advance the SLM');
        end
    end
end

% --- Local helper ---

function rmdirSafe(d)
if exist(d, 'dir')
    rmdir(d, 's');
end
end
