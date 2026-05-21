%test_ensemble_activation_mock  Smoke-test exp_ensemble_activation with mock hardware.
%
%   Runs the full two-condition ensemble activation experiment against
%   MockDMD and MockDAQ — no real hardware, no ScanImage connection.
%
%   20 random ROI centroids are generated within the mock DMD FOV.
%   The live figure is shown; the experiment takes ~20.5 s (20 sequential
%   500 ms stim + 500 ms gap each, then 1 ensemble stim).
%
%   Usage:
%     cd to repo root, then:
%       >> run tests/test_ensemble_activation_mock
%     or:
%       >> addpath(fullfile(pwd, 'src'));
%       >> run tests/test_ensemble_activation_mock

addpath(fullfile(fileparts(mfilename('fullpath')), '..', 'src'));

% -------------------------------------------------------------------------
% Hardware
% -------------------------------------------------------------------------
dmd = tfp.hardware.MockDMD();
dmd.initialize(struct('nRows', 800, 'nCols', 1280));

daq = tfp.hardware.MockDAQ();
daq.initialize(struct( ...
    'sampleRate',         10000, ...
    'analogInChannels',   [], ...
    'analogOutChannels',  1, ...
    'digitalInChannels',  {{}}, ...
    'digitalOutChannels', {{}}));

% -------------------------------------------------------------------------
% Calibration (identity: scan-field coords == DMD pixel coords)
% -------------------------------------------------------------------------
% dmdToScan_affine maps [dmd_col; dmd_row; 1] -> [scan_x; scan_y; 1].
% Identity means the mock ROIs can be expressed directly in DMD pixel coords.
calib.dmdToScan_affine    = eye(3);
calib.scan_fast_axis_sign = 1;
calib.scan_slow_axis_sign = 1;

% -------------------------------------------------------------------------
% 20 random ROI centroids (in scan-field = DMD pixel coords for this mock)
% -------------------------------------------------------------------------
rng(42);
nROIs  = 20;
margin = 40;    % keep spots away from DMD edges so no clamping warnings

roiCentroids_scan = [randi([margin, dmd.nCols - margin], nROIs, 1), ...
                     randi([margin, dmd.nRows - margin], nROIs, 1)];
roiCentroids_scan = double(roiCentroids_scan);

fprintf('Mock ROI centroids (DMD pixel coords):\n');
for k = 1:nROIs
    fprintf('  ROI %2d: col=%4d  row=%3d\n', k, ...
        roiCentroids_scan(k,1), roiCentroids_scan(k,2));
end

% -------------------------------------------------------------------------
% Mock power curve (linear 0–100 mW over 0–5 V, as if from powerMeterSweep)
% Fractions [0.2 0.4 0.6 0.8 1.0] → voltages [1 2 3 4 5] V
% -------------------------------------------------------------------------
mockPowerCurve.voltageV = linspace(0, 5,   25);
mockPowerCurve.powerMw  = linspace(0, 100, 25);

% -------------------------------------------------------------------------
% Experiment options
% -------------------------------------------------------------------------
options.spotRadiusPx   = 8;              % ~16 µm diameter at ~2 µm/px (DLi4130)
options.stimDurationS  = 0.5;           % 500 ms laser ON
options.interStimS     = 0.5;           % 500 ms gap between sequential pulses
options.aoChannel      = 'ao1';         % FS-50 power modulation channel
options.powerV         = 5.0;           % full power (mock: just logged)
options.powerCurve     = mockPowerCurve;
options.powerFractions = 0.2:0.2:1.0;
options.showLiveFigure = true;

% -------------------------------------------------------------------------
% Run
% -------------------------------------------------------------------------
fprintf('\nStarting mock ensemble activation (est. %.0f s)...\n', ...
    nROIs * (options.stimDurationS + options.interStimS) + options.stimDurationS);

result = tfp.experiments.exp_ensemble_activation( ...
    dmd, daq, roiCentroids_scan, calib, options);

% -------------------------------------------------------------------------
% Verify via DAQ log
% -------------------------------------------------------------------------
daqLog = daq.getLog();
aoEvents = daqLog(strcmp({daqLog.eventType}, 'outputSingleAnalog'));

onVoltages  = arrayfun(@(e) e.payload.voltageV, aoEvents);
nPulsesOn   = sum(onVoltages == options.powerV);
nPulsesOff  = sum(onVoltages == 0);

nPowerLevels   = numel(options.powerFractions);
% Expected ON pulses: nROIs (sequential) + 1 (ensemble) + nPowerLevels (series)
expectedOn  = nROIs + 1 + nPowerLevels;
% Expected OFF pulses: same count + 1 initial safety-off
expectedOff = expectedOn + 1;
% Expected advanceToPattern: nROIs (sequential) + 1 (ensemble) + nPowerLevels (series)
expectedAdv = nROIs + 1 + nPowerLevels;

fprintf('\n--- Mock verification ---\n');
fprintf('  DAQ outputSingleAnalog events: %d total\n', numel(aoEvents));
fprintf('  ON  pulses: %d  (expected %d)\n', nPulsesOn,  expectedOn);
fprintf('  OFF pulses: %d  (expected %d)\n', nPulsesOff, expectedOff);

dmdLog = dmd.getLog();
advEvents = dmdLog(strcmp({dmdLog.eventType}, 'advanceToPattern'));
fprintf('  DMD advanceToPattern calls: %d  (expected %d)\n', ...
    numel(advEvents), expectedAdv);

fprintf('\nPower-series voltages:\n');
for k = 1:nPowerLevels
    fprintf('  %.0f%%  →  %.3f V\n', ...
        options.powerFractions(k) * 100, result.powerSeriesVoltages(k));
end

fprintf('\nResult struct:\n');
fprintf('  nROIs:              %d\n', result.nROIs);
fprintf('  nSequentialTrials:  %d\n', result.nSequentialTrials);
fprintf('  nEnsembleTrials:    %d\n', result.nEnsembleTrials);
fprintf('  nPowerSeriesTrials: %d\n', result.nPowerSeriesTrials);
fprintf('  completedAt:        %s\n', char(result.completedAt));

assert(result.nROIs == nROIs, 'result.nROIs mismatch');
assert(result.nSequentialTrials == nROIs, 'nSequentialTrials mismatch');
assert(result.nEnsembleTrials == 1, 'nEnsembleTrials mismatch');
assert(result.nPowerSeriesTrials == nPowerLevels, 'nPowerSeriesTrials mismatch');
assert(nPulsesOn == expectedOn, ...
    'Expected %d ON pulses, got %d', expectedOn, nPulsesOn);
% Verify voltages are monotonically increasing (linear mock curve)
assert(all(diff(result.powerSeriesVoltages) > 0), ...
    'Power-series voltages should be monotonically increasing for linear curve');

fprintf('\nAll assertions passed.\n');

dmd.cleanup();
daq.cleanup();
