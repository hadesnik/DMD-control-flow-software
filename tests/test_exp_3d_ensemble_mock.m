classdef test_exp_3d_ensemble_mock < matlab.unittest.TestCase
    %test_exp_3d_ensemble_mock End-to-end mock 3D session: depth-grouped
    %   sequence -> MockSLM advances -> free-run mock imaging -> per-group
    %   summary + persisted trials.

    properties
        tempDataDir
    end

    methods (TestMethodSetup)
        function armSafety(~)
            tfp.util.safetyChecks('arm');
        end
        function makeTmp(testCase)
            testCase.tempDataDir = tempname();
            mkdir(testCase.tempDataDir);
        end
    end

    methods (TestMethodTeardown)
        function rmTmp(testCase)
            if exist(testCase.tempDataDir, 'dir')
                rmdir(testCase.tempDataDir, 's');
            end
        end
    end

    methods (Access = private)
        function config = makeConfig(testCase)
            config.hardwareKind = 'mock';
            config.dmd = struct('nRows', 800, 'nCols', 1280, ...
                'maxPatternRate', 12500, 'loadLatencyMsPerPattern', 0, ...
                'debugFigure', false);
            config.daq = struct('sampleRate', 10000, ...
                'analogInChannels', [0 1], 'analogOutChannels', 0, ...
                'digitalOutChannels', {{'port0/line10', 'port0/line8'}}, ...
                'digitalInChannels', {{'port0/line2'}}, ...
                'aiRangeV', [-5 5], 'startAcqLine', 'port0/line10', ...
                'frameClockLine', 'port0/line2', 'aoChannelIdx', 1);
            config.paths   = struct('dataDir', testCase.tempDataDir);
            config.imaging = struct('frameRate', 30, 'simulateLatency', false, ...
                'planeZUm', [-15, 0, 15], 'imagingSigmaZUm', 6);
            config.slm = struct('enabled', true, 'backend', 'mock', ...
                'nRows', 64, 'nCols', 64, 'pitch_um', 17.0, 'nStates', 256, ...
                'lambda_nm', 1038, 'm_relay', 1.2, ...
                'trigger_mode', 'software', 'settle_s', 0, ...
                'uniform_blob_fraction', 0.02);
            config.objective = struct('name', 'nikon10x045');
            config.etl       = struct('n_planes', 3, 'plane_calibration_file', '');
            config.threeD    = struct('enabled', true, 'dz_bin_um', 10, ...
                'depth_gradient_sign', 1, 'pace_trials', false, ...
                'nReps', 2, 'powerMw', 1, 'radiusPx', 10);
            config.bringupMode = true;   % 0.1 s trials
            % Targets spread laterally with depths OPPOSING the tilt so
            % their required defocus values differ (multiple groups).
            config.mockTargets3D = [ ...
                450, 400, 3,  15; ...
                640, 400, 2,   0; ...
                830, 400, 1, -15];
            % Cells co-located with the targets, each at its target depth.
            config.fakeCells = struct( ...
                'tag',      {'p3', 'p2', 'p1'}, ...
                'dmdCol',   {450, 640, 830}, ...
                'dmdRow',   {400, 400, 400}, ...
                'radiusDmd', {8, 8, 8}, ...
                'amplitude', {1.5, 1.5, 1.5}, ...
                'sigma',     {10, 10, 10}, ...
                'aiChannel', {0, 1, 2}, ...
                'dmdZUm',    {15, 0, -15});
        end
    end

    methods (Test)

        function endToEndMock3DSession(testCase)
            config = testCase.makeConfig();
            result = tfp.experiments.exp_3d_ensemble(config, 'mock3d_e2e');

            testCase.verifyFalse(isfield(result, 'runError'), ...
                'experiment reported a run error');

            G = numel(result.groups);
            testCase.verifyGreaterThanOrEqual(G, 2, ...
                'FOV-spanning targets should split into multiple depth groups');
            testCase.verifyEqual(result.nTrialsCompleted, ...
                G * config.threeD.nReps);
            testCase.verifyEqual(result.nTrialsFailed, 0);

            % Per-group summary: every group saw responses.
            testCase.verifyEqual(numel(result.summary), G);
            for g = 1:G
                testCase.verifyEqual(result.summary(g).nTrials, ...
                    config.threeD.nReps);
                testCase.verifyGreaterThan(result.summary(g).meanResponse, ...
                    0.2, sprintf('group %d shows no response', g));
            end

            % Trials persisted; meta files carry no bulky pattern arrays.
            metaFiles = dir(fullfile(result.sessionDir, 'trials', ...
                'trial_*_meta.mat'));
            testCase.verifyEqual(numel(metaFiles), G * config.threeD.nReps);
            m1 = load(fullfile(metaFiles(1).folder, metaFiles(1).name));
            testCase.verifyTrue(isfield(m1, 'meta'));
            testCase.verifyEqual(m1.meta.status, 'complete');
            if isfield(m1.meta.targetSpec, 'patternRef')
                testCase.verifyTrue(isempty(m1.meta.targetSpec.patternRef), ...
                    'meta file must not carry the DMD pattern array');
            end
            % 3D metadata survived the round trip.
            testCase.verifyTrue(isfield(m1.meta.metadata, 'slmGroupIdx'));
            testCase.verifyTrue(isfield(m1.meta.metadata, 'slmDefocusUm'));
        end

        function refusesWithout3DFlag(testCase)
            config = testCase.makeConfig();
            config.threeD.enabled = false;
            testCase.verifyError( ...
                @() tfp.experiments.exp_3d_ensemble(config, 'mock3d_off'), ...
                'tfp:experiments:exp_3d_ensemble:threeDDisabled');
        end
    end
end
