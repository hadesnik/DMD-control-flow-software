function m = analyzeTimingTrace(raw, cfg)
%analyzeTimingTrace Extract DMD switching-timing metrics from one raw capture.
%
%   Part of the DMD timing-characterization toolset (scripts/photodiode_timing_tests/).
%   See scripts/photodiode_timing_tests/README.md for the overall measurement procedure and
%   how this analysis fits into the ping-pong switching-timing sweep.
%
%   This is the CORE analysis routine of the toolset.  Given a single
%   rawCapture struct holding an avalanche-photodiode (APD) analog trace and
%   the trigger logic trace -- both sampled on the SAME DAQ clock -- it
%   recovers the optical switching behaviour of the DMD:
%
%       * trigger -> light latency        (per matched trigger edge)
%       * optical 10-90% rise / fall time (per optical edge)
%       * achieved switch rate            (from the optical edge intervals)
%       * timing jitter                   (std of latency, or interval std)
%       * duty cycle                      (fraction of time in the HIGH state)
%       * dropped-frame fraction          (commanded vs. observed toggles)
%
%   The algorithm is deliberately matched to the conventions of the
%   synthetic-trace generator (see cfg.synth in defaultTimingConfig.m) so
%   that recovered metrics track ground truth closely:
%       latencyMean within +/-2 sample periods of truth,
%       riseMean/fallMean within +/-25% of truth,
%       achievedRateHz within +/-3% of the true effective rate.
%
%   m = analyzeTimingTrace(raw, cfg)
%
%   Inputs
%   ------
%   raw : struct  (rawCapture schema)
%       .sampleRateHz    scalar > 0  -- acquisition sample rate (Hz).
%       .t               N x 1       -- sample time stamps (s).  If absent or
%                                       mismatched, reconstructed as
%                                       (0:N-1)'/sampleRateHz.
%       .apd             N x 1       -- APD analog voltage (V).
%       .trig            N x 1       -- trigger logic in {0,1} (or thresholded).
%       .commandedRateHz scalar > 0  -- commanded DMD switch rate (Hz).
%       .nCommanded      scalar      -- number of commanded pattern advances
%                                       (== expected optical toggles).
%       .meta            (ignored here -- provenance only)
%       .truth           GROUND TRUTH -- deliberately NOT read by this
%                                       function; recovery must be blind.
%
%   cfg : struct  (timing config; see defaultTimingConfig.m)
%       Only cfg.trigger.mode is consulted (informational; both 'external'
%       and 'internal' expect one optical toggle per commanded advance).
%       Missing fields are tolerated with sensible defaults.
%
%   Output
%   ------
%   m : struct with EXACTLY these fields --
%       .commandedRateHz       scalar  -- echoed from raw.
%       .nTriggerEdges         scalar  -- number of trigger rising edges.
%       .nOpticalTransitions   scalar  -- number of detected optical edges.
%       .highLevelV            scalar  -- 95th-percentile APD level (V).
%       .lowLevelV             scalar  -- 5th-percentile APD level (V).
%       .contrastV             scalar  -- highLevelV - lowLevelV (V).
%       .latency_s             1 x K   -- matched trigger->light latencies (s).
%       .latencyMean_s         scalar  -- mean(latency_s) or NaN.
%       .latencyMedian_s       scalar  -- median(latency_s) or NaN.
%       .latencyStd_s          scalar  -- std(latency_s) or NaN.
%       .riseTime_s            1 x Kr  -- per-edge 10-90% rise times (s).
%       .fallTime_s            1 x Kf  -- per-edge 90-10% fall times (s).
%       .riseMean_s            scalar  -- mean(riseTime_s) or NaN.
%       .fallMean_s            scalar  -- mean(fallTime_s) or NaN.
%       .achievedRateHz        scalar  -- 1/median(edge intervals) or NaN.
%       .intervalStd_s         scalar  -- std of optical-edge intervals.
%       .jitter_s              scalar  -- std(latency_s) (>=2) else intervalStd.
%       .dutyCycle             scalar  -- fraction of samples HIGH.
%       .trackingOK            logical -- nOptical >= 0.9*expected.
%       .droppedFraction       scalar  -- max(0, 1 - nOptical/expected).
%       .edges                 struct  -- .trigEdgeIdx (col double),
%                                          .optEdgeIdx  (col double),
%                                          .optEdgeSign (col double, +1/-1).
%       .notes                 cellstr -- warnings ({} if none).
%
%   Robustness
%   ----------
%   A degenerate-but-valid trace (flat line, no triggers, no optical edges)
%   never errors: the relevant metrics come back NaN / empty, trackingOK is
%   false, and a descriptive note is appended.  Hard errors are reserved for
%   malformed INPUT (wrong type, missing required fields, length mismatch).
%
%   Errors (identifier format: tfp:timing:analyzeTimingTrace:<reason>)
%   ------
%   tfp:timing:analyzeTimingTrace:badRaw
%       raw is not a struct, or is missing a required field, or apd/trig are
%       not equal-length column vectors, or commandedRateHz <= 0.
%
%   Example
%   -------
%   cfg = defaultTimingConfig();
%   % raw produced by the synthetic generator at, say, 1 kHz commanded rate
%   m   = analyzeTimingTrace(raw, cfg);
%   fprintf('latency = %.1f us, rise = %.1f us, achieved = %.0f Hz\n', ...
%       m.latencyMean_s*1e6, m.riseMean_s*1e6, m.achievedRateHz);
%
%   See also: defaultTimingConfig, makeTimingPatterns, scripts/photodiode_timing_tests/README.md

% =========================================================================
% 1.  Validate INPUT (hard errors only for malformed input)
% =========================================================================
if ~isstruct(raw) || ~isscalar(raw)
    error('tfp:timing:analyzeTimingTrace:badRaw', ...
        'raw must be a scalar struct (rawCapture); got %s.', class(raw));
end

requiredFields = {'apd', 'trig', 'sampleRateHz', 'commandedRateHz', 'nCommanded'};
for k = 1 : numel(requiredFields)
    if ~isfield(raw, requiredFields{k})
        error('tfp:timing:analyzeTimingTrace:badRaw', ...
            'raw is missing required field ''%s''.', requiredFields{k});
    end
end

apd  = raw.apd;
trig = raw.trig;

% apd and trig must be equal-length column vectors.
if ~isnumeric(apd) || ~isvector(apd) || ~isnumeric(trig) || ~isvector(trig)
    error('tfp:timing:analyzeTimingTrace:badRaw', ...
        'raw.apd and raw.trig must be numeric vectors.');
end
apd  = apd(:);    % force column
trig = trig(:);   % force column
if numel(apd) ~= numel(trig)
    error('tfp:timing:analyzeTimingTrace:badRaw', ...
        'raw.apd (%d) and raw.trig (%d) must be the same length.', ...
        numel(apd), numel(trig));
end

N = numel(apd);

sampleRateHz = raw.sampleRateHz;
if ~isnumeric(sampleRateHz) || ~isscalar(sampleRateHz) || ~(sampleRateHz > 0)
    error('tfp:timing:analyzeTimingTrace:badRaw', ...
        'raw.sampleRateHz must be a positive scalar.');
end
sampleRateHz = double(sampleRateHz);
dt = 1 / sampleRateHz;                 % sample period (s)

commandedRateHz = raw.commandedRateHz;
if ~isnumeric(commandedRateHz) || ~isscalar(commandedRateHz) || ~(commandedRateHz > 0)
    error('tfp:timing:analyzeTimingTrace:badRaw', ...
        'raw.commandedRateHz must be a positive scalar.');
end
commandedRateHz = double(commandedRateHz);

nCommanded = double(raw.nCommanded);   % expected optical toggles

% Reconstruct the time vector if absent or shape-mismatched.
if isfield(raw, 't') && isnumeric(raw.t) && numel(raw.t) == N
    t = raw.t(:);
else
    t = (0:N-1).' * dt;
end

% cfg.trigger.mode is informational only here; tolerate a missing cfg.
trigMode = 'external';
if nargin >= 2 && isstruct(cfg) && isfield(cfg, 'trigger') ...
        && isstruct(cfg.trigger) && isfield(cfg.trigger, 'mode') ...
        && (ischar(cfg.trigger.mode) || isstring(cfg.trigger.mode))
    trigMode = char(cfg.trigger.mode); %#ok<NASGU> kept for future use / clarity
end

notes = {};   % accumulate human-readable warnings here

% =========================================================================
% 2.  Estimate signal levels (manual percentiles -- no Stats toolbox)
% =========================================================================
%   Use robust percentiles rather than min/max so a stray noise spike does
%   not blow up the contrast estimate.
lowLevelV  = localPercentile(apd,  5);
highLevelV = localPercentile(apd, 95);
contrastV  = highLevelV - lowLevelV;

% Noise estimate: std of the trace after removing the level structure is
% awkward without segmentation, so use a cheap robust proxy -- the median
% absolute first difference scaled to an approximate Gaussian sigma.
%   sigma ~= 1.4826 * median(|diff(apd)|) / sqrt(2)
% (the /sqrt(2) accounts for differencing two noisy samples).
if N >= 2
    absDiff   = abs(diff(apd));
    noiseStd  = 1.4826 * localMedian(absDiff) / sqrt(2);
else
    noiseStd  = 0;
end
if ~isfinite(noiseStd) || noiseStd < 0
    noiseStd = 0;
end

% Low-contrast guard: if the optical signal barely moves we cannot reliably
% recover edges.  Flag it but still proceed (trackingOK will likely be false).
contrastFloor = max(0.02, 5 * noiseStd);   % V
lowContrast = contrastV < contrastFloor;
if lowContrast
    notes{end+1} = sprintf( ...
        'low contrast (%.4f V < floor %.4f V); edge detection unreliable', ...
        contrastV, contrastFloor);
end

% =========================================================================
% 3.  Detect optical edges with a hysteretic state machine
% =========================================================================
%   threshold       = midpoint of the contrast.
%   hysteresis band = +/-0.1*contrast around threshold rejects noise chatter:
%     - declare HIGH only after the signal rises above threshold + band,
%     - declare LOW  only after it falls below  threshold - band.
%   Each state flip is one optical edge.  We record the nearest-sample index
%   and refine the EDGE TIME to the 50%-crossing of `threshold` by linear
%   interpolation between the bracketing samples.
threshold = lowLevelV + 0.5 * contrastV;
band      = 0.1 * contrastV;
hiArm     = threshold + band;   % must exceed this to enter HIGH
loArm     = threshold - band;   % must drop below this to enter LOW

optEdgeIdx     = zeros(0, 1);   % nearest-sample index of each edge
optEdgeSign    = zeros(0, 1);   % +1 = low->high, -1 = high->low
optEdgeTime    = zeros(0, 1);   % refined 50%-crossing time (s)

if N >= 2 && contrastV > 0
    % Seed the state from the first sample relative to the threshold.  Using
    % the bare threshold (not the armed levels) for the seed avoids an
    % artificial "unknown" state; the arming only governs flips thereafter.
    if apd(1) >= threshold
        state = 1;     % HIGH
    else
        state = -1;    % LOW
    end

    for i = 2 : N
        v = apd(i);
        if state == -1 && v >= hiArm
            % LOW -> HIGH transition (rising optical edge)
            state = 1;
            [idx, tc] = refineCrossing(apd, t, i, threshold, +1);
            optEdgeIdx(end+1, 1)  = idx;     %#ok<AGROW>
            optEdgeSign(end+1, 1) = +1;       %#ok<AGROW>
            optEdgeTime(end+1, 1) = tc;       %#ok<AGROW>
        elseif state == 1 && v <= loArm
            % HIGH -> LOW transition (falling optical edge)
            state = -1;
            [idx, tc] = refineCrossing(apd, t, i, threshold, -1);
            optEdgeIdx(end+1, 1)  = idx;     %#ok<AGROW>
            optEdgeSign(end+1, 1) = -1;       %#ok<AGROW>
            optEdgeTime(end+1, 1) = tc;       %#ok<AGROW>
        end
    end
end

nOpticalTransitions = numel(optEdgeIdx);
if nOpticalTransitions == 0
    notes{end+1} = 'no optical edges detected';
end

% =========================================================================
% 4.  Detect trigger rising edges (0 -> 1)
% =========================================================================
%   raw.trig is logic-valued; binarize about 0.5 to be robust to either a
%   {0,1} integer encoding or a thresholded analog level.
trigHigh = trig > 0.5;
% A rising edge occurs at sample i (i>=2) where trigHigh(i) && ~trigHigh(i-1).
risingMask  = trigHigh(2:end) & ~trigHigh(1:end-1);
trigEdgeIdx = find(risingMask) + 1;       % +1 -> index of the HIGH sample
trigEdgeIdx = trigEdgeIdx(:);             % column
trigEdgeTime = t(trigEdgeIdx);            % seconds
nTriggerEdges = numel(trigEdgeIdx);
if nTriggerEdges == 0
    notes{end+1} = 'no trigger rising edges found';
end

% =========================================================================
% 5.  Match latency: trigger rising edge -> first optical 50%-crossing after
% =========================================================================
%   For each trigger rising edge, find the first optical edge whose refined
%   crossing time is at/after the trigger time AND within 2 commanded
%   periods.  Triggers with no match are treated as dropped and skipped.
%   We match against ANY optical edge sign: in 'alloff'/ping-pong captures the
%   first toggle after a trigger may be a rise or a fall depending on phase,
%   and the trigger->light delay is the same transport latency either way.
commandedPeriod = 1 / commandedRateHz;
matchWindow     = 2 * commandedPeriod;        % s

latency_s = zeros(1, 0);
if nTriggerEdges > 0 && nOpticalTransitions > 0
    for i = 1 : nTriggerEdges
        te = trigEdgeTime(i);
        % First optical crossing at/after this trigger edge.
        cand = optEdgeTime(optEdgeTime >= te);
        if isempty(cand)
            continue;   % dropped: no optical activity after this trigger
        end
        d = cand(1) - te;
        if d <= matchWindow
            latency_s(end+1) = d;  %#ok<AGROW>
        end
        % else: optical edge too far away -> count as dropped, skip.
    end
end

% =========================================================================
% 6.  Rise / fall 10-90% times per optical edge
% =========================================================================
%   For a rising edge: time from the (low + 0.1*contrast) crossing to the
%   (low + 0.9*contrast) crossing, searching forward from the edge sample.
%   For a falling edge: time from the (low + 0.9*contrast) crossing to the
%   (low + 0.1*contrast) crossing.  Crossings are linearly interpolated.
lvl10 = lowLevelV + 0.1 * contrastV;
lvl90 = lowLevelV + 0.9 * contrastV;

riseTime_s = zeros(1, 0);
fallTime_s = zeros(1, 0);

for e = 1 : nOpticalTransitions
    s   = optEdgeSign(e);
    idx = optEdgeIdx(e);
    if s > 0
        % Rising edge: low end (lvl10) reached before high end (lvl90).
        tLo = crossingNear(apd, t, idx, lvl10, +1);
        tHi = crossingNear(apd, t, idx, lvl90, +1);
        if ~isnan(tLo) && ~isnan(tHi)
            rt = tHi - tLo;
            if rt >= 0
                riseTime_s(end+1) = rt;  %#ok<AGROW>
            end
        end
    else
        % Falling edge: high end (lvl90) reached before low end (lvl10).
        tHi = crossingNear(apd, t, idx, lvl90, -1);
        tLo = crossingNear(apd, t, idx, lvl10, -1);
        if ~isnan(tLo) && ~isnan(tHi)
            ft = tLo - tHi;
            if ft >= 0
                fallTime_s(end+1) = ft;  %#ok<AGROW>
            end
        end
    end
end

if isempty(riseTime_s)
    riseMean_s = NaN;
else
    riseMean_s = mean(riseTime_s);
end
if isempty(fallTime_s)
    fallMean_s = NaN;
else
    fallMean_s = mean(fallTime_s);
end

% =========================================================================
% 7.  Rates and jitter from optical-edge intervals
% =========================================================================
%   Each commanded advance produces ONE optical toggle (a rise OR a fall),
%   so the period between consecutive optical edges is the achieved switch
%   half/period.  We report 1/median(interval) as the achieved rate: the
%   commanded "rate" in this toolset counts toggles, so the toggle interval
%   directly inverts to the achieved toggle rate, matching commandedRateHz.
opticalEdgeTimes = sort(optEdgeTime);
if numel(opticalEdgeTimes) >= 2
    intervals     = diff(opticalEdgeTimes);
    achievedRateHz = 1 / localMedian(intervals);
    intervalStd_s  = localStd(intervals);
else
    intervals      = zeros(0, 1);
    achievedRateHz = NaN;
    intervalStd_s  = NaN;
end

% Jitter: prefer the latency spread (a direct trigger->light measure); fall
% back to the optical-interval spread when too few latencies are matched.
if numel(latency_s) >= 2
    jitter_s = localStd(latency_s);
else
    jitter_s = intervalStd_s;
end

% =========================================================================
% 8.  Duty cycle -- fraction of samples in the HIGH state
% =========================================================================
%   Computed over the span between the first and last optical edge when
%   edges exist (avoids skewing from long pre/post-sequence dwell), else over
%   the whole trace.  Membership in HIGH is decided by the bare threshold.
isHigh = apd >= threshold;
if nOpticalTransitions >= 2
    i0 = optEdgeIdx(1);
    i1 = optEdgeIdx(end);
    if i1 < i0
        tmp = i0; i0 = i1; i1 = tmp;   % defensive (edges are time-ordered)
    end
    seg = isHigh(i0:i1);
    if isempty(seg)
        dutyCycle = NaN;
    else
        dutyCycle = sum(seg) / numel(seg);
    end
else
    dutyCycle = sum(isHigh) / N;
end

% =========================================================================
% 9.  Dropped-frame fraction and tracking flag
% =========================================================================
%   expectedTransitions = nCommanded (one optical toggle per commanded
%   advance, for both external and internal trigger modes).
expectedTransitions = nCommanded;
if isnan(expectedTransitions) || expectedTransitions <= 0
    % Cannot judge dropping without a positive expectation.
    droppedFraction = NaN;
    trackingOK      = false;
    notes{end+1}    = 'nCommanded is missing or non-positive; droppedFraction undefined';
else
    droppedFraction = max(0, 1 - nOpticalTransitions / expectedTransitions);
    trackingOK      = nOpticalTransitions >= 0.9 * expectedTransitions;
end

% Low contrast almost certainly means we are not really tracking.
if lowContrast
    trackingOK = false;
end

% =========================================================================
% 10. Latency summary statistics
% =========================================================================
if isempty(latency_s)
    latencyMean_s   = NaN;
    latencyMedian_s = NaN;
    latencyStd_s    = NaN;
    if nTriggerEdges > 0
        notes{end+1} = 'no trigger->light latencies matched within window';
    end
else
    latencyMean_s   = mean(latency_s);
    latencyMedian_s = localMedian(latency_s);
    latencyStd_s    = localStd(latency_s);
end

% =========================================================================
% 11. Assemble the metrics struct (EXACT field names / order per schema)
% =========================================================================
m = struct();
m.commandedRateHz     = commandedRateHz;
m.nTriggerEdges       = nTriggerEdges;
m.nOpticalTransitions = nOpticalTransitions;

m.highLevelV = highLevelV;
m.lowLevelV  = lowLevelV;
m.contrastV  = contrastV;

m.latency_s       = latency_s;          % 1 x K row
m.latencyMean_s   = latencyMean_s;
m.latencyMedian_s = latencyMedian_s;
m.latencyStd_s    = latencyStd_s;

m.riseTime_s = riseTime_s;              % 1 x Kr row
m.fallTime_s = fallTime_s;              % 1 x Kf row
m.riseMean_s = riseMean_s;
m.fallMean_s = fallMean_s;

m.achievedRateHz = achievedRateHz;
m.intervalStd_s  = intervalStd_s;
m.jitter_s       = jitter_s;
m.dutyCycle      = dutyCycle;

m.trackingOK      = logical(trackingOK);
m.droppedFraction = droppedFraction;

m.edges = struct( ...
    'trigEdgeIdx', trigEdgeIdx(:), ...   % col double
    'optEdgeIdx',  optEdgeIdx(:), ...    % col double
    'optEdgeSign', optEdgeSign(:));      % col double, +1/-1

m.notes = notes;                        % cellstr ({} when empty)

end % analyzeTimingTrace


% =========================================================================
% Local helper -- 50%-crossing refinement at a detected state flip
% =========================================================================
function [idx, tc] = refineCrossing(apd, t, i, level, sgn)
%refineCrossing Interpolate the exact time apd crosses LEVEL near sample i.
%
%   The hysteretic state machine declares a flip at sample i (the first
%   sample past the arming level).  The true 50%-crossing of `level` lies on
%   the last segment that crossed it -- somewhere between the most recent
%   sample below `level` and the first sample above (rising), or vice versa
%   (falling).  We walk backwards from i to find the bracketing pair, then
%   linearly interpolate the crossing time.
%
%   idx : nearest integer sample index to the crossing (for m.edges).
%   tc  : interpolated crossing time (s).
%   sgn : +1 rising, -1 falling.

idx = i;          % default: the flip sample itself
tc  = t(i);

if sgn > 0
    % Rising: find the last j < i with apd(j) < level and apd(j+1) >= level.
    j = i - 1;
    while j >= 1 && apd(j) >= level
        j = j - 1;
    end
    % Now apd(j) < level (or j < 1).  Bracket is [j, j+1].
    if j >= 1
        a = apd(j); b = apd(j+1);
        tc = interpCross(t(j), t(j+1), a, b, level);
        % nearest sample index
        if abs(level - a) <= abs(b - level)
            idx = j;
        else
            idx = j + 1;
        end
    end
else
    % Falling: find the last j < i with apd(j) > level and apd(j+1) <= level.
    j = i - 1;
    while j >= 1 && apd(j) <= level
        j = j - 1;
    end
    if j >= 1
        a = apd(j); b = apd(j+1);
        tc = interpCross(t(j), t(j+1), a, b, level);
        if abs(a - level) <= abs(level - b)
            idx = j;
        else
            idx = j + 1;
        end
    end
end

end % refineCrossing


% =========================================================================
% Local helper -- forward search for a level crossing near an edge
% =========================================================================
function tc = crossingNear(apd, t, idx, level, sgn)
%crossingNear Find the interpolated time apd crosses LEVEL near sample idx.
%
%   Used for the 10% / 90% landmarks of rise/fall measurement.  For a rising
%   edge (sgn=+1) we search OUTWARD from idx (both directions) for the first
%   bracketing pair where apd goes from below to above LEVEL; for a falling
%   edge (sgn=-1) from above to below.  Returns NaN if no crossing is found
%   within a bounded window (so a malformed edge yields NaN, not garbage).
%
%   The 10% and 90% landmarks of a single transition both sit on the same
%   monotone ramp, just on opposite sides of the 50% point, so a local
%   bidirectional search reliably locates each.

N = numel(apd);

% Bound the search to a small neighbourhood of the edge so we don't grab a
% landmark from an adjacent transition.  16 samples each way is generous for
% the rise/fall times this toolset targets relative to the sample rate.
win = 16;
lo  = max(1, idx - win);
hi  = min(N, idx + win);

tc = NaN;
bestDist = Inf;

for j = lo : (hi - 1)
    a = apd(j);
    b = apd(j+1);
    crosses = false;
    if sgn > 0
        crosses = (a < level && b >= level);
    else
        crosses = (a > level && b <= level);
    end
    if crosses
        cand = interpCross(t(j), t(j+1), a, b, level);
        % Prefer the crossing nearest the edge index time.
        d = abs(cand - t(idx));
        if d < bestDist
            bestDist = d;
            tc = cand;
        end
    end
end

end % crossingNear


% =========================================================================
% Local helper -- linear interpolation of a level crossing time
% =========================================================================
function tc = interpCross(t0, t1, v0, v1, level)
%interpCross Linearly interpolate the time at which v(t) == level.
%
%   Given two bracketing samples (t0,v0) and (t1,v1), returns the time of the
%   LEVEL crossing on that segment.  Falls back to the midpoint if the
%   segment is flat (v0 == v1) to avoid a divide-by-zero.

if v1 == v0
    tc = 0.5 * (t0 + t1);
else
    frac = (level - v0) / (v1 - v0);
    % Clamp to [0,1] for numerical safety (the caller guarantees a bracket,
    % but rounding can push frac a hair outside).
    if frac < 0, frac = 0; end
    if frac > 1, frac = 1; end
    tc = t0 + frac * (t1 - t0);
end

end % interpCross


% =========================================================================
% Local helper -- percentile via sort + linear interpolation
% =========================================================================
function p = localPercentile(x, pct)
%localPercentile Manual percentile (no Stats toolbox).
%
%   p = localPercentile(x, pct) returns the PCT-th percentile (0<=pct<=100)
%   of vector X, ignoring NaNs.  Uses the common "linear interpolation
%   between closest ranks" definition with the MATLAB prctile convention:
%   the i-th of n sorted values sits at percentile 100*(i-0.5)/n, and values
%   outside that range clamp to the extremes.
%
%   Returns NaN for empty input.

x = x(:);
x = x(~isnan(x));
n = numel(x);
if n == 0
    p = NaN;
    return;
end
if n == 1
    p = x(1);
    return;
end

xs = sort(x);

% Percentile positions of the sorted samples (MATLAB prctile convention).
ranks = 100 * ((1:n) - 0.5) / n;   % 1 x n

if pct <= ranks(1)
    p = xs(1);
elseif pct >= ranks(end)
    p = xs(end);
else
    % Linear interpolation between the two bracketing sorted samples.
    p = interp1(ranks, xs, pct, 'linear');
end

end % localPercentile


% =========================================================================
% Local helper -- median (base median() exists, but keep NaN-safe + explicit)
% =========================================================================
function md = localMedian(x)
%localMedian NaN-ignoring median of a vector via sort.
%
%   Implemented directly (sort + middle element / mean of two middle) so the
%   routine has no hidden toolbox dependence and treats NaNs explicitly.

x = x(:);
x = x(~isnan(x));
n = numel(x);
if n == 0
    md = NaN;
    return;
end
xs = sort(x);
if mod(n, 2) == 1
    md = xs((n + 1) / 2);
else
    md = 0.5 * (xs(n/2) + xs(n/2 + 1));
end

end % localMedian


% =========================================================================
% Local helper -- sample standard deviation (NaN-safe)
% =========================================================================
function s = localStd(x)
%localStd NaN-ignoring sample standard deviation (N-1 normalisation).
%
%   Returns 0 for a single finite element and NaN for empty input, matching
%   the conventions used by the metrics schema (jitter/interval std).

x = x(:);
x = x(~isnan(x));
n = numel(x);
if n == 0
    s = NaN;
    return;
end
if n == 1
    s = 0;
    return;
end
mu = sum(x) / n;
s  = sqrt(sum((x - mu).^2) / (n - 1));

end % localStd
