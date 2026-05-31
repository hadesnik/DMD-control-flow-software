classdef test_exp_ppsf_lateral_mock < matlab.unittest.TestCase
    %test_exp_ppsf_lateral_mock Phase 1 milestone -- full PPSF experiment
    %against mocks. PPSF runs against a single central target cell
    %(within 80 px of the DMD geometric center) and verifies the end-to-end
    %pipeline produces 34 completed trials (1 target * 17 distances * 2 reps)
    %with a well-shaped summary across 17 distance bins (symmetric -40..40 µm).

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

            % Single central target at the DMD geometric center (640,400).
            % PPSF requires exactly one target within 80 px of center; the
            % fake cell is co-located with the target so d=0 trials hit it.
            config.mockTargets = [640, 400];
            config.fakeCells = struct( ...
                'tag',       {'cell_01'}, ...
                'dmdCol',    {640}, ...
                'dmdRow',    {400}, ...
                'radiusDmd', {14}, ...
                'amplitude', {1.5}, ...
                'sigma',     {10}, ...
                'aiChannel', {0});

            result = tfp.experiments.exp_ppsf_lateral(config, 'test-session');

            % 1 target * 17 distances * 2 reps = 34 trials.
            testCase.verifyEqual(result.nTrialsCompleted, 34);
            testCase.verifyEqual(result.nTrialsFailed, 0);

            % 34 _meta.mat files on disk, each loadable, status complete.
            files = dir(fullfile(result.sessionDir, 'trials', 'trial_*_meta.mat'));
            testCase.verifyEqual(numel(files), 34);
            for k = 1:numel(files)
                loaded = load(fullfile(files(k).folder, files(k).name));
                testCase.verifyEqual(loaded.meta.status, 'complete');
            end

            % Summary shape: 9 rows (one per distance), expected fields,
            % 2 trials per distance (1 target x 2 reps).
            testCase.verifyEqual(numel(result.summary), 17);
            testCase.verifyTrue(isfield(result.summary, 'distanceUm'));
            testCase.verifyTrue(isfield(result.summary, 'meanResponse'));
            testCase.verifyTrue(isfield(result.summary, 'nTrials'));
            for d = 1:17
                testCase.verifyEqual(result.summary(d).nTrials, 2);
            end

            % meanResponse at d=0 should be positive (cells directly under spot).
            % distancesUm is symmetric -40..40; d=0 lives at the middle entry
            % (index 9 of 17), not index 1 as in the pre-bringup asymmetric form.
            d0idx = find([result.summary.distanceUm] == 0, 1);
            testCase.verifyGreaterThan(result.summary(d0idx).meanResponse, 0, ...
                'meanResponse at d=0 must be positive (on-target cells).');

            % meanResponse should peak at d=0 and fall off toward the edges.
            % distancesUm is symmetric, so check that the d=0 entry exceeds
            % BOTH endpoints (d=-40 and d=+40).
            responses = [result.summary.meanResponse];
            testCase.verifyGreaterThan(responses(d0idx), responses(1), ...
                'meanResponse at d=0 must exceed meanResponse at d=-40 um.');
            testCase.verifyGreaterThan(responses(d0idx), responses(end), ...
                'meanResponse at d=0 must exceed meanResponse at d=+40 um.');
        end

        function ppsf2d_runs_end_to_end(testCase)
            tempDataDir = tempname();
            cleaner = onCleanup(@() rmdirSafe(tempDataDir)); %#ok<NASGU>

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
            config.paths.dataDir = tempDataDir;
            config.calibration_file = '';
            config.scanimage.enabled = false;
            config.imaging.frameRate = 30;
            config.imaging.simulateLatency = false;
            % Single central target + co-located fake cell for the 2D PPSF.
            config.mockTargets = [640, 400];
            config.fakeCells = struct( ...
                'tag',       {'cell_01'}, ...
                'dmdCol',    {640}, ...
                'dmdRow',    {400}, ...
                'radiusDmd', {14}, ...
                'amplitude', {1.5}, ...
                'sigma',     {10}, ...
                'aiChannel', {0});

            config.ppsf2d.maxUm              = 10;
            config.ppsf2d.nPointsPerHalfAxis = 1;
            config.ppsf2d.nReps              = 1;

            result = tfp.experiments.exp_ppsf_2d(config, 'test-2d-session');

            testCase.verifyTrue(isfield(result, 'ppsf2d_summary'));
            testCase.verifyTrue(isfield(result, 'nTrialsCompleted'));
            testCase.verifyGreaterThan(result.nTrialsCompleted, 0);

            rmap = result.ppsf2d_summary.responseMap;
            testCase.verifyTrue(size(rmap,1) > 1 && size(rmap,2) > 1, ...
                'responseMap must be 2D with multiple rows and columns.');

            testCase.verifyTrue(isfield(result, 'ppsf2d_figure_path'));
            testCase.verifyTrue(isfile(result.ppsf2d_figure_path), ...
                'ppsf2d_heatmap.png must exist on disk.');
        end
    end
end

% Local helper.
function rmdirSafe(d)
if isfolder(d)
    rmdir(d, 's');
end
end
