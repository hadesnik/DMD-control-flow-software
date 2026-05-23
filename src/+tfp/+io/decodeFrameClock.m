function [frameStartSamples, frameRateHz] = decodeFrameClock(diVec, sampleRate, options)
%decodeFrameClock Detect ScanImage frame-clock rising edges in a DI vector.
%
%   [frameStartSamples, frameRateHz] = tfp.io.decodeFrameClock(diVec, sampleRate)
%   returns the 1-based DAQ sample indices at which ScanImage frame-clock
%   pulses begin, and the frame rate inferred from the median inter-edge
%   interval.
%
%   Inputs:
%     diVec      - N-element numeric or logical vector. Treated as logical
%                  via threshold > 0.5.
%     sampleRate - scalar positive double, Hz. Master clock rate of the
%                  continuous DAQ session.
%
%   Name-value options:
%     Polarity ('rising'|'falling'|'auto', default 'rising')
%                  Which edge marks the frame start. The on-wire contract
%                  in docs/SYNC_FRAME.md §5 is active-high (rising). 'auto'
%                  treats the line as inverted when its mean duty cycle
%                  exceeds 0.5; useful when polarity at the patch panel is
%                  uncertain.
%
%   Outputs:
%     frameStartSamples (n x 1 uint64) - 1-based sample indices of detected
%                  edges. A pulse that starts on sample k yields index k.
%                  Empty (0 x 1 uint64) when no edges are found.
%     frameRateHz (scalar double) - sampleRate / median(diff(edges)). NaN
%                  when fewer than two edges are found. Robust to missing
%                  pulses (median absorbs the doubled intervals) and to
%                  small jitter.
%
%   See docs/SYNC_FRAME.md §5 for the encoding contract.

arguments
    diVec
    sampleRate (1,1) double {mustBePositive, mustBeFinite}
    options.Polarity (1,1) string ...
        {mustBeMember(options.Polarity, ["rising","falling","auto"])} = "rising"
end

if ~isvector(diVec) || isempty(diVec)
    if isempty(diVec)
        frameStartSamples = zeros(0, 1, 'uint64');
        frameRateHz = NaN;
        return
    end
    error('tfp:io:decodeFrameClock:badShape', ...
        'diVec must be a non-empty vector; got size %s.', mat2str(size(diVec)));
end

x = double(diVec(:)) > 0.5;

polarity = options.Polarity;
if polarity == "auto"
    if mean(x) > 0.5
        polarity = "falling";
    else
        polarity = "rising";
    end
end

% dx(k) = x(k) - x(k-1), with x(0) := 0. A rising edge at sample k gives
% dx(k) == 1; a falling edge gives dx(k) == -1.
dx = diff([0; double(x)]);
if polarity == "rising"
    edgeIdx = find(dx == 1);
else
    edgeIdx = find(dx == -1);
end

frameStartSamples = uint64(edgeIdx);

if numel(edgeIdx) < 2
    frameRateHz = NaN;
    return
end

medianInterval = median(diff(double(edgeIdx)));
frameRateHz = sampleRate / medianInterval;
end
