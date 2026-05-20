%run_powerMeterSweep  Two-phase FS-50 power calibration vs. ao1 voltage.
%
%   Runs tfp.calibration.powerMeterSweep on the scope PC using the
%   NI-6323 DAQ (Dev1) and a Thorlabs PM100D + S350C sensor.
%
%   Phase 1 (divided mode, ~10 kHz): sweeps 0.4–5 V at low total power so
%   the thermal sensor and optics are safe.  Phase 2 (full rep rate,
%   1.25 MHz): sweeps 0.4–1.4 V only.  A zero-intercept scale factor derived
%   from the 0–1 V overlap is used to translate the divided-mode 1–5 V
%   readings to full-rep-rate equivalent power, producing a single merged
%   calibration curve.
%
%   The routine prompts you to switch the pulse picker rep rate between
%   phases — follow the on-screen instructions.
%
%   Prerequisites:
%     1. Thorlabs Optical Power Monitor (TLPM MATLAB driver) installed.
%     2. PM100D connected via USB; S350C sensor attached.
%     3. FS-50 ao1 BNC connected to Dev1/ao1 on the NI-6323.
%     4. Beam path aligned; sensor placed at sample plane (or exit pupil
%        for relative calibration — note position in the saved notes field).
%
%   Usage:
%     cd to repo root, then run from the MATLAB command window:
%       >> run scripts/run_powerMeterSweep
%     or add src/ to path first:
%       >> addpath(fullfile(pwd, 'src'));
%       >> run scripts/run_powerMeterSweep

repoRoot = fullfile(fileparts(mfilename('fullpath')), '..');
addpath(fullfile(repoRoot, 'src'));
addpath(fullfile(repoRoot, 'vendor', 'thorlabs'));

% --- Config to update after calibration ---
configPath = fullfile(repoRoot, 'configs', 'real.yaml');

% --- DAQ configuration ---
config.deviceName = 'Dev1';
config.sampleRate = 10000;

d = tfp.hardware.NI6323_DAQ(config);
cleanupObj = onCleanup(@() d.outputSingleAnalog('ao3', 0));  % zero on any exit

% --- Sweep options ---
options.voltageStepsDiv  = linspace(0.4, 5, 24);  % Phase 1: 0.4–5 V, 24 steps (no power below 0.4 V)
options.voltageStepsFull = linspace(0.4, 1.4, 11);  % Phase 2: 0.4–1.4 V, 11 steps
options.settleTimeS      = 5.0;                 % 5 s recommended PM100D stabilization
options.warmupTimeS      = 5.0;                 % thermal equilibration at start
options.nAverages        = 5;                   % readings averaged per step
options.aoChannel        = 'ao3';               % FS-50 modulation input (Dev1/ao3)
options.fovAreaUm2       = pi * 400^2;          % 800 µm diameter circle
options.showFigure       = true;
options.wavelengthNm     = 1040;                % FS-50 centre wavelength
options.repRateDivKhz    = 10;                  % divided-mode rep rate
options.repRateFullMhz   = 1.25;                % full rep rate

% --- Run two-phase sweep ---
fprintf('Starting two-phase power meter sweep.\n');
fprintf('  Phase 1: %d steps, 0.4–5 V (divided mode)\n', numel(options.voltageStepsDiv));
fprintf('  Phase 2: %d steps, 0.4–1.4 V (full rep rate)\n', numel(options.voltageStepsFull));
fprintf('Follow the on-screen prompts to switch rep rate between phases.\n\n');

curve = tfp.calibration.powerMeterSweep(d, options);

% --- Save to data/calibration/ ---
calibDir = fullfile(repoRoot, 'data', 'calibration');
if ~exist(calibDir, 'dir')
    mkdir(calibDir);
end
fname = sprintf('power_curve_%s.mat', datestr(curve.timestamp, 'yyyymmdd_HHMMSS'));
fpath = fullfile(calibDir, fname);
save(fpath, 'curve');
fprintf('\nSaved: %s\n', fpath);
fprintf('Scale factor (P_full/P_div): %.4f\n', curve.scaleFactor);
fprintf('Peak power (merged curve):   %.2f mW at %.1f V\n', ...
    max(curve.powerMw), curve.voltageV(curve.powerMw == max(curve.powerMw)));

% --- Update laser.calibration_file in config (always points to latest run) ---
try
    cfgText  = fileread(configPath);
    fpathFwd = strrep(fpath, '\', '/');  % YAML-safe forward slashes
    cfgText  = regexprep(cfgText, ...
        '(laser:[\s\S]*?calibration_file:\s*)(''[^'']*''|"[^"]*"|[^\r\n]*)', ...
        ['$1''' fpathFwd '''']);
    fid = fopen(configPath, 'w');
    fprintf(fid, '%s', cfgText);
    fclose(fid);
    fprintf('Updated laser.calibration_file in: %s\n', configPath);
catch ME
    warning('tfp:calibration:powerMeterSweep:configUpdateFailed', ...
        'Could not update config: %s\nSet laser.calibration_file manually to: %s', ...
        ME.message, fpath);
end

d.outputSingleAnalog('ao3', 0);
d.cleanup();
