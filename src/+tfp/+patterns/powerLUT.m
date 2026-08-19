function dutyCycle = powerLUT(targetPowerMwPerUm2, calibration)
%powerLUT Convert target sample-plane power density to DMD on-fraction.
%
%   dutyCycle = tfp.patterns.powerLUT(targetPowerMwPerUm2, calibration)
%
%   Inputs:
%     targetPowerMwPerUm2 - scalar or vector of desired power densities (mW/um^2)
%     calibration         - struct with a .powerCurve field. The curve may be
%                           in either the legacy ON-count shape
%                           (.dmdActivePx vector + .powerAtSample) or schema 2
%                           (.pattern.dmdActivePx + .pattern.powerAtSample);
%                           tfp.calibration.normalizePowerCurve reconciles
%                           them, so callers do not have to care.
%                           Optional .dmdSize = [nRows nCols] overrides the
%                           chip size; otherwise it comes from the handoff's
%                           dmd_rows/dmd_cols rather than being pasted here.
%
%   Output:
%     dutyCycle - same size as targetPowerMwPerUm2, values in [0,1]
%
%   NOTE this needs the ON-COUNT branch of the power curve (how much power a
%   given number of lit mirrors delivers), NOT the volts->mW branch that
%   tfp.calibration.powerMeterSweep* measures. They used to share the field
%   name .dmdActivePx with different shapes — a scalar in one, a vector in the
%   other — which is why normalizePowerCurve now stands between them and why
%   requireBranch is asserted here rather than silently interpolating whatever
%   happens to be present.
%
%   See also tfp.calibration.normalizePowerCurve, tfp.calibration.powerMeterSweep.

totalPx = chipPixelCount(calibration);

hasCurve = isstruct(calibration) && isfield(calibration, 'powerCurve') && ...
           ~isempty(calibration.powerCurve) && isstruct(calibration.powerCurve);
if hasCurve
    pcRaw    = calibration.powerCurve;
    hasCurve = (isfield(pcRaw, 'dmdActivePx')   && ~isempty(pcRaw.dmdActivePx)) || ...
               (isfield(pcRaw, 'pattern')       && isstruct(pcRaw.pattern) && ...
                isfield(pcRaw.pattern, 'dmdActivePx') && ~isempty(pcRaw.pattern.dmdActivePx));
end

if ~hasCurve
    % %ASSUMED fallback: linear scale to 1 mW over a 12 um-radius spot
    maxPowerDensity = 1 / (pi * 12^2);  % mW/um^2, 12 um radius %ASSUMED
    dutyCycle = targetPowerMwPerUm2 / maxPowerDensity;
    dutyCycle = max(0, min(1, dutyCycle));
    return;
end

pc = tfp.calibration.normalizePowerCurve(calibration.powerCurve, ...
    struct('requireBranch', 'pattern'));

if isempty(pc.fovAreaUm2)
    error('tfp:patterns:powerLUT:missingFovArea', ...
        'calibration.powerCurve.fovAreaUm2 is required.');
end

targetMw = targetPowerMwPerUm2 * pc.fovAreaUm2;

powerAtSample = pc.pattern.powerAtSample;
dmdActivePx   = pc.pattern.dmdActivePx;

calMin = min(powerAtSample);
calMax = max(powerAtSample);
if any(targetMw(:) < calMin) || any(targetMw(:) > calMax)
    warning('tfp:patterns:powerLUT:outOfRange', ...
        'One or more target power values are outside the calibration range [%.4g, %.4g] mW.', ...
        calMin, calMax);
end

% interp1 requires monotonically ordered X; sort the calibration curve.
[sortedPower, sortIdx] = sort(powerAtSample);
sortedPx  = dmdActivePx(sortIdx);
nActivePx = interp1(sortedPower, sortedPx, targetMw, 'linear', 'extrap');

dutyCycle = nActivePx / totalPx;
dutyCycle = max(0, min(1, dutyCycle));

end

% ---------------------------------------------------------------------------
function totalPx = chipPixelCount(calibration)
%chipPixelCount Chip size from the calibration, else from the handoff.
%   Previously hardcoded as 800x1280. That is right for the DLP650LNIR and
%   wrong for the borrowed DLP7000 (768x1024), and a duty cycle computed
%   against the wrong chip is silently off by 30%.
if isstruct(calibration) && isfield(calibration, 'dmdSize') && ...
        numel(calibration.dmdSize) == 2
    totalPx = double(calibration.dmdSize(1)) * double(calibration.dmdSize(2));
    return
end
hc      = tfp.util.readHandoffConstants();
totalPx = hc.dmd_rows * hc.dmd_cols;
end
