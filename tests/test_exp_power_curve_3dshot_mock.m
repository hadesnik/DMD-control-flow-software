classdef test_exp_power_curve_3dshot_mock < matlab.unittest.TestCase
    %test_exp_power_curve_3dshot_mock Integration test for exp_power_curve_3dshot.
    %
    %   Runs the full experiment against mock hardware (MockDMD, MockDAQ,
    %   RemoteSLM in loopback mode wrapping MockSLM).  Verifies trial count,
    %   on-disk artefacts, summary shape, and session-log entries — all
    %   without touching any real hardware or network connections.
    %
    %   Config uses small SLM dims (128×128) and gsIters=6 to keep CGH
    %   runtime short.

    methods (TestMethodSetup)
        function armSafety(~)
            tfp.util.safetyChecks('arm');
        end
    end

    methods (Test)

        function runFullExperimentProducesExpectedTrialCount(testCase)
            tempDataDir = tempname();
            cleaner = onCleanup(@() rmdirSafe(tempDataDir)); %#ok<NASGU>

            config = buildMockConfig(tempDataDir);

            result = tfp.experiments.exp_power_curve_3dshot(config, 'test-3dshot-power-curve');

            % 2 power levels × 2 reps = 4 trials.
            testCase.verifyEqual(result.nTrialsCompleted, 4, ...
                'Expected 4 completed trials (2 powers × 2 reps).');
            testCase.verifyEqual(result.nTrialsFailed, 0, ...
                'Expected 0 failed trials.');
        end

        function runFullExperimentWritesMetaFilesAllComplete(testCase)
            tempDataDir = tempname();
            cleaner = onCleanup(@() rmdirSafe(tempDataDir)); %#ok<NASGU>

            config = buildMockConfig(tempDataDir);

            result = tfp.experiments.exp_power_curve_3dshot(config, 'test-3dshot-meta');

            % Expect exactly 4 _meta.mat files, each with status='complete'.
            metaFiles = dir(fullfile(result.sessionDir, 'trials', 'trial_*_meta.mat'));
            testCase.verifyEqual(numel(metaFiles), 4, ...
                'Expected 4 trial _meta.mat files on disk.');
            for k = 1:numel(metaFiles)
                loaded = load(fullfile(metaFiles(k).folder, metaFiles(k).name));
                testCase.verifyEqual(loaded.meta.status, 'complete', ...
                    sprintf('trial %d: expected status complete.', k));
            end
        end

        function summaryHasCorrectShape(testCase)
            tempDataDir = tempname();
            cleaner = onCleanup(@() rmdirSafe(tempDataDir)); %#ok<NASGU>

            config = buildMockConfig(tempDataDir);

            result = tfp.experiments.exp_power_curve_3dshot(config, 'test-3dshot-summary');

            % summary.response must be [nCells × nPowers] = [nAccepted × 2].
            testCase.verifyTrue(isfield(result.summary, 'perCellMw'), ...
                'summary must have perCellMw field.');
            testCase.verifyTrue(isfield(result.summary, 'response'), ...
                'summary must have response field.');
            testCase.verifyTrue(isfield(result.summary, 'nCells'), ...
                'summary must have nCells field.');

            nP = numel(config.powerCurve.perCellPowersMw);
            testCase.verifyEqual(size(result.summary.response, 2), nP, ...
                'response must have nPowers columns.');
            % nCells must be at least 1 (SLM accepted some targets).
            testCase.verifyGreaterThanOrEqual(result.summary.nCells, 1, ...
                'nCells must be >= 1.');
            testCase.verifyEqual(size(result.summary.response, 1), result.summary.nCells, ...
                'response rows must equal nCells.');
        end

        function sessionLogContainsExactlyOneSlmTargetsProjected(testCase)
            tempDataDir = tempname();
            cleaner = onCleanup(@() rmdirSafe(tempDataDir)); %#ok<NASGU>

            config = buildMockConfig(tempDataDir);

            result = tfp.experiments.exp_power_curve_3dshot(config, 'test-3dshot-log');

            % Read log.txt and count 'slm-targets-projected' entries.
            logFile = fullfile(result.sessionDir, 'log.txt');
            testCase.verifyTrue(isfile(logFile), 'log.txt must exist.');
            raw = fileread(logFile);
            hits = strfind(raw, 'slm-targets-projected');
            testCase.verifyEqual(numel(hits), 1, ...
                'Exactly one slm-targets-projected entry expected in session log.');
        end

        function resultContainsSlmFields(testCase)
            tempDataDir = tempname();
            cleaner = onCleanup(@() rmdirSafe(tempDataDir)); %#ok<NASGU>

            config = buildMockConfig(tempDataDir);

            result = tfp.experiments.exp_power_curve_3dshot(config, 'test-3dshot-fields');

            testCase.verifyTrue(isfield(result, 'nCells'), ...
                'result must have nCells field.');
            testCase.verifyTrue(isfield(result, 'perCellDeliveredFraction'), ...
                'result must have perCellDeliveredFraction field.');
            testCase.verifyTrue(isfield(result, 'perCellPowersMw'), ...
                'result must have perCellPowersMw field.');
            testCase.verifyEqual(numel(result.perCellPowersMw), ...
                numel(config.powerCurve.perCellPowersMw), ...
                'perCellPowersMw length must match config.');
            testCase.verifyGreaterThanOrEqual(result.nCells, 1, ...
                'nCells must be >= 1.');
            testCase.verifyTrue(isfinite(result.perCellDeliveredFraction), ...
                'perCellDeliveredFraction must be finite.');
        end

    end
end

% =========================================================================
% Local helpers
% =========================================================================

function config = buildMockConfig(tempDataDir)
%buildMockConfig Build a self-contained inline config for mock integration tests.

config.hardwareKind = 'mock';

% DMD (mock)
config.dmd.nRows                   = 800;
config.dmd.nCols                   = 1280;
config.dmd.maxPatternRate          = 12500;
config.dmd.loadLatencyMsPerPattern = 0;
config.dmd.debugFigure             = false;

% DAQ (mock) — 3 AI channels for 3 fake cells
config.daq.sampleRate         = 10000;
config.daq.analogInChannels   = [0 1 2];
config.daq.analogOutChannels  = [0];
config.daq.digitalOutChannels = {'port0/line0'};
config.daq.aiRangeV           = [-5 5];
config.daq.fakeCells          = [];

% SLM: loopback with small dims for speed
config.slm.connectionMode        = 'loopback';
config.slm.dims                  = [128 128];    % [nCols nRows]
config.slm.pitch_um              = 17;
config.slm.lambda_nm             = 1030;
config.slm.f_ft_um               = 16800;
config.slm.mag                   = 1;
config.slm.n                     = 1.33;
config.slm.gsIters               = 6;
config.slm.gsWeighted            = true;
config.slm.gsSeed                = 0;
config.slm.addressableRadiusUm   = 1e6;
config.slm.minSpacingUm          = 0;
config.slm.maxCells              = 20;
config.slm.slmScanCalib_file     = '';
config.slm.efficiencyMap_file    = '';

% Laser safety ceiling. In mock there is no absolute mW->V calibration, so
% totalPowers = perCell/f are in arbitrary units (f is a dimensionless focal
% fraction ~1/N). Use a large ceiling so the happy path runs all trials; the
% real safety-clip behaviour is exercised on the rig with a real calibration.
config.laser.modulation_voltage_max = 1e9;

% Power-curve parameters: 2 powers × 2 reps = 4 trials
config.powerCurve.perCellPowersMw = [1 2];
config.powerCurve.nReps           = 2;

% 3 mock SI centroids (SLM µm, small values well inside addressable radius)
config.mockTargets = [0 0; 5 0; -5 0];

% Fake cells for MockScanImageBridge / MockDAQ synthetic AI traces
config.fakeCells = struct( ...
    'tag',       {'cell_01', 'cell_02', 'cell_03'}, ...
    'dmdCol',    {640, 660, 620}, ...
    'dmdRow',    {400, 400, 400}, ...
    'radiusDmd', {14, 14, 14}, ...
    'amplitude', {1.0, 1.0, 1.0}, ...
    'sigma',     {10, 10, 10}, ...
    'aiChannel', {0, 1, 2});

config.paths.dataDir = tempDataDir;
end

function rmdirSafe(d)
if isfolder(d)
    rmdir(d, 's');
end
end
