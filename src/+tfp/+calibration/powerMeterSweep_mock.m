function curve = powerMeterSweep_mock(options)
%powerMeterSweep_mock Synthetic power sweep — no hardware required.
%   Returns a plausible sigmoid power-vs-voltage curve for pipeline testing.
%   The curve shape (sigmoid, 0–5 mW, midpoint 2.5 V) approximates a typical
%   EOM/AOM transfer function.  Output struct matches powerMeterSweep exactly.
%
%   curve = powerMeterSweep_mock()
%   curve = powerMeterSweep_mock(options)
%
%   options fields (all optional, same defaults as powerMeterSweep):
%     .voltageSteps  - default linspace(0,5,25)
%     .fovAreaUm2    - default pi*(400)^2
%     .wavelengthNm  - default 1040
%     .aoChannel     - default 'ao1'  (stored in notes only)
%     .showFigure    - default true
%     .maxPowerMw    - peak plateau power (mW); default 5
%     .sigmoidK      - steepness; default 2
%     .sigmoidV0     - midpoint (V); default 2.5
%     .noiseMw       - std dev of simulated PM100D noise (mW); default 0.02
%
%   See also tfp.calibration.powerMeterSweep, tfp.patterns.powerLUT.

if nargin < 1
    options = struct();
end

voltageSteps = configField(options, 'voltageSteps', linspace(0, 5, 25));
fovAreaUm2   = configField(options, 'fovAreaUm2',   pi * 400^2);
wavelengthNm = configField(options, 'wavelengthNm', 1040);
aoChannel    = configField(options, 'aoChannel',    'ao1');
showFigure   = configField(options, 'showFigure',   true);
maxPowerMw   = configField(options, 'maxPowerMw',   5);
k_sig        = configField(options, 'sigmoidK',     2);
v0           = configField(options, 'sigmoidV0',    2.5);
noiseMw      = configField(options, 'noiseMw',      0.02);

voltageSteps = voltageSteps(:)';
nSteps       = numel(voltageSteps);

% Sigmoid: power = maxPower / (1 + exp(-k*(V - v0)))
powerMw  = maxPowerMw ./ (1 + exp(-k_sig * (voltageSteps - v0)));
powerStd = abs(noiseMw * randn(1, nSteps));  % simulated PM100D noise

curve.voltageV     = voltageSteps;
curve.powerMw      = powerMw;
curve.powerStdMw   = powerStd;
curve.fovAreaUm2   = fovAreaUm2;
curve.wavelengthNm = wavelengthNm;
curve.timestamp    = datetime('now');
curve.notes        = sprintf('MOCK sigmoid — %s, %.1f-%.1fV, %dnm', ...
    aoChannel, min(voltageSteps), max(voltageSteps), wavelengthNm);
curve.dmdActivePx  = 768 * 1024;  % DLi4130; change to 800*1280 for DLP650LNIR

if showFigure
    figure('Name', 'powerMeterSweep_mock', 'NumberTitle', 'off');
    errorbar(curve.voltageV, curve.powerMw, curve.powerStdMw, 'o-', 'LineWidth', 1.2);
    xlabel('AO Voltage (V)');
    ylabel('Power at sample (mW)');
    title(sprintf('MOCK power curve — %s', aoChannel));
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
