function raw = synthTimingTrace(cfg, commandedRateHz, nTransitions)
%synthTimingTrace Generate a synthetic APD + trigger trace for the DMD timing toolset.
%
%   Part of the DMD timing-characterization toolset (scripts/photodiode_timing_tests/).
%   See scripts/photodiode_timing_tests/README.md for the overall measurement procedure.
%
%   raw = synthTimingTrace(cfg, commandedRateHz, nTransitions)
%
%   This is the *reference signal generator* for the switching-timing
%   pipeline.  It produces a realistic synthetic avalanche-photodiode (APD)
%   voltage trace and the accompanying recorded trigger line, modelling the
%   DMD's finite optical latency, rise/fall time, per-transition jitter,
%   measurement noise, and frame-dropping above the device's maximum trackable
%   rate.  Because the ground-truth parameters used to build the trace are
%   returned in raw.truth, the analysis routine (analyzeTimingTrace) can be
%   unit-tested by checking that it recovers these encoded parameters, and the
%   full acquisition -> analysis -> plotting pipeline can run on a dev machine
%   with no hardware attached.
%
%   The signal model implemented here is the contract that analyzeTimingTrace
%   must mirror.  Do not change one without the other.
%
%   Inputs
%   ------
%   cfg : struct
%       Timing config struct (see scripts/photodiode_timing_tests/defaultTimingConfig.m).
%       Fields read by this function:
%         cfg.sampleRateHz          - DAQ acquisition rate (Hz), e.g. 250000.
%         cfg.hardwareKind          - 'mock' | 'real' (recorded into meta).
%         cfg.channels              - struct of channel IDs (recorded into meta).
%         cfg.trigger.mode          - 'external' | 'internal' (recorded; see below).
%         cfg.trigger.pulseWidthFrac- trigger high fraction of each period.
%         cfg.synth.latency_s       - trigger edge -> optical 50% crossing (s).
%         cfg.synth.riseTime_s      - 10-90% rise time, low->high (s).
%         cfg.synth.fallTime_s      - 10-90% fall time, high->low (s).
%         cfg.synth.jitterStd_s     - per-transition timing jitter std dev (s).
%         cfg.synth.highV           - APD voltage in the optical "on" state (V).
%         cfg.synth.lowV            - APD voltage in the optical "off" state (V).
%         cfg.synth.noiseStd_v      - Gaussian noise std added to the trace (V).
%         cfg.synth.maxTrackRateHz  - rate above which the device drops frames.
%
%   commandedRateHz : scalar double > 0
%       Commanded pattern-advance (optical-toggle) rate, Hz.  One commanded
%       trigger per requested toggle.
%
%   nTransitions : integer >= 1
%       Number of commanded triggers (= optical toggles requested).
%
%   Output
%   ------
%   raw : struct  (a rawCapture)
%       .sampleRateHz   - scalar, copied from cfg.sampleRateHz.
%       .t              - (N x 1) double, time vector (0:N-1)'/sampleRateHz.
%       .apd            - (N x 1) double, synthetic APD voltage (V).
%       .trig           - (N x 1) double in {0,1}, recorded trigger line.
%       .commandedRateHz- scalar, copied from commandedRateHz.
%       .nCommanded     - scalar integer, = nTransitions.
%       .meta           - provenance struct (device, triggerMode, hardwareKind,
%                         channels, sampleRateHz, commandedRateHz, datetime).
%       .truth          - ground-truth struct used to build the trace:
%                         latency_s, riseTime_s, fallTime_s, jitterStd_s,
%                         highV, lowV, noiseStd_v, maxTrackRateHz,
%                         commandedRateHz, effectiveRateHz, nTransitionsTrue.
%
%   Signal semantics (mirrored by analyzeTimingTrace)
%   -------------------------------------------------
%   * Trigger period sPer = round(sampleRateHz/commandedRateHz) samples.
%     Trigger i (i = 0..nCommanded-1) rises at sample index i*sPer+1 and stays
%     high for round(pulseWidthFrac*sPer) samples, then low.  The record is
%     N = nCommanded*sPer + tail samples, where tail ~ 2*sPer low samples so
%     the final optical edge completes inside the capture.
%   * Each trigger rising edge toggles the optical state A<->B.  The trace
%     starts in the LOW (off) state before the first edge.
%   * The optical 50% crossing for the toggle caused by edge i is at
%     trigEdgeTime(i) + latency_s + jitterStd_s*randn.
%   * Each optical edge is a LINEAR ramp between low and high whose 10-90% span
%     equals riseTime_s (low->high) or fallTime_s (high->low).  For a linear
%     ramp the 10-90% span is 0.8 of the full 0%->100% duration, so the full
%     ramp duration D = riseTime_s/0.8 (resp fallTime_s/0.8).  The ramp is
%     centred so its 50% point lands on the crossing time.
%   * Gaussian measurement noise (noiseStd_v) is added to the whole trace.
%   * Dropped frames: if commandedRateHz > maxTrackRateHz the device cannot
%     keep up.  Only a fraction f = maxTrackRateHz/commandedRateHz of the
%     commanded triggers actually toggle the optical state (toggle when
%     floor(i*f) increments); skipped triggers leave the optical level held.
%     effectiveRateHz = min(commandedRateHz, maxTrackRateHz) and
%     nTransitionsTrue = the number of toggles actually applied.
%   * Internal-pacer mode (cfg.trigger.mode == 'internal'): the device
%     free-runs and emits a frame-sync OUTPUT rather than receiving an external
%     trigger.  For synthesis the recorded sync line is treated identically to
%     the external trigger; only raw.meta.triggerMode reflects the mode.
%
%   Determinism
%   -----------
%   This function NEVER calls rng() or reseeds the global generator, so it does
%   not disturb the caller's RNG state.  randn() is used directly for noise and
%   jitter; analyzer tolerances are loose enough and tests use enough samples.
%
%   Errors (identifier format: tfp:timing:synthTimingTrace:<reason>)
%   ------
%   tfp:timing:synthTimingTrace:badCfg
%       cfg is not a struct.
%   tfp:timing:synthTimingTrace:badRate
%       commandedRateHz is not a positive scalar.
%   tfp:timing:synthTimingTrace:badNTransitions
%       nTransitions is not an integer-valued scalar >= 1.
%   tfp:timing:synthTimingTrace:rateTooHighForSampleRate
%       The trigger period is < 4 samples (sampling too coarse for this rate).
%
%   Example
%   -------
%   cfg = defaultTimingConfig();
%   raw = synthTimingTrace(cfg, 1000, 200);     % 1 kHz, 200 toggles
%   plot(raw.t, raw.apd);
%
%   See also defaultTimingConfig, makeTimingPatterns, scripts/photodiode_timing_tests/README.md

% -------------------------------------------------------------------------
% 0.  Validate inputs
% -------------------------------------------------------------------------
if ~isstruct(cfg)
    error('tfp:timing:synthTimingTrace:badCfg', ...
        'cfg must be a struct; got %s.', class(cfg));
end

if ~isnumeric(commandedRateHz) || ~isscalar(commandedRateHz) || ...
        ~isfinite(commandedRateHz) || commandedRateHz <= 0
    error('tfp:timing:synthTimingTrace:badRate', ...
        'commandedRateHz must be a positive finite scalar; got %s.', ...
        mat2str(commandedRateHz));
end

if ~isnumeric(nTransitions) || ~isscalar(nTransitions) || ...
        ~isfinite(nTransitions) || nTransitions < 1 || ...
        nTransitions ~= floor(nTransitions)
    error('tfp:timing:synthTimingTrace:badNTransitions', ...
        'nTransitions must be an integer scalar >= 1; got %s.', ...
        mat2str(nTransitions));
end

nCommanded = double(nTransitions);

% -------------------------------------------------------------------------
% 1.  Unpack config (with the synth-model parameters)
% -------------------------------------------------------------------------
sampleRateHz   = cfg.sampleRateHz;
pulseWidthFrac = cfg.trigger.pulseWidthFrac;

latency_s      = cfg.synth.latency_s;
riseTime_s     = cfg.synth.riseTime_s;
fallTime_s     = cfg.synth.fallTime_s;
jitterStd_s    = cfg.synth.jitterStd_s;
highV          = cfg.synth.highV;
lowV           = cfg.synth.lowV;
noiseStd_v     = cfg.synth.noiseStd_v;
maxTrackRateHz = cfg.synth.maxTrackRateHz;

% -------------------------------------------------------------------------
% 2.  Sample geometry of the trigger train
% -------------------------------------------------------------------------
sPer = round(sampleRateHz / commandedRateHz);     % samples per commanded period
if sPer < 4
    error('tfp:timing:synthTimingTrace:rateTooHighForSampleRate', ...
        ['Trigger period is %d sample(s) (< 4) at commandedRateHz=%g Hz with ' ...
         'sampleRateHz=%g Hz. The sampling is too coarse to represent this ' ...
         'rate; increase cfg.sampleRateHz (need >= %g Hz for >= 4 samples/period).'], ...
        sPer, commandedRateHz, sampleRateHz, 4 * commandedRateHz);
end

tail = 2 * sPer;                                  % low-state tail so last edge completes
N    = nCommanded * sPer + tail;                  % total record length (samples)

% -------------------------------------------------------------------------
% 3.  Build the recorded trigger line (Nx1, 0/1)
% -------------------------------------------------------------------------
% Rising edge of trigger i at sample index (1-based) i*sPer+1; high for
% round(pulseWidthFrac*sPer) samples then low.
trig    = zeros(N, 1);
highLen = round(pulseWidthFrac * sPer);
highLen = max(0, min(highLen, sPer));             % clamp into [0, sPer]

for i = 0 : (nCommanded - 1)
    riseIdx = i * sPer + 1;                        % 1-based sample of the rising edge
    if highLen > 0
        hiStart = riseIdx;
        hiEnd   = min(riseIdx + highLen - 1, N);
        trig(hiStart:hiEnd) = 1;
    end
end

% Time vector
t = (0:N-1)' / sampleRateHz;

% -------------------------------------------------------------------------
% 4.  Determine which commanded triggers actually toggle the optical state
% -------------------------------------------------------------------------
% Above the trackable rate the device drops frames: only a fraction
% f = maxTrackRateHz/commandedRateHz of toggles land. We toggle on trigger i
% whenever floor(i*f) increments relative to floor((i-1)*f); skipped triggers
% hold the optical level. At/below the limit, f=1 -> every trigger toggles.
if commandedRateHz > maxTrackRateHz
    f               = maxTrackRateHz / commandedRateHz;
    effectiveRateHz = maxTrackRateHz;
else
    f               = 1;
    effectiveRateHz = commandedRateHz;
end

% Logical mask: toggleOnTrigger(i+1) is true if commanded trigger i toggles.
toggleOnTrigger = false(nCommanded, 1);
prevCount       = 0;                               % floor((-1)*f) treated as 0 baseline
for i = 0 : (nCommanded - 1)
    thisCount = floor((i + 1) * f);                % cumulative toggles through trigger i
    if thisCount > prevCount
        toggleOnTrigger(i + 1) = true;
    end
    prevCount = thisCount;
end

toggleTriggerIdx = find(toggleOnTrigger) - 1;      % 0-based commanded-trigger indices
nTransitionsTrue = numel(toggleTriggerIdx);

% -------------------------------------------------------------------------
% 5.  Build the clean (noise-free) optical APD waveform
% -------------------------------------------------------------------------
% Start in the LOW (off) state before the first edge.
apd = repmat(lowV, N, 1);

% Full ramp durations (0%->100%) so that the 10-90% span equals the spec'd
% rise/fall time.  For a linear ramp the 10-90% span is 0.8*D, hence D = T/0.8.
riseFullDur_s = riseTime_s / 0.8;
fallFullDur_s = fallTime_s / 0.8;

curLevel = lowV;                                   % optical level before next toggle
for k = 1 : nTransitionsTrue
    i = toggleTriggerIdx(k);                        % 0-based commanded-trigger index

    % Target level after this toggle (alternates each ACTUAL toggle).
    if curLevel == lowV
        nextLevel = highV;
        fullDur_s = riseFullDur_s;                  % low -> high uses rise time
    else
        nextLevel = lowV;
        fullDur_s = fallFullDur_s;                  % high -> low uses fall time
    end

    % Trigger edge time (s), plus latency and per-transition jitter.
    trigEdgeTime_s = (i * sPer) / sampleRateHz;     % time of sample index i*sPer+1
    crossTime_s    = trigEdgeTime_s + latency_s + jitterStd_s * randn;

    % Linear ramp centred on the 50% crossing time.
    rampStart_s = crossTime_s - 0.5 * fullDur_s;
    rampEnd_s   = crossTime_s + 0.5 * fullDur_s;

    % Sample indices spanned by the ramp (clamp into [1, N]).
    sIdxStart = max(1, floor(rampStart_s * sampleRateHz) + 1);
    sIdxEnd   = min(N,  ceil(rampEnd_s   * sampleRateHz) + 1);

    if sIdxEnd >= sIdxStart
        idx       = (sIdxStart:sIdxEnd)';
        tt        = t(idx);
        % Normalised ramp coordinate u in [0,1] across the ramp; clamp ends.
        if fullDur_s > 0
            u = (tt - rampStart_s) / fullDur_s;
        else
            u = double(tt >= crossTime_s);          % degenerate: instantaneous step
        end
        u          = min(1, max(0, u));
        apd(idx)   = curLevel + u * (nextLevel - curLevel);
    end

    % Everything from the ramp end to the end of the record holds at the new
    % level (later toggles overwrite their own spans).
    holdStart = min(N, sIdxEnd + 1);
    apd(holdStart:N) = nextLevel;
    if sIdxEnd < 1
        apd(:) = nextLevel;                          % ramp entirely before t=0 (shouldn't occur)
    end

    curLevel = nextLevel;
end

% -------------------------------------------------------------------------
% 6.  Add Gaussian measurement noise
% -------------------------------------------------------------------------
apd = apd + noiseStd_v * randn(N, 1);

% -------------------------------------------------------------------------
% 7.  Enforce column-double output shapes and strict 0/1 trigger
% -------------------------------------------------------------------------
t    = double(t(:));
apd  = double(apd(:));
trig = double(trig(:) ~= 0);                        % strictly {0,1}

% -------------------------------------------------------------------------
% 8.  Assemble the rawCapture struct
% -------------------------------------------------------------------------
raw = struct();
raw.sampleRateHz    = sampleRateHz;
raw.t               = t;
raw.apd             = apd;
raw.trig            = trig;
raw.commandedRateHz = commandedRateHz;
raw.nCommanded      = nCommanded;

raw.meta = struct( ...
    'device',         'DMD', ...
    'triggerMode',    cfg.trigger.mode, ...
    'hardwareKind',   cfg.hardwareKind, ...
    'channels',       cfg.channels, ...
    'sampleRateHz',   cfg.sampleRateHz, ...
    'commandedRateHz', commandedRateHz, ...
    'datetime',       datetime('now'));

raw.truth = struct( ...
    'latency_s',        latency_s, ...
    'riseTime_s',       riseTime_s, ...
    'fallTime_s',       fallTime_s, ...
    'jitterStd_s',      jitterStd_s, ...
    'highV',            highV, ...
    'lowV',             lowV, ...
    'noiseStd_v',       noiseStd_v, ...
    'maxTrackRateHz',   maxTrackRateHz, ...
    'commandedRateHz',  commandedRateHz, ...
    'effectiveRateHz',  effectiveRateHz, ...
    'nTransitionsTrue', nTransitionsTrue);

end % synthTimingTrace
