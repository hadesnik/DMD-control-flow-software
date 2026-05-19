function dutyCycle = powerLUT(targetPowerMwPerUm2, calibration)
%powerLUT Convert target sample-plane power density to DMD on-fraction.
%
%   dutyCycle = powerLUT(targetPowerMwPerUm2, calibration)
%
%   Inputs:
%     targetPowerMwPerUm2  - scalar or vector of desired power densities (mW/µm²)
%     calibration          - calibration struct with field powerCurve containing:
%                              .dmdActivePx   - vector of active pixel counts
%                              .powerAtSample - corresponding powers (mW)
%                              .fovAreaUm2    - FOV area in µm²
%
%   Output:
%     dutyCycle  - same size as targetPowerMwPerUm2, values in [0,1]

nRows = 800;   % DLP650LNIR
nCols = 1280;
totalPx = nRows * nCols;

hasCurve = isstruct(calibration) && ...
           isfield(calibration, 'powerCurve') && ...
           ~isempty(calibration.powerCurve) && ...
           isfield(calibration.powerCurve, 'dmdActivePx') && ...
           ~isempty(calibration.powerCurve.dmdActivePx);

if ~hasCurve
    % %ASSUMED fallback: linear scale to 1 mW over a 12 µm-radius spot
    maxPowerDensity = 1 / (pi * 12^2);  % mW/µm², 12 µm radius %ASSUMED
    dutyCycle = targetPowerMwPerUm2 / maxPowerDensity;
    dutyCycle = max(0, min(1, dutyCycle));
    return;
end

pc = calibration.powerCurve;

if ~isfield(pc, 'fovAreaUm2') || isempty(pc.fovAreaUm2)
    error('tfp:patterns:powerLUT:missingFovArea', ...
        'calibration.powerCurve.fovAreaUm2 is required.');
end

targetMw = targetPowerMwPerUm2 * pc.fovAreaUm2;

calMin = min(pc.powerAtSample);
calMax = max(pc.powerAtSample);
if any(targetMw(:) < calMin) || any(targetMw(:) > calMax)
    warning('tfp:patterns:powerLUT:outOfRange', ...
        'One or more target power values are outside the calibration range [%.4g, %.4g] mW.', ...
        calMin, calMax);
end

% interp1 requires monotonically ordered X; sort the calibration curve.
[sortedPower, sortIdx] = sort(pc.powerAtSample);
sortedPx = pc.dmdActivePx(sortIdx);
nActivePx = interp1(sortedPower, sortedPx, targetMw, 'linear', 'extrap');

dutyCycle = nActivePx / totalPx;
dutyCycle = max(0, min(1, dutyCycle));

end
