function curve = powerMeterSweep(daq, options)
%powerMeterSweep Characterise FS-50 laser power vs. AO control voltage.
%   Sweeps the DAQ AO voltage driving the FS-50 fast power modulation input
%   and records sample-plane power with a Thorlabs PM100D (S350C thermal
%   sensor) at each step. The output struct is compatible with
%   tfp.patterns.powerLUT for converting target power to DMD duty cycle.
%
%   Requires the Thorlabs TLPM MATLAB driver, installed with the Optical
%   Power Monitor application:
%   https://www.thorlabs.com/software_pages/ViewSoftwarePage.cfm?Code=PM100D
%
%   curve = powerMeterSweep(daq)
%   curve = powerMeterSweep(daq, options)
%
%   Inputs:
%     daq     - tfp.hardware.NI6323_DAQ, already initialized. The AO
%               channel is auto-added to the session if not yet configured.
%     options - struct (all optional):
%       .voltageSteps  - AO voltages to test (V); default linspace(0,5,25)
%       .settleTimeS   - dwell after each step before reading (s); default 3.0
%                        (S350C thermal sensor has ~3 s response time)
%       .warmupTimeS   - extra wait at the first non-zero step before the sweep
%                        begins; default 5.0  (thermal equilibration)
%       .nAverages     - PM100D readings averaged per step; default 5
%       .aoChannel     - DAQ AO channel string, e.g. 'ao1'; default 'ao1'
%       .fovAreaUm2    - FOV area for power-density calculations (µm²);
%                        default pi*(400)^2  (800 µm diameter circle)
%       .showFigure    - plot curve on completion; default true
%       .wavelengthNm  - wavelength for PM100D spectral correction (nm);
%                        default 1040
%
%   Output curve struct:
%     .voltageV      - voltage steps (V), 1×N
%     .powerMw       - mean power at each step (mW), 1×N
%     .powerStdMw    - std dev of nAverages readings (mW), 1×N
%     .fovAreaUm2    - FOV area used for density normalisation
%     .wavelengthNm  - wavelength setting on PM100D
%     .settleTimeS   - settle time used (s)
%     .warmupTimeS   - warmup time used (s)
%     .timestamp     - datetime of sweep
%     .notes         - human-readable description string
%     .dmdActivePx   - total DMD pixel count (DLi4130: 768×1024 = 786432).
%                      The FS-50 controls total beam power; the DMD controls
%                      spatial distribution. These are independent calibration
%                      axes. Update to 800×1280 when the DLP650LNIR arrives.
%
%   See also tfp.calibration.powerMeterSweep_mock, tfp.patterns.powerLUT.

if nargin < 2
    options = struct();
end

voltageSteps = configField(options, 'voltageSteps', linspace(0, 5, 25));
settleTimeS  = configField(options, 'settleTimeS',  3.0);
warmupTimeS  = configField(options, 'warmupTimeS',  5.0);
nAverages    = configField(options, 'nAverages',    5);
aoChannel    = configField(options, 'aoChannel',    'ao1');
fovAreaUm2   = configField(options, 'fovAreaUm2',   pi * 400^2);
showFigure   = configField(options, 'showFigure',   true);
wavelengthNm = configField(options, 'wavelengthNm', 1040);

voltageSteps = voltageSteps(:)';
nSteps       = numel(voltageSteps);

% --- Connect to PM100D via Thorlabs TLPM driver ---
% TLPM is a MATLAB class provided by the Optical Power Monitor installer.
% If TLPM is not on the MATLAB path this block will throw and the
% :noDriver error below re-surfaces it with installation instructions.
try
    pm = TLPM();
catch
    error('tfp:calibration:powerMeterSweep:noDriver', ...
        ['Thorlabs TLPM driver not found. Install from ' ...
         'https://www.thorlabs.com/software_pages/ViewSoftwarePage.cfm?Code=PM100D']);
end

resourceName = pm.findRsrc();
pm.init(resourceName, true, true);
pm.setWavelength(wavelengthNm);

% --- Warmup: prime thermal sensor at first non-zero voltage ---
idxWarm = find(voltageSteps > 0, 1, 'first');
warmupV = voltageSteps(max(1, idxWarm));
daq.outputSingleAnalog(aoChannel, warmupV);
estSecs = warmupTimeS + nSteps * settleTimeS + nSteps * (nAverages - 1) * 0.5;
fprintf('Warmup: %.2f V for %.1f s  (est. sweep: %.0f s = %.1f min)...\n', ...
    warmupV, warmupTimeS, estSecs, estSecs / 60);
pause(warmupTimeS);

% --- Sweep all steps ---
powerMw  = zeros(1, nSteps);
powerStd = zeros(1, nSteps);

try
    for k = 1:nSteps
        v = voltageSteps(k);
        daq.outputSingleAnalog(aoChannel, v);
        pause(settleTimeS);

        readings = zeros(1, nAverages);
        for j = 1:nAverages
            % TLPM measPower passes value via a libpointer (legacy driver).
            % If your TLPM version returns the value directly, replace these
            % three lines with: readings(j) = pm.measPower() * 1e3;
            powerPtr    = libpointer('doublePtr', 0);
            pm.measPower(powerPtr);
            readings(j) = powerPtr.Value * 1e3;  % W → mW
            if j < nAverages
                pause(0.5);
            end
        end

        powerMw(k)  = mean(readings);
        powerStd(k) = std(readings);
        fprintf('Step %d/%d: %.2fV -> %.3f mW\n', k, nSteps, v, powerMw(k));
    end
catch ME
    try, daq.outputSingleAnalog(aoChannel, 0); catch, end  % laser off on error
    try, pm.close();                            catch, end
    rethrow(ME);
end

% Return AO to 0 V (laser off) and close PM100D.
daq.outputSingleAnalog(aoChannel, 0);
pm.close();

% --- Assemble output ---
% dmdActivePx is set to the full DLi4130 pixel count (768×1024).
% The FS-50 power calibration assumes all DMD pixels are on; the DMD
% independently controls which pixels are illuminated during stimulation.
% powerLUT uses this field to normalise power per active pixel count.
curve.voltageV     = voltageSteps;
curve.powerMw      = powerMw;
curve.powerStdMw   = powerStd;
curve.fovAreaUm2   = fovAreaUm2;
curve.wavelengthNm = wavelengthNm;
curve.settleTimeS  = settleTimeS;
curve.warmupTimeS  = warmupTimeS;
curve.timestamp    = datetime('now');
curve.notes        = sprintf('PM100D + S350C, %s, %.1f-%.1fV, %dnm', ...
    aoChannel, min(voltageSteps), max(voltageSteps), wavelengthNm);
curve.dmdActivePx  = 768 * 1024;  % DLi4130; change to 800*1280 for DLP650LNIR

if showFigure
    figure('Name', 'powerMeterSweep', 'NumberTitle', 'off');
    errorbar(curve.voltageV, curve.powerMw, curve.powerStdMw, 'o-', 'LineWidth', 1.2);
    xlabel('AO Voltage (V)');
    ylabel('Power at sample (mW)');
    title(sprintf('FS-50 power curve — %s — %s', aoChannel, ...
        datestr(curve.timestamp, 'yyyy-mm-dd HH:MM')));
    grid on;
end

end

% --- Local helper ---

function value = configField(s, name, default)
if isfield(s, name)
    value = s.(name);
else
    value = default;
end
end
