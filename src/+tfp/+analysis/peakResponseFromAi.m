function r = peakResponseFromAi(ai)
%peakResponseFromAi Peak dF/F from a DAQ analog-input snippet via onlineDFF.
%
%   r = tfp.analysis.peakResponseFromAi(ai)
%
%   ai is an nSamples x nChans analog-input matrix.  Channels are treated as ROI
%   pixels (H=1, W=nChans) and averaged; the first quarter of samples is the
%   baseline window.  Returns the peak of the resulting dF/F trace.  Shared by
%   the power-curve / rapid-sequential experiment scripts.

[N, nChans] = size(ai);
frames    = reshape(ai, [N, 1, nChans]);
roi       = true(1, nChans);
nBaseline = max(1, round(N / 4));
trace     = tfp.analysis.onlineDFF(frames, roi, 1:nBaseline);
r         = max(trace);
end
