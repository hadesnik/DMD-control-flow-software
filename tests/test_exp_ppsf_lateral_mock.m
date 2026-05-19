classdef test_exp_ppsf_lateral_mock < matlab.unittest.TestCase
    %test_exp_ppsf_lateral_mock Phase 1 milestone -- full PPSF experiment
    %against mocks. Verifies the end-to-end pipeline produces 54 completed
    %trials with a well-shaped summary across 9 distance bins.

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
            config.imaging.frameRate = 30;
            config.imaging.simulateLatency = false;

            % Fake cells placed at the three target positions used by the
            % experiment ([400,400], [500,400], [600,400]) so each trial
            % produces synthetic imaging data via MockScanImageBridge.
            config.fakeCells = struct( ...
                'tag',       {'cell_01',  'cell_02',  'cell_03'}, ...
                'dmdCol',    {400,        500,        600}, ...
                'dmdRow',    {400,        400,        400}, ...
                'radiusDmd', {8,          8,          8}, ...
                'amplitude', {1.5,        1.2,        1.8}, ...
                'sigma',     {10,         10,         10}, ...
                'aiChannel', {0,          1,          2});

            result = tfp.experiments.exp_ppsf_lateral(config, 'test-session');

            % 3 targets * 9 distances * 2 reps = 54 trials.
            testCase.verifyEqual(result.nTrialsCompleted, 54);
            testCase.verifyEqual(result.nTrialsFailed, 0);

            % 54 .mat files on disk, each loadable, status complete.
            files = dir(fullfile(result.sessionDir, 'trials', 'trial_*.mat'));
            testCase.verifyEqual(numel(files), 54);
            for k = 1:numel(files)
                loaded = load(fullfile(files(k).folder, files(k).name));
                testCase.verifyEqual(loaded.trial.status, 'complete');
                testCase.verifyNotEmpty(loaded.trial.data);
            end

            % Summary shape: 9 rows (one per distance), expected fields,
            % 6 trials per distance (3 targets x 2 reps).
            testCase.verifyEqual(numel(result.summary), 9);
            testCase.verifyTrue(isfield(result.summary, 'distanceUm'));
            testCase.verifyTrue(isfield(result.summary, 'meanResponse'));
            testCase.verifyTrue(isfield(result.summary, 'nTrials'));
            for d = 1:9
                testCase.verifyEqual(result.summary(d).nTrials, 6);
            end

            % meanResponse at d=0 should be positive (cells directly under spot).
            testCase.verifyGreaterThan(result.summary(1).meanResponse, 0, ...
                'meanResponse at d=0 must be positive (on-target cells).');

            % meanResponse should decrease monotonically from d=0 to d=40.
            responses = [result.summary.meanResponse];
            testCase.verifyGreaterThan(responses(1), responses(end), ...
                'meanResponse at d=0 must exceed meanResponse at d=40 um.');
        end
    end
end

% Local helper.
function rmdirSafe(d)
if isfolder(d)
    rmdir(d, 's');
end
end
