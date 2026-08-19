function [powerMw, powerStd] = runPowerSweepPhase(meter, voltageSteps, options)
%runPowerSweepPhase Drive one monotone AO ramp and read the meter at each step.
%
%   [powerMw, powerStd] = runPowerSweepPhase(meter, voltageSteps, options)
%
%   Extracted from tfp.calibration.powerMeterSweep's local runSweep so that the
%   FS-50 two-phase sweep (pulse-picker divided + full rep rate) and the
%   CARBIDE single-phase sweep share one implementation rather than two copies
%   that drift.
%
%   options (all required fields are marked):
%     .setVoltsFcn  REQUIRED @(volts) — how a step is commanded. This is the
%                   hook that decides whether the ramp goes through the raw
%                   DAQ (legacy build-A path) or through
%                   tfp.hardware.LaserPowerController (interlocked path).
%     .zeroFcn      @() — called on any fault before rethrowing. Default: a
%                   no-op, but every real caller supplies one.
%     .settleTimeS  dwell after each step (default 5.0)
%     .warmupTimeS  extra wait at the first non-zero step (default 0)
%     .nAverages    meter readings averaged per step (default 5)
%     .readPauseS   pause between averaged readings (default 0.5)
%     .label        char, prefixes the progress lines (default '')
%     .onStep       @(k, nSteps, voltageV, powerMw, powerStdMw) — progress
%                   sink. A callback rather than an axes handle, so the same
%                   sweep serves a console run, the legacy figure, and the GUI.
%     .verbose      print per-step lines (default true)
%
%   Faults call zeroFcn and rethrow: the beam must never be left on because a
%   meter read failed.

setVoltsFcn = tfp.util.configField(options, 'setVoltsFcn', []);
if isempty(setVoltsFcn) || ~isa(setVoltsFcn, 'function_handle')
    error('tfp:calibration:runPowerSweepPhase:missingSetVolts', ...
        'options.setVoltsFcn is required and must be a function handle.');
end
zeroFcn     = tfp.util.configField(options, 'zeroFcn',     @() []);
settleTimeS = tfp.util.configField(options, 'settleTimeS', 5.0);
warmupTimeS = tfp.util.configField(options, 'warmupTimeS', 0);
nAverages   = tfp.util.configField(options, 'nAverages',   5);
readPauseS  = tfp.util.configField(options, 'readPauseS',  0.5);
label       = char(tfp.util.configField(options, 'label',  ''));
onStep      = tfp.util.configField(options, 'onStep',      []);
verbose     = logical(tfp.util.configField(options, 'verbose', true));

voltageSteps = voltageSteps(:)';
nSteps   = numel(voltageSteps);
powerMw  = zeros(1, nSteps);
powerStd = zeros(1, nSteps);

if warmupTimeS > 0
    idxWarm = find(voltageSteps > 0, 1, 'first');
    warmupV = voltageSteps(max(1, idxWarm));
    setVoltsFcn(warmupV);
    estSecs = warmupTimeS + nSteps * settleTimeS + ...
              nSteps * (nAverages - 1) * readPauseS;
    if verbose
        fprintf('[%s] Warmup: %.2f V for %.1f s  (est. sweep: %.0f s = %.1f min)...\n', ...
            label, warmupV, warmupTimeS, estSecs, estSecs / 60);
    end
    pause(warmupTimeS);
end

try
    for k = 1:nSteps
        v = voltageSteps(k);
        setVoltsFcn(v);
        pause(settleTimeS);

        readings = zeros(1, nAverages);
        for j = 1:nAverages
            readings(j) = meter.measPower() * 1e3;   % W -> mW
            if j < nAverages
                pause(readPauseS);
            end
        end

        powerMw(k)  = mean(readings);
        powerStd(k) = std(readings);
        if verbose
            fprintf('[%s] Step %d/%d: %.2f V -> %.3f +/- %.4f mW\n', ...
                label, k, nSteps, v, powerMw(k), powerStd(k));
        end

        if ~isempty(onStep)
            try
                onStep(k, nSteps, voltageSteps(1:k), powerMw(1:k), powerStd(1:k));
            catch
                % A progress sink must never take the sweep down with it.
            end
        end
    end
catch ME
    try, zeroFcn(); catch, end
    rethrow(ME);
end
end
