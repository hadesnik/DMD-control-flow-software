%run_powerMeterSweep_quicktest  Fast smoke-test of powerMeterSweep with real hardware.
%
%   Runs the full two-phase sweep against the real NI-6323 DAQ and PM100D,
%   but with minimal steps and waits so the whole run completes in ~2 min.
%   Purpose: verify the code path (including cleanup) does not hang.
%
%   NOT for calibration use -- the data will be coarse and the sensor will
%   not have time to stabilise.  Output is saved with a 'quicktest_' prefix
%   and does NOT update real.yaml.
%
%   Usage:
%     >> run scripts/run_powerMeterSweep_quicktest

repoRoot = fullfile(fileparts(mfilename('fullpath')), '..');
addpath(fullfile(repoRoot, 'src'));
addpath(fullfile(repoRoot, 'vendor', 'thorlabs'));

% --- DAQ configuration ---
config.deviceName = 'Dev1';
config.sampleRate = 10000;

d = tfp.hardware.NI6323_DAQ(config);

% --- Minimal sweep options ---
options.voltageStepsDiv  = linspace(0.4, 1.4, 3);  % 3 steps only
options.voltageStepsFull = linspace(0.4, 1.4, 3);  % 3 steps only
options.settleTimeS      = 0.5;   % no sensor stabilisation
options.warmupTimeS      = 0;     % no warmup
options.nAverages        = 1;     % single reading per step
options.sensorRelaxTimeS = 2;     % 2 s instead of 20 s
options.aoChannel        = 'ao3';
options.fovAreaUm2       = pi * 400^2;
options.showFigure       = true;
options.wavelengthNm     = 1040;
options.repRateDivKhz    = 10;
options.repRateFullMhz   = 1.25;

fprintf('=== QUICKTEST MODE: minimal steps, no stabilisation waits ===\n');
fprintf('Follow the on-screen prompts to switch rep rate between phases.\n\n');

curve = tfp.calibration.powerMeterSweep(d, options);

% --- Save with quicktest prefix (does NOT update real.yaml) ---
calibDir = fullfile(repoRoot, 'data', 'calibration');
if ~exist(calibDir, 'dir')
    mkdir(calibDir);
end
fname = sprintf('quicktest_power_curve_%s.mat', datestr(curve.timestamp, 'yyyymmdd_HHMMSS'));
fpath = fullfile(calibDir, fname);
save(fpath, 'curve');
fprintf('\nSaved (quicktest only -- not written to config): %s\n', fpath);
fprintf('Deg-1 fit coeff: %.4f\n', curve.fitDeg1Coeff);
fprintf('Deg-2 fit RMSE:  %.3f mW\n', curve.fitRmseDeg2);

d.outputSingleAnalog('ao3', 0);
d.cleanup();
fprintf('Done.\n');
