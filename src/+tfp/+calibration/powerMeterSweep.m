function curve = powerMeterSweep(daq, options)
%powerMeterSweep Characterise FS-50 laser power vs. AO control voltage.
%   Two-phase calibration that accounts for non-linear pulse-picker scaling
%   between divided mode (low rep rate) and full rep rate operation.
%
%   Phase 1 - divided mode (~10 kHz): sweeps 0-5 V at safe power levels for
%   the thermal sensor and optics. The operator sets the rep rate manually.
%
%   Phase 2 - full rep rate (~1.25 MHz): sweeps 0-1 V only. The operator
%   switches rep rate manually before this phase begins.
%
%   In the overlap voltage region both phases were measured directly.
%   A zero-intercept polynomial (degree 1 and 2) is fitted to the
%   (P_div, P_full) pairs in that region. Divided-mode readings above the
%   overlap are mapped to full-rep-rate equivalent power via the degree-2
%   fit, which captures any nonlinearity in the ratio without assuming a
%   constant scale factor. A diagnostic panel shows both fits and their
%   residuals so the operator can verify the degree-1 approximation is
%   adequate.
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
%     .powerStdMw          - measurement std dev (mW), propagated through fit
%     .fitDeg1Coeff        - scalar a: P_full = a * P_div (zero-intercept)
%     .fitDeg2Coeffs       - [a, b]: P_full = a*P_div + b*P_div^2
%     .fitRmseDeg1         - overlap-region RMSE of degree-1 fit (mW)
%     .fitRmseDeg2         - overlap-region RMSE of degree-2 fit (mW)
%     .scaleFactor         - alias for fitDeg1Coeff (backward compat)
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

% --- Create live figure: 2x2 layout ---
if showFigure
    fig = figure('Name', 'powerMeterSweep', 'NumberTitle', 'off', ...
                 'Position', [80 80 1400 900]);

    ax1 = subplot(2, 2, 1, 'Parent', fig);
    title(ax1, sprintf('Phase 1 - Divided Mode (%.0f kHz)', repRateDivKhz));
    xlabel(ax1, 'AO Voltage (V)');  ylabel(ax1, 'Power (mW)');
    xlim(ax1, [min(voltageStepsDiv) - 0.1, max(voltageStepsDiv) + 0.1]);
    grid(ax1, 'on');  hold(ax1, 'on');

    ax2 = subplot(2, 2, 2, 'Parent', fig);
    title(ax2, sprintf('Phase 2 - Full Rep Rate (%.2f MHz)', repRateFullMhz));
    xlabel(ax2, 'AO Voltage (V)');  ylabel(ax2, 'Power (mW)');
    xlim(ax2, [min(voltageStepsFull) - 0.05, max(voltageStepsFull) + 0.05]);
    grid(ax2, 'on');  hold(ax2, 'on');

    ax3 = subplot(2, 2, 4, 'Parent', fig);
    title(ax3, 'Merged curve (full rep rate equivalent)');
    xlabel(ax3, 'AO Voltage (V)');  ylabel(ax3, 'Power at sample (mW)');
    grid(ax3, 'on');

    ax4 = subplot(2, 2, 3, 'Parent', fig);
    title(ax4, 'Overlap fit: P_{full} vs P_{div}');
    xlabel(ax4, 'P_{div} (mW)');  ylabel(ax4, 'P_{full} (mW)');
    grid(ax4, 'on');  hold(ax4, 'on');

    drawnow;
else
    ax1 = [];
    ax2 = [];
    ax3 = [];
    ax4 = [];
end

% =========================================================
% Phase 1 - divided mode
% =========================================================
fprintf('\n=== PHASE 1: DIVIDED MODE (%.0f kHz) ===\n', repRateDivKhz);
fprintf('Set the pulse picker to DIVIDED MODE (%.0f kHz) now.\n', repRateDivKhz);
fprintf('Press any key when ready...\n');
pause();

[powerMw_div, powerStd_div] = runSweep(daq, pm, aoChannel, ...
    voltageStepsDiv, settleTimeS, warmupTimeS, nAverages, ...
    sprintf('DIV %.0f kHz', repRateDivKhz), ax1);

% =========================================================
% Phase 2 - full rep rate
% =========================================================
% Zero AO before prompting rep-rate switch -- laser must be off while
% the operator changes pulse-picker settings.
daq.outputSingleAnalog(aoChannel, 0);

fprintf('\n=== PHASE 2: FULL REP RATE (%.2f MHz) ===\n', repRateFullMhz);
fprintf('Switch the pulse picker to FULL REP RATE (%.2f MHz) now.\n', repRateFullMhz);
fprintf('Press any key when ready...\n');
pause();

fprintf('Waiting 20 s for thermal sensor to relax to zero...\n');
pause(20);

[powerMw_full, powerStd_full] = runSweep(daq, pm, aoChannel, ...
    voltageStepsFull, settleTimeS, 0, nAverages, ...
    sprintf('FULL %.2f MHz', repRateFullMhz), ax2);

% Return AO to 0 V (laser off) and close PM100D.
daq.outputSingleAnalog(aoChannel, 0);
pm.close();

% =========================================================
% Power-space fit over the overlap region.
%   Degree 1 (zero-intercept): P_full = a * P_div
%   Degree 2 (zero-intercept): P_full = a*P_div + b*P_div^2
% Fitting in power space captures any voltage-dependent ratio without
% assuming the nonlinearity is identical in both modes.
% =========================================================
powerDiv_atFullV = interp1(voltageStepsDiv, powerMw_div, ...
    voltageStepsFull, 'linear', 'extrap');

validMask = powerDiv_atFullV > 0 & powerMw_full > 0;
if sum(validMask) < 2
    warning('tfp:calibration:powerMeterSweep:tooFewOverlapPoints', ...
        'Fewer than 2 positive overlap points; fit defaulting to identity.');
    fitDeg1 = 1;
    fitDeg2 = [1, 0];
    rmse1   = NaN;
    rmse2   = NaN;
else
    pd = powerDiv_atFullV(validMask)';   % column vectors for OLS
    pf = powerMw_full(validMask)';

    % Degree-1 zero-intercept OLS: minimise ||pf - a*pd||^2
    fitDeg1 = (pd' * pf) / (pd' * pd);
    resid1  = pf - fitDeg1 * pd;
    rmse1   = sqrt(mean(resid1.^2));

    % Degree-2 zero-intercept OLS: [a; b] = (X'X)\(X'pf), X = [pd, pd.^2]
    X2      = [pd, pd.^2];
    fitDeg2 = (X2' * X2) \ (X2' * pf);   % column [a; b]
    resid2  = pf - X2 * fitDeg2;
    rmse2   = sqrt(mean(resid2.^2));
    fitDeg2 = fitDeg2';                   % store as row [a, b]
end

fprintf('\nPower-space fit over overlap region (%.1f-%.1f V):\n', ...
    min(voltageStepsFull), max(voltageStepsFull));
fprintf('  Deg-1  P_full = %.4f * P_div                       RMSE = %.3f mW\n', ...
    fitDeg1, rmse1);
fprintf('  Deg-2  P_full = %.4f*P_div + %.2e*P_div^2   RMSE = %.3f mW\n', ...
    fitDeg2(1), fitDeg2(2), rmse2);
if ~isnan(rmse1) && rmse2 < 0.5 * rmse1
    fprintf('  ** Deg-2 RMSE is substantially lower -- nonlinear ratio detected.\n');
end

% =========================================================
% Merge: Phase 2 measured directly for V <= vBoundary;
%        degree-2 power-space map applied to Phase 1 above vBoundary.
% =========================================================
vBoundary   = max(voltageStepsFull);
maskHighDiv = voltageStepsDiv > vBoundary;

pdHigh  = powerMw_div(maskHighDiv);
% P_full = a*P_div + b*P_div^2
pfHigh  = fitDeg2(1) * pdHigh + fitDeg2(2) * pdHigh.^2;
% Error propagation: sigma_P_full = |dP_full/dP_div| * sigma_P_div
dfdp    = abs(fitDeg2(1) + 2 * fitDeg2(2) * pdHigh);
stdHigh = dfdp .* powerStd_div(maskHighDiv);

voltagesMerged = [voltageStepsFull,  voltageStepsDiv(maskHighDiv)];
powersMerged   = [powerMw_full,      pfHigh];
stdMerged      = [powerStd_full,     stdHigh];

[voltagesMerged, sortIdx] = sort(voltagesMerged);
powersMerged = powersMerged(sortIdx);
stdMerged    = stdMerged(sortIdx);

% =========================================================
% Assemble output struct
% =========================================================
curve.voltageV      = voltagesMerged;
curve.powerMw       = powersMerged;
curve.powerStdMw    = stdMerged;
curve.fitDeg1Coeff  = fitDeg1;          % scalar a
curve.fitDeg2Coeffs = fitDeg2;          % [a, b]: P_full = a*P_div + b*P_div^2
curve.fitRmseDeg1   = rmse1;
curve.fitRmseDeg2   = rmse2;
curve.scaleFactor   = fitDeg1;          % backward-compat alias

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
    'PM100D+S350C, %s, div %.0f kHz + full %.2f MHz (overlap %.1f-%.1f V), deg2=[%.4f %.2e] rmse1=%.3f rmse2=%.3f mW, %d nm', ...
    aoChannel, repRateDivKhz, repRateFullMhz, min(voltageStepsFull), vBoundary, ...
    fitDeg2(1), fitDeg2(2), rmse1, rmse2, wavelengthNm);
curve.dmdActivePx  = 768 * 1024;  % DLi4130; update to 800*1280 for DLP650LNIR

% =========================================================
% Fill post-sweep panels (diagnostic + merged + Phase 1 overlay)
% =========================================================
if showFigure
    try
        % Panel 3 (bottom-left): power-space fit diagnostic
        if ~isempty(ax4) && isvalid(ax4) && sum(validMask) >= 2
            pdPlot = powerDiv_atFullV(validMask);
            pfPlot = powerMw_full(validMask);
            pRange = linspace(0, max(pdPlot) * 1.15, 300);

            scatter(ax4, pdPlot, pfPlot, 50, 'ko', 'filled', 'DisplayName', 'Measured');
            plot(ax4, pRange, fitDeg1 * pRange, 'b-', 'LineWidth', 1.8, ...
                'DisplayName', sprintf('Deg-1  a=%.4f  RMSE=%.2f mW', fitDeg1, rmse1));
            plot(ax4, pRange, fitDeg2(1)*pRange + fitDeg2(2)*pRange.^2, 'r--', ...
                'LineWidth', 1.8, ...
                'DisplayName', sprintf('Deg-2  a=%.4f b=%.2e  RMSE=%.2f mW', ...
                    fitDeg2(1), fitDeg2(2), rmse2));
            legend(ax4, 'Location', 'northwest');
            title(ax4, sprintf('Overlap fit  (%.1f-%.1f V)', ...
                min(voltageStepsFull), vBoundary));
            grid(ax4, 'on');
        end

        % Panel 4 (bottom-right): merged curve
        if ~isempty(ax3) && isvalid(ax3)
            errorbar(ax3, curve.voltageV, curve.powerMw, curve.powerStdMw, ...
                'k-o', 'LineWidth', 1.4);
            xline(ax3, vBoundary, 'r:', 'LineWidth', 1.2, ...
                'DisplayName', 'fit boundary');
            title(ax3, sprintf('Merged  %s', ...
                datestr(curve.timestamp, 'yyyy-mm-dd HH:MM')));
            grid(ax3, 'on');
        end

        % Panel 1 (top-left): overlay deg-2 mapped Phase 1 for visual check
        if ~isempty(ax1) && isvalid(ax1)
            pdAll  = curve.divMode.powerMw;
            pfAll  = fitDeg2(1)*pdAll + fitDeg2(2)*pdAll.^2;
            stdAll = abs(fitDeg2(1) + 2*fitDeg2(2)*pdAll) .* curve.divMode.powerStdMw;
            errorbar(ax1, curve.divMode.voltageV, pfAll, stdAll, ...
                'r--', 'LineWidth', 1.0, ...
                'DisplayName', 'deg-2 mapped (full-rate equiv.)');
            xline(ax1, vBoundary, 'k:', 'LineWidth', 0.8);
            legend(ax1, 'Location', 'northwest');
        end

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
                title(liveAx, sprintf('%s - step %d/%d  (%.3f mW)', ...
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
