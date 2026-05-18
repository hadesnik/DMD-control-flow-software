classdef test_exp_ppsf_lateral_mock < matlab.unittest.TestCase
    %test_exp_ppsf_lateral_mock Phase 1 milestone -- full PPSF experiment
    %against mocks. Verifies the end-to-end pipeline produces 18 completed
    %trials with a well-shaped summary.

    methods (TestMethodSetup)
        function armSafety(~)
            tfp.util.safetyChecks('arm');
        end
    end

    methods (Test)
        function runFullExperimentAgainstMocksCheckOutputStructure(testCase)
            tempDataDir = tempname();
            cleaner = onCleanup(@() rmdirSafe(tempDataDir)); %#ok<NASGU>

            % Build config struct directly (no YAML).
            config.hardwareKind = 'mock';
            config.dmd.nRows = 800;
            config.dmd.nCols = 1280;
            config.dmd.maxPatternRate = 12500;
            config.dmd.loadLatencyMsPerPattern = 0;
            config.dmd.debugFigure = false;
            config.daq.sampleRate = 10000;
            config.daq.analogInChannels = [0 1];
            config.daq.analogOutChannels = [0];
            config.daq.digitalOutChannels = {'port0/line0'};
            config.daq.aiRangeV = [-5 5];
            config.daq.fakeCells = [];
            config.paths.dataDir = tempDataDir;
            config.calibration_file = '';
            config.scanimage.enabled = false;

            result = tfp.experiments.exp_ppsf_lateral(config, 'test-session');

            % 3 targets * 3 distances * 2 reps = 18 trials.
            testCase.verifyEqual(result.nTrialsCompleted, 18);
            testCase.verifyEqual(result.nTrialsFailed, 0);

            % 18 .mat files on disk, each loadable, status complete.
            files = dir(fullfile(result.sessionDir, 'trials', 'trial_*.mat'));
            testCase.verifyEqual(numel(files), 18);
            for k = 1:numel(files)
                loaded = load(fullfile(files(k).folder, files(k).name));
                testCase.verifyEqual(loaded.trial.status, 'complete');
                testCase.verifyNotEmpty(loaded.trial.data);
            end

            % Summary shape: 3 rows (one per distance), expected fields,
            % 6 trials per distance (3 targets x 2 reps).
            testCase.verifyEqual(numel(result.summary), 3);
            testCase.verifyTrue(isfield(result.summary, 'distanceUm'));
            testCase.verifyTrue(isfield(result.summary, 'meanResponse'));
            testCase.verifyTrue(isfield(result.summary, 'nTrials'));
            for d = 1:3
                testCase.verifyEqual(result.summary(d).nTrials, 6);
            end
        end
    end
end

% Local helper.
function rmdirSafe(d)
if isfolder(d)
    rmdir(d, 's');
end
end
