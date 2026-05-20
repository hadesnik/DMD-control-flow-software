function curve = powerMeterSweep(daq, options)
%powerMeterSweep Characterise FS-50 laser power vs. AO control voltage.
%   Two-phase calibration that accounts for non-linear pulse-picker scaling
%   between divided mode (low rep rate) and full rep rate operation.
%
%   Phase 1 — divided mode (~10 kHz): sweeps 0–5 V at safe power levels for
%   the thermal sensor and optics. The operator sets the rep rate manually.
%
%   Phase 2 — full rep rate (~1.25 MHz): sweeps 0–1 V only. The operator
%   switches rep rate manually before this phase begins.
%
%   A zero-intercept linear fit over the 0–1 V overlap region gives a scale
%   factor (P_full = scaleFactor × P_div). Divided-mode readings above 1 V
%   are multiplied by this factor to produce the final merged 0–5 V
%   calibration curve referenced to full rep rate power.
%
%   curve = powerMeterSweep(daq)
%   curve = powerMeterSweep(daq, options)
%
%   Inputs:
%     daq     - tfp.hardware.NI6323_DAQ, already initialized. The AO
%               channel is auto-added to the session if not yet configured.
%     options - struct (all optional):
%       .voltageStepsDiv   - AO voltages for divided-mode sweep (V);
%                            default linspace(0,5,25)
%       .voltageStepsFull  - AO voltages for full-rep-rate sweep (V);
%                            default linspace(0,1,11)
%       .settleTimeS       - dwell after each voltage step (s); default 5.0
%                            (5 s recommended stabilization time for PM100D)
%       .warmupTimeS       - extra wait at first non-zero step in phase 1 (s);
%                            default 5.0
%       .nAverages         - PM100D readings averaged per step; default 5
%       .aoChannel         - DAQ AO channel string; default 'ao1'
%       .fovAreaUm2        - FOV area for power-density calcs (µm²);
%                            default pi*(400)^2  (800 µm diameter circle)
%       .showFigure        - plot curves on completion; default true
%       .wavelengthNm      - wavelength for PM100D spectral correction (nm);
%                            default 1040
%       .repRateDivKhz     - divided-mode rep rate in kHz (informational,
%                            stored in notes); default 10
%       .repRateFullMhz    - full rep rate in MHz (informational); default 1.25
%
%   Output curve struct:
%     .voltageV            - merged voltage axis (V), sorted ascending
%     .powerMw             - merged power at full rep rate (mW)
%     .powerStdMw          - measurement std dev (mW)
%     .scaleFactor         - zero-intercept ratio P_full/P_div over 0–1 V
%     .divMode             - substruct with raw divided-mode sweep:
%                              .voltageV, .powerMw, .powerStdMw
%     .fullRepMode         - substruct with raw full-rep sweep:
%                              .voltageV, .powerMw, .powerStdMw
%     .fovAreaUm2          - FOV area used for density normalisation
%     .wavelengthNm        - wavelength setting on PM100D
%     .settleTimeS         - settle time used (s)
%     .warmupTimeS         - warmup time used (s)
%     .timestamp           - datetime of sweep
%     .notes               - human-readable description string
%     .dmdActivePx         - total DMD pixel count (DLi4130: 768×1024).
%                            Update to 800×1280 when DLP650LNIR arrives.
%
%   See also tfp.calibration.powerMeterSweep_mock, tfp.patterns.powerLUT.

if nargin < 2
    options = struct();
end

voltageStepsDiv  = configField(options, 'voltageStepsDiv',  linspace(0, 5, 25));
voltageStepsFull = configField(options, 'voltageStepsFull', linspace(0, 1, 11));
settleTimeS      = configField(options, 'settleTimeS',   5.0);
warmupTimeS      = configField(options, 'warmupTimeS',   5.0);
nAverages        = configField(options, 'nAverages',     5);
aoChannel        = configField(options, 'aoChannel',     'ao1');
fovAreaUm2       = configField(options, 'fovAreaUm2',    pi * 400^2);
showFigure       = configField(options, 'showFigure',    true);
wavelengthNm     = configField(options, 'wavelengthNm',  1040);
repRateDivKhz    = configField(options, 'repRateDivKhz',  10);
repRateFullMhz   = configField(options, 'repRateFullMhz', 1.25);

voltageStepsDiv  = sort(voltageStepsDiv(:)');
voltageStepsFull = sort(voltageStepsFull(:)');

% --- Connect to PM100D via Thorlabs TLPM driver ---
% TLPM is a MATLAB class provided by the Optical Power Monitor installer.
% findRsrc() returns a device count; getRsrcName(0) returns the USB resource
% string for the first device. Verified against TLPM MATLAB wrapper shipped
% with Optical Power Monitor v3.x. If a future version changes the API,
% check Thorlabs\TLPM\Examples\MATLAB\ for the updated call sequence.
try
    pm = TLPM();
catch
    error('tfp:calibration:powerMeterSweep:noDriver', ...
        ['Thorlabs TLPM driver not found. Install from ' ...
         'https://www.thorlabs.com/software_pages/ViewSoftwarePage.cfm?Code=PM100D']);
end

deviceCount = pm.findRsrc();
if deviceCount < 1
    error('tfp:calibration:powerMeterSweep:noDevice', ...
        'No PM100D found. Check USB connection and Thorlabs Optical Power Monitor software.');
end
resourceName = pm.getRsrcName(0);
pm.init(resourceName, true, true);
pm.setWavelength(wavelengthNm);

% =========================================================
% Phase 1 — divided mode (low rep rate, full voltage range)
% =========================================================
fprintf('\n=== PHASE 1: DIVIDED MODE (%.0f kHz) ===\n', repRateDivKhz);
fprintf('Set the pulse picker to DIVIDED MODE (%.0f kHz) now.\n', repRateDivKhz);
fprintf('Press any key when ready...\n');
pause();

[powerMw_div, powerStd_div] = runSweep(daq, pm, aoChannel, ...
    voltageStepsDiv, settleTimeS, warmupTimeS, nAverages, 'DIV');

% =========================================================
% Phase 2 — full rep rate (low voltage range only)
% =========================================================
fprintf('\n=== PHASE 2: FULL REP RATE (%.2f MHz) ===\n', repRateFullMhz);
fprintf('Switch the pulse picker to FULL REP RATE (%.2f MHz) now.\n', repRateFullMhz);
fprintf('Press any key when ready...\n');
pause();

% No additional warmup for phase 2 — laser is already thermally stable.
[powerMw_full, powerStd_full] = runSweep(daq, pm, aoChannel, ...
    voltageStepsFull, settleTimeS, 0, nAverages, 'FULL');

% Return AO to 0 V (laser off) and close PM100D.
daq.outputSingleAnalog(aoChannel, 0);
pm.close();

% =========================================================
% Scale factor: zero-intercept OLS over the overlap region.
% Fit: P_full = scaleFactor * P_div  (no offset term).
% scaleFactor = sum(P_div * P_full) / sum(P_div^2)
% =========================================================
powerDiv_atFullV = interp1(voltageStepsDiv, powerMw_div, ...
    voltageStepsFull, 'linear', 'extrap');

validMask = powerDiv_atFullV > 0;
if sum(validMask) < 2
    warning('tfp:calibration:powerMeterSweep:tooFewOverlapPoints', ...
        'Fewer than 2 positive overlap points; scale factor defaulting to 1.');
    scaleFactor = 1;
else
    pd = powerDiv_atFullV(validMask);
    pf = powerMw_full(validMask);
    scaleFactor = (pd * pf') / (pd * pd');
end

fprintf('\nScale factor P_full/P_div (0–%.1f V overlap): %.4f\n', ...
    max(voltageStepsFull), scaleFactor);

% =========================================================
% Merge: voltageStepsFull range from direct measurement;
%        voltageStepsDiv above that boundary, scaled up.
% =========================================================
vBoundary   = max(voltageStepsFull);
maskHighDiv = voltageStepsDiv > vBoundary;

voltagesMerged = [voltageStepsFull,  voltageStepsDiv(maskHighDiv)];
powersMerged   = [powerMw_full,      powerMw_div(maskHighDiv) * scaleFactor];
stdMerged      = [powerStd_full,     powerStd_div(maskHighDiv) * scaleFactor];

[voltagesMerged, sortIdx] = sort(voltagesMerged);
powersMerged = powersMerged(sortIdx);
stdMerged    = stdMerged(sortIdx);

% =========================================================
% Assemble output struct
% =========================================================
curve.voltageV    = voltagesMerged;
curve.powerMw     = powersMerged;
curve.powerStdMw  = stdMerged;
curve.scaleFactor = scaleFactor;

curve.divMode.voltageV    = voltageStepsDiv;
curve.divMode.powerMw     = powerMw_div;
curve.divMode.powerStdMw  = powerStd_div;

curve.fullRepMode.voltageV    = voltageStepsFull;
curve.fullRepMode.powerMw     = powerMw_full;
curve.fullRepMode.powerStdMw  = powerStd_full;

curve.fovAreaUm2   = fovAreaUm2;
curve.wavelengthNm = wavelengthNm;
curve.settleTimeS  = settleTimeS;
curve.warmupTimeS  = warmupTimeS;
curve.timestamp    = datetime('now');
curve.notes        = sprintf( ...
    'PM100D+S350C, %s, div %.0f kHz (0-5V) + full %.2f MHz (0-%.1fV), scale=%.4f, %d nm', ...
    aoChannel, repRateDivKhz, repRateFullMhz, vBoundary, scaleFactor, wavelengthNm);
curve.dmdActivePx  = 768 * 1024;  % DLi4130; change to 800*1280 for DLP650LNIR

if showFigure
    plotCurves(curve, scaleFactor);
end

end

% =========================================================
% Local: run one voltage sweep, return mean power and std
% =========================================================
function [powerMw, powerStd] = runSweep(daq, pm, aoChannel, ...
        voltageSteps, settleTimeS, warmupTimeS, nAverages, label)

nSteps   = numel(voltageSteps);
powerMw  = zeros(1, nSteps);
powerStd = zeros(1, nSteps);

if warmupTimeS > 0
    idxWarm = find(voltageSteps > 0, 1, 'first');
    warmupV = voltageSteps(max(1, idxWarm));
    daq.outputSingleAnalog(aoChannel, warmupV);
    estSecs = warmupTimeS + nSteps * settleTimeS + nSteps * (nAverages - 1) * 0.5;
    fprintf('[%s] Warmup: %.2f V for %.1f s  (est. sweep: %.0f s = %.1f min)...\n', ...
        label, warmupV, warmupTimeS, estSecs, estSecs / 60);
    pause(warmupTimeS);
end

try
    for k = 1:nSteps
        v = voltageSteps(k);
        daq.outputSingleAnalog(aoChannel, v);
        pause(settleTimeS);

        readings = zeros(1, nAverages);
        for j = 1:nAverages
            readings(j) = pm.measPower() * 1e3;  % W -> mW
            if j < nAverages
                pause(0.5);
            end
        end

        powerMw(k)  = mean(readings);
        powerStd(k) = std(readings);
        fprintf('[%s] Step %d/%d: %.2f V -> %.3f mW\n', label, k, nSteps, v, powerMw(k));
    end
catch ME
    try, daq.outputSingleAnalog(aoChannel, 0); catch, end
    try, pm.close();                            catch, end
    rethrow(ME);
end

end

% =========================================================
% Local: figure with two panels
% =========================================================
function plotCurves(curve, scaleFactor)
figure('Name', 'powerMeterSweep', 'NumberTitle', 'off');

subplot(1, 2, 1);
hold on;
errorbar(curve.divMode.voltageV, curve.divMode.powerMw, curve.divMode.powerStdMw, ...
    'b-o', 'LineWidth', 1.2, 'DisplayName', 'Divided mode (raw)');
errorbar(curve.fullRepMode.voltageV, curve.fullRepMode.powerMw, curve.fullRepMode.powerStdMw, ...
    'r-s', 'LineWidth', 1.2, 'DisplayName', 'Full rep rate (measured)');
errorbar(curve.divMode.voltageV, curve.divMode.powerMw * scaleFactor, ...
    curve.divMode.powerStdMw * scaleFactor, 'b--', 'LineWidth', 1.0, ...
    'DisplayName', sprintf('Divided \\times %.3f (scaled)', scaleFactor));
xline(max(curve.fullRepMode.voltageV), 'k--', 'LineWidth', 0.8, ...
    'Label', 'Merge boundary');
xlabel('AO Voltage (V)');
ylabel('Power (mW)');
title('Raw sweeps + scale factor');
legend('Location', 'northwest');
grid on;

subplot(1, 2, 2);
errorbar(curve.voltageV, curve.powerMw, curve.powerStdMw, 'k-o', 'LineWidth', 1.4);
xlabel('AO Voltage (V)');
ylabel('Power at sample (mW)');
title(sprintf('Final merged curve  [scale = %.3f] — %s', ...
    scaleFactor, datestr(curve.timestamp, 'yyyy-mm-dd HH:MM')));
grid on;

end

% =========================================================
% Local helper
% =========================================================
function value = configField(s, name, default)
if isfield(s, name)
    value = s.(name);
else
    value = default;
end
end
