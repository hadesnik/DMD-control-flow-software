classdef test_exp_axial_ppsf_mock < matlab.unittest.TestCase
    %test_exp_axial_ppsf_mock Phase 1 milestone — full axial-PPSF experiment
    %against mocks. Verifies the end-to-end pipeline (DMD + DAQ + PLM) produces
    %the expected trial count, disk files, and summary shape with no hardware.

    methods (TestMethodSetup)
        function armSafety(~)
            tfp.util.safetyChecks('arm');
        end
    end

    methods (Test)

        function runFullExperimentAgainstMocksCheckOutputStructure(testCase)
            tempDataDir = tempname();
            cleaner = onCleanup(@() rmdirSafe(tempDataDir)); %#ok<NASGU>

            % Build inline config (no YAML needed).
            config.hardwareKind = 'mock';

            config.dmd.nRows                   = 800;
            config.dmd.nCols                   = 1280;
            config.dmd.maxPatternRate          = 12500;
            config.dmd.loadLatencyMsPerPattern = 0;
            config.dmd.debugFigure             = false;

            config.daq.sampleRate          = 10000;
            config.daq.analogInChannels    = [0 1];
            config.daq.analogOutChannels   = [0];
            config.daq.digitalOutChannels  = {'port0/line0'};
            config.daq.aiRangeV            = [-5 5];
            config.daq.fakeCells           = [];

            config.plm.nRows         = 800;
            config.plm.nCols         = 904;
            config.plm.pitchX_um     = 16.2;
            config.plm.pitchY_um     = 10.8;
            config.plm.nPhaseStates  = 32;
            config.plm.lambda_nm     = 1030;
            config.plm.loadLatencyMs = 0;

            config.paths.dataDir       = tempDataDir;
            config.calibration_file    = '';
            config.scanimage.enabled   = false;
            config.imaging.frameRate   = 30;
            config.imaging.simulateLatency = false;

            % Single target at (640, 400); one fake cell at that position.
            config.mockTargets = [640, 400];
            config.fakeCells = struct( ...
                'tag',       {'cell_01'}, ...
                'dmdCol',    {640}, ...
                'dmdRow',    {400}, ...
                'radiusDmd', {8}, ...
                'amplitude', {1.5}, ...
                'sigma',     {10}, ...
                'aiChannel', {0});

            % 3 dz steps, 2 reps → 1 target * 3 dz * 2 reps = 6 trials.
            config.axialPpsf.dzUm    = [-10, 0, 10];
            config.axialPpsf.nReps   = 2;
            config.axialPpsf.powerMw = 5;

            result = tfp.experiments.exp_axial_ppsf(config, 'test-axial-ppsf');

            % Trial counts.
            testCase.verifyEqual(result.nTrialsCompleted, 6);
            testCase.verifyEqual(result.nTrialsFailed,    0);

            % 6 .mat files on disk; each loadable and complete.
            files = dir(fullfile(result.sessionDir, 'trials', 'trial_*.mat'));
            testCase.verifyEqual(numel(files), 6);
            for k = 1:numel(files)
                loaded = load(fullfile(files(k).folder, files(k).name));
                testCase.verifyEqual(loaded.trial.status, 'complete');
                testCase.verifyNotEmpty(loaded.trial.data);
            end

            % Summary: one entry per dz step, 2 trials each.
            testCase.verifyEqual(numel(result.summary), 3);
            testCase.verifyTrue(isfield(result.summary, 'dzUm'));
            testCase.verifyTrue(isfield(result.summary, 'meanResponse'));
            testCase.verifyTrue(isfield(result.summary, 'nTrials'));
            for d = 1:3
                testCase.verifyEqual(result.summary(d).nTrials, 2);
            end

            % PLM integration: last trial data must contain a non-empty plmLog
            % with at least one loadPattern entry (confirms Sequencer called PLM).
            lastFile = load(fullfile(files(end).folder, files(end).name));
            plmLog = lastFile.trial.data.plmLog;
            testCase.verifyNotEmpty(plmLog);
            nLoadEntries = sum(strcmp({plmLog.eventType}, 'loadPattern'));
            testCase.verifyGreaterThanOrEqual(nLoadEntries, 1, ...
                'plmLog must contain at least one loadPattern entry.');
        end

    end
end

% Local helper.
function rmdirSafe(d)
if isfolder(d)
    rmdir(d, 's');
end
end
