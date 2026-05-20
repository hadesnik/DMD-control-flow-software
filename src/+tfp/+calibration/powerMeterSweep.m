function curve = powerMeterSweep(daq, options)
%powerMeterSweep Characterise FS-50 laser power vs. AO control voltage.
%   Two-phase calibration that accounts for non-linear pulse-picker scaling
%   between divided mode (low rep rate) and full rep rate operation.
%
%   Phase 1 — divided mode (~10 kHz): sweeps 0-5 V at safe power levels for
%   the thermal sensor and optics. The operator sets the rep rate manually.
%
%   Phase 2 — full rep rate (~1.25 MHz): sweeps 0-1 V only. The operator
%   switches rep rate manually before this phase begins.
%
%   A zero-intercept linear fit over the 0-1 V overlap region gives a scale
%   factor (P_full = scaleFactor * P_div). Divided-mode readings above 1 V
%   are multiplied by this factor to produce the final merged 0-5 V
%   calibration curve referenced to full rep rate power.
%
%   curve = powerMeterSweep(daq)
%   curve = powerMeterSweep(daq, options)
%
%   Inputs:
%     daq     - tfp.hardware.NI6323_DAQ, already initialized.
%     options - struct (all optional):
%       .voltageStepsDiv   - AO voltages for divided-mode sweep (V);
%                            default linspace(0,5,25)
%       .voltageStepsFull  - AO voltages for full-rep-rate sweep (V);
%                            default linspace(0,1,11)
%       .settleTimeS       - dwell after each voltage step (s); default 5.0
%       .warmupTimeS       - extra wait at first non-zero step (s); default 5.0
%       .nAverages         - PM100D readings averaged per step; default 5
%       .aoChannel         - DAQ AO channel string; default 'ao3' (FS-50)
%       .fovAreaUm2        - FOV area for power-density calcs (um^2);
%                            default pi*(400)^2  (800 um diameter circle)
%       .showFigure        - show live figure during sweep; default true
%       .wavelengthNm      - wavelength for PM100D spectral correction (nm);
%                            default 1040
%       .repRateDivKhz     - divided-mode rep rate in kHz; default 10
%       .repRateFullMhz    - full rep rate in MHz; default 1.25
%
%   Output curve struct:
%     .voltageV            - merged voltage axis (V), sorted ascending
%     .powerMw             - merged power at full rep rate (mW)
%     .powerStdMw          - measurement std dev (mW)
%     .scaleFactor         - zero-intercept ratio P_full/P_div over 0-1 V
%     .divMode             - substruct: .voltageV, .powerMw, .powerStdMw
%     .fullRepMode         - substruct: .voltageV, .powerMw, .powerStdMw
%     .fovAreaUm2          - FOV area used for density normalisation
%     .wavelengthNm        - wavelength setting on PM100D
%     .settleTimeS, .warmupTimeS, .timestamp, .notes, .dmdActivePx
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
aoChannel        = configField(options, 'aoChannel',     'ao3');
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

% --- Create live figure: [Phase 1 | Phase 2 | Merged] ---
if showFigure
    fig = figure('Name', 'powerMeterSweep', 'NumberTitle', 'off', ...
                 'Position', [80 200 1400 480]);

    ax1 = subplot(1, 3, 1, 'Parent', fig);
    title(ax1, sprintf('Phase 1 — Divided Mode (%.0f kHz)', repRateDivKhz));
    xlabel(ax1, 'AO Voltage (V)');  ylabel(ax1, 'Power (mW)');
    xlim(ax1, [min(voltageStepsDiv) - 0.1, max(voltageStepsDiv) + 0.1]);
    grid(ax1, 'on');  hold(ax1, 'on');

    ax2 = subplot(1, 3, 2, 'Parent', fig);
    title(ax2, sprintf('Phase 2 — Full Rep Rate (%.2f MHz)', repRateFullMhz));
    xlabel(ax2, 'AO Voltage (V)');  ylabel(ax2, 'Power (mW)');
    xlim(ax2, [min(voltageStepsFull) - 0.05, max(voltageStepsFull) + 0.05]);
    grid(ax2, 'on');  hold(ax2, 'on');

    ax3 = subplot(1, 3, 3, 'Parent', fig);
    title(ax3, 'Merged curve (full rep rate equivalent)');
    xlabel(ax3, 'AO Voltage (V)');  ylabel(ax3, 'Power at sample (mW)');
    grid(ax3, 'on');

    drawnow;
else
    ax1 = [];
    ax2 = [];
    ax3 = [];
end

% =========================================================
% Phase 1 — divided mode
% =========================================================
fprintf('\n=== PHASE 1: DIVIDED MODE (%.0f kHz) ===\n', repRateDivKhz);
fprintf('Set the pulse picker to DIVIDED MODE (%.0f kHz) now.\n', repRateDivKhz);
fprintf('Press any key when ready...\n');
pause();

[powerMw_div, powerStd_div] = runSweep(daq, pm, aoChannel, ...
    voltageStepsDiv, settleTimeS, warmupTimeS, nAverages, ...
    sprintf('DIV %.0f kHz', repRateDivKhz), ax1);

% =========================================================
% Phase 2 — full rep rate
% =========================================================
fprintf('\n=== PHASE 2: FULL REP RATE (%.2f MHz) ===\n', repRateFullMhz);
fprintf('Switch the pulse picker to FULL REP RATE (%.2f MHz) now.\n', repRateFullMhz);
fprintf('Press any key when ready...\n');
pause();

[powerMw_full, powerStd_full] = runSweep(daq, pm, aoChannel, ...
    voltageStepsFull, settleTimeS, 0, nAverages, ...
    sprintf('FULL %.2f MHz', repRateFullMhz), ax2);

% Return AO to 0 V (laser off) and close PM100D.
daq.outputSingleAnalog(aoChannel, 0);
pm.close();

% =========================================================
% Scale factor: zero-intercept OLS over the overlap region.
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

fprintf('\nScale factor P_full/P_div (0-%.1f V overlap): %.4f\n', ...
    max(voltageStepsFull), scaleFactor);

% =========================================================
% Merge
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
curve.dmdActivePx  = 768 * 1024;  % DLi4130; update to 800*1280 for DLP650LNIR

% =========================================================
% Fill merged panel and annotate Phase 1 with scale overlay
% =========================================================
if showFigure && ~isempty(ax3)
    try
        % Panel 3: merged curve
        errorbar(ax3, curve.voltageV, curve.powerMw, curve.powerStdMw, ...
            'k-o', 'LineWidth', 1.4);
        title(ax3, sprintf('Merged  [scale = %.3f]  %s', ...
            scaleFactor, datestr(curve.timestamp, 'yyyy-mm-dd HH:MM')));
        grid(ax3, 'on');

        % Panel 1: add scaled overlay so both modes are comparable
        errorbar(ax1, curve.divMode.voltageV, curve.divMode.powerMw * scaleFactor, ...
            curve.divMode.powerStdMw * scaleFactor, 'b--', 'LineWidth', 1.0, ...
            'DisplayName', sprintf('x%.3f (full-rate equiv.)', scaleFactor));
        xline(ax1, vBoundary, 'k--', 'LineWidth', 0.8);
        legend(ax1, 'Location', 'northwest');

        drawnow;
    catch
    end
end

end

% =========================================================
% Local: run one voltage sweep with live figure update
% =========================================================
function [powerMw, powerStd] = runSweep(daq, pm, aoChannel, ...
        voltageSteps, settleTimeS, warmupTimeS, nAverages, label, liveAx)

nSteps   = numel(voltageSteps);
powerMw  = zeros(1, nSteps);
powerStd = zeros(1, nSteps);

hasAx = nargin >= 9 && ~isempty(liveAx) && isvalid(liveAx);

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
        fprintf('[%s] Step %d/%d: %.2f V -> %.3f +/- %.4f mW\n', ...
            label, k, nSteps, v, powerMw(k), powerStd(k));

        % Live figure update
        if hasAx
            try
                cla(liveAx);
                errorbar(liveAx, voltageSteps(1:k), powerMw(1:k), powerStd(1:k), ...
                    'o-', 'LineWidth', 1.4, 'MarkerFaceColor', 'auto');
                title(liveAx, sprintf('%s — step %d/%d  (%.3f mW)', ...
                    label, k, nSteps, powerMw(k)));
                xlabel(liveAx, 'AO Voltage (V)');
                ylabel(liveAx, 'Power (mW)');
                grid(liveAx, 'on');
                drawnow;
            catch
            end
        end
    end
catch ME
    try, daq.outputSingleAnalog(aoChannel, 0); catch, end
    try, pm.close();                            catch, end
    rethrow(ME);
end

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
