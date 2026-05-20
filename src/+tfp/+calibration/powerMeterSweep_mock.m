function curve = powerMeterSweep_mock(options)
%powerMeterSweep_mock Synthetic two-phase power sweep — no hardware required.
%   Simulates the divided-mode (0–5 V) and full-rep-rate (0–1 V) calibration
%   phases, computes the zero-intercept scale factor, and returns the merged
%   curve.  Output struct matches powerMeterSweep exactly.
%
%   Both synthetic curves share the same sigmoid shape scaled to different
%   amplitudes to mimic the empirical non-linearity of the pulse picker.
%   No pauses or user prompts are issued.
%
%   curve = powerMeterSweep_mock()
%   curve = powerMeterSweep_mock(options)
%
%   options fields (all optional, same defaults as powerMeterSweep):
%     .voltageStepsDiv   - default linspace(0,5,25)
%     .voltageStepsFull  - default linspace(0,1,11)
%     .fovAreaUm2        - default pi*(400)^2
%     .wavelengthNm      - default 1040
%     .aoChannel         - default 'ao1'  (stored in notes only)
%     .showFigure        - default true
%     .repRateDivKhz     - stored in notes; default 10
%     .repRateFullMhz    - stored in notes; default 1.25
%     .maxPowerDivMw     - peak plateau power in divided mode (mW); default 0.5
%     .trueScaleFactor   - underlying full/div power ratio used to generate
%                          the synthetic full-rep data; default 87.3
%                          (non-round: emphasises the empirical nature)
%     .sigmoidK          - sigmoid steepness; default 2
%     .sigmoidV0         - sigmoid midpoint (V); default 2.5
%     .noiseMw           - std dev of simulated PM100D noise (mW); default 0.005
%
%   See also tfp.calibration.powerMeterSweep, tfp.patterns.powerLUT.

if nargin < 1
    options = struct();
end

voltageStepsDiv  = configField(options, 'voltageStepsDiv',  linspace(0, 5, 25));
voltageStepsFull = configField(options, 'voltageStepsFull', linspace(0, 1, 11));
fovAreaUm2       = configField(options, 'fovAreaUm2',   pi * 400^2);
wavelengthNm     = configField(options, 'wavelengthNm', 1040);
aoChannel        = configField(options, 'aoChannel',    'ao1');
showFigure       = configField(options, 'showFigure',   true);
repRateDivKhz    = configField(options, 'repRateDivKhz',  10);
repRateFullMhz   = configField(options, 'repRateFullMhz', 1.25);
maxPowerDivMw    = configField(options, 'maxPowerDivMw',  0.5);
trueScaleFactor  = configField(options, 'trueScaleFactor', 87.3);
k_sig            = configField(options, 'sigmoidK',   2);
v0               = configField(options, 'sigmoidV0',  2.5);
noiseMw          = configField(options, 'noiseMw',    0.005);

voltageStepsDiv  = sort(voltageStepsDiv(:)');
voltageStepsFull = sort(voltageStepsFull(:)');

% --- Phase 1: divided mode (0–5 V) ---
fprintf('[MOCK] Phase 1: divided mode (%.0f kHz), %d steps 0–5 V\n', ...
    repRateDivKhz, numel(voltageStepsDiv));
powerMw_div  = maxPowerDivMw ./ (1 + exp(-k_sig * (voltageStepsDiv - v0)));
powerStd_div = abs(noiseMw * randn(1, numel(voltageStepsDiv)));

% --- Phase 2: full rep rate (0–1 V) ---
% True underlying power = trueScaleFactor * divided-mode sigmoid (same shape).
fprintf('[MOCK] Phase 2: full rep rate (%.2f MHz), %d steps 0–1 V\n', ...
    repRateFullMhz, numel(voltageStepsFull));
powerMw_full  = trueScaleFactor * maxPowerDivMw ./ (1 + exp(-k_sig * (voltageStepsFull - v0)));
powerStd_full = abs(noiseMw * trueScaleFactor * randn(1, numel(voltageStepsFull)));

% --- Scale factor: zero-intercept OLS over the 0–1 V overlap ---
powerDiv_atFullV = interp1(voltageStepsDiv, powerMw_div, ...
    voltageStepsFull, 'linear', 'extrap');

validMask = powerDiv_atFullV > 0;
if sum(validMask) < 2
    warning('tfp:calibration:powerMeterSweep_mock:tooFewOverlapPoints', ...
        'Fewer than 2 positive overlap points; scale factor defaulting to 1.');
    scaleFactor = 1;
else
    pd = powerDiv_atFullV(validMask);
    pf = powerMw_full(validMask);
    scaleFactor = (pd * pf') / (pd * pd');
end

fprintf('[MOCK] Scale factor P_full/P_div: %.4f  (true: %.4f)\n', ...
    scaleFactor, trueScaleFactor);

% --- Merge ---
vBoundary   = max(voltageStepsFull);
maskHighDiv = voltageStepsDiv > vBoundary;

voltagesMerged = [voltageStepsFull,  voltageStepsDiv(maskHighDiv)];
powersMerged   = [powerMw_full,      powerMw_div(maskHighDiv) * scaleFactor];
stdMerged      = [powerStd_full,     powerStd_div(maskHighDiv) * scaleFactor];

[voltagesMerged, sortIdx] = sort(voltagesMerged);
powersMerged = powersMerged(sortIdx);
stdMerged    = stdMerged(sortIdx);

% --- Assemble output struct ---
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
curve.settleTimeS  = 5.0;
curve.warmupTimeS  = 5.0;
curve.timestamp    = datetime('now');
curve.notes        = sprintf( ...
    'MOCK sigmoid, %s, div %.0f kHz (0-5V) + full %.2f MHz (0-%.1fV), scale=%.4f, %d nm', ...
    aoChannel, repRateDivKhz, repRateFullMhz, vBoundary, scaleFactor, wavelengthNm);
curve.dmdActivePx  = 768 * 1024;  % DLi4130; change to 800*1280 for DLP650LNIR

if showFigure
    figure('Name', 'powerMeterSweep_mock', 'NumberTitle', 'off');

    subplot(1, 2, 1);
    hold on;
    plot(curve.divMode.voltageV, curve.divMode.powerMw, 'b-o', ...
        'LineWidth', 1.2, 'DisplayName', 'Divided mode (raw)');
    plot(curve.fullRepMode.voltageV, curve.fullRepMode.powerMw, 'r-s', ...
        'LineWidth', 1.2, 'DisplayName', 'Full rep rate (measured)');
    plot(curve.divMode.voltageV, curve.divMode.powerMw * scaleFactor, 'b--', ...
        'LineWidth', 1.0, 'DisplayName', sprintf('Divided \\times %.3f', scaleFactor));
    xline(vBoundary, 'k--', 'LineWidth', 0.8, 'Label', 'Merge boundary');
    xlabel('AO Voltage (V)');
    ylabel('Power (mW)');
    title('MOCK: raw sweeps + scale factor');
    legend('Location', 'northwest');
    grid on;

    subplot(1, 2, 2);
    errorbar(curve.voltageV, curve.powerMw, curve.powerStdMw, 'k-o', 'LineWidth', 1.4);
    xlabel('AO Voltage (V)');
    ylabel('Power at sample (mW)');
    title(sprintf('MOCK merged curve  [scale = %.3f]', scaleFactor));
    grid on;
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
