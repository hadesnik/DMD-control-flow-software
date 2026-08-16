function [planeIdx, report] = assignFramePlanes(framesIn, nPlanes, opts)
%assignFramePlanes Map acquisition frames to ETL plane indices.
%
%   planeIdx = tfp.io.assignFramePlanes(frameIdx, nPlanes)
%   planeIdx = tfp.io.assignFramePlanes(frameIdx, nPlanes, opts)
%   [planeIdx, report] = tfp.io.assignFramePlanes(frameStartSamples, nPlanes, ...
%                            struct('fromClockSamples', true, ...))
%
%   THE single home of the interleave formula: in a free-running nPlanes
%   ETL volume, frame k images plane
%
%       plane = mod(k - volumeStartFrame, nPlanes) + 1
%
%   Mode 1 (default): framesIn is a vector of frame indices; pure modular
%   assignment. opts.volumeStartFrame (default 1) anchors which frame is
%   plane 1.
%
%   Mode 2 (opts.fromClockSamples = true): framesIn is the decoded
%   frame-clock edge samples (tfp.io.decodeFrameClock output). A dropped
%   frame shifts every subsequent modular assignment — the classic silent
%   3D corruption — so gaps in the edge train are detected against the
%   median frame interval and the plane counter is advanced THROUGH each
%   gap (ScanImage keeps its ETL cycle even when an edge goes missing in
%   the DAQ record). report tags the result:
%     .confidence      "exact" | "corrected" | "quarantined" (per frame)
%       exact       — no gaps before this frame
%       corrected   — a near-integer gap was skipped over; assignment
%                     corrected, treat with mild skepticism
%       quarantined — a non-integer gap (>25% off a whole frame count)
%                     precedes this frame; assignment unreliable
%     .nGaps, .firstGapFrame, .missedByGap
%
%   opts.gapFactor (default 1.5): interval > gapFactor * median flags a gap.

if nargin < 3 || isempty(opts)
    opts = struct();
end
volumeStart = double(tfp.util.configField(opts, 'volumeStartFrame', 1));
fromClock   = logical(tfp.util.configField(opts, 'fromClockSamples', false));
gapFactor   = double(tfp.util.configField(opts, 'gapFactor', 1.5));

nPlanes = double(nPlanes);
if ~isscalar(nPlanes) || nPlanes < 1 || nPlanes ~= round(nPlanes)
    error('tfp:io:assignFramePlanes:badNPlanes', ...
        'nPlanes must be a positive integer scalar.');
end

if ~fromClock
    frameIdx = double(framesIn(:)');
    planeIdx = mod(frameIdx - volumeStart, nPlanes) + 1;
    if nargout > 1
        report = struct('confidence', repmat("exact", 1, numel(frameIdx)), ...
            'nGaps', 0, 'firstGapFrame', NaN, 'missedByGap', []);
    end
    return
end

% --- Mode 2: gap-aware assignment from frame-clock edges --------------
samples = double(framesIn(:)');
K = numel(samples);
planeIdx   = zeros(1, K);
confidence = repmat("exact", 1, K);
missed     = [];
firstGap   = NaN;
quarantine = false;

if K >= 3
    medDt = median(diff(samples));
else
    medDt = NaN;
end

counter = volumeStart - 1;   % counts SI frames including missed ones
for k = 1:K
    if k > 1 && isfinite(medDt) && medDt > 0
        dt = samples(k) - samples(k - 1);
        if dt > gapFactor * medDt
            nMissedF = dt / medDt - 1;          % fractional missed frames
            nMissed  = round(nMissedF);
            if abs(nMissedF - nMissed) > 0.25
                % Gap is not close to a whole number of frames: the clock
                % record itself is suspect from here on.
                quarantine = true;
            end
            counter = counter + max(0, nMissed);
            missed(end+1) = nMissed; %#ok<AGROW>
            if isnan(firstGap)
                firstGap = k;
            end
        end
    end
    counter = counter + 1;
    planeIdx(k) = mod(counter - volumeStart, nPlanes) + 1;
    if quarantine
        confidence(k) = "quarantined";
    elseif ~isnan(firstGap)
        confidence(k) = "corrected";
    end
end

report = struct('confidence', confidence, 'nGaps', numel(missed), ...
    'firstGapFrame', firstGap, 'missedByGap', missed);
end
