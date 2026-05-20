%run_powerMeterSweep  Characterise FS-50 power vs. ao1 control voltage.
%
%   Runs tfp.calibration.powerMeterSweep on the scope PC using the
%   NI-6323 DAQ (Dev1) and a Thorlabs PM100D + S350C sensor.  The
%   resulting curve is saved as 'power_curve_<date>.mat' in the current
%   directory and can be loaded into a calibration struct for powerLUT.
%
%   Prerequisites:
%     1. Thorlabs Optical Power Monitor (TLPM MATLAB driver) installed.
%     2. PM100D connected via USB; S350C sensor attached.
%     3. FS-50 ao1 BNC connected to Dev1/ao1 on the NI-6323.
%     4. Beam path aligned; sensor placed at sample plane (or exit pupil
%        for relative calibration — note position in the saved notes field).
%
%   Usage:
%     cd to repo root, then run this script from the MATLAB command window:
%       >> run scripts/run_powerMeterSweep
%     or add +tfp to path first:
%       >> addpath(fullfile(pwd, 'src'));
%       >> run scripts/run_powerMeterSweep

addpath(fullfile(fileparts(mfilename('fullpath')), '..', 'src'));

% --- DAQ configuration ---
config.deviceName  = 'Dev1';
config.sampleRate  = 10000;

d = tfp.hardware.NI6323_DAQ(config);

% --- Sweep options ---
options.voltageSteps = linspace(0, 5, 25);  % 0–5 V in 25 steps
options.settleTimeS  = 0.1;                 % 100 ms settle (thermal sensor)
options.nAverages    = 5;                   % readings averaged per step
options.aoChannel    = 'ao1';               % FS-50 modulation input
options.fovAreaUm2   = pi * 400^2;          % 800 µm diameter circle
options.showFigure   = true;
options.wavelengthNm = 1040;                % FS-50 centre wavelength

% --- Run sweep ---
fprintf('Starting power meter sweep (%d steps × %d averages)...\n', ...
    numel(options.voltageSteps), options.nAverages);

curve = tfp.calibration.powerMeterSweep(d, options);

% --- Save ---
fname = sprintf('power_curve_%s.mat', datestr(curve.timestamp, 'yyyymmdd_HHMMSS'));
save(fname, 'curve');
fprintf('Saved: %s\n', fname);
fprintf('Peak power: %.2f mW at %.1f V\n', max(curve.powerMw), ...
    curve.voltageV(curve.powerMw == max(curve.powerMw)));

d.cleanup();
