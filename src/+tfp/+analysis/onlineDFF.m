function trace = onlineDFF(frames, roi, baselineFrames)
%onlineDFF Compute deltaF/F0 trace for an ROI from a frame stack.
%
%   trace = onlineDFF(frames, roi, baselineFrames)
%
%   Inputs:
%     frames         - T x H x W numeric (T timepoints, H x W pixels).
%     roi            - H x W logical mask.
%     baselineFrames - integer vector of frame indices in 1..T used to
%                      compute F0 (mean of per-frame ROI means).
%
%   Output:
%     trace          - T x 1 double. trace(t) = (Fbar(t) - F0) / F0
%                      where Fbar(t) = mean over ROI of frames(t,:,:).
%                      If F0 is zero, returns raw deltaF (no division).

if ~isnumeric(frames) || ndims(frames) ~= 3
    error('tfp:analysis:onlineDFF:badFrames', 'frames must be T x H x W numeric.');
end
[T, H, W] = size(frames);
if ~islogical(roi) || ~isequal(size(roi), [H, W])
    error('tfp:analysis:onlineDFF:badRoi', ...
        'roi must be H x W logical matching frames spatial size.');
end
if nnz(roi) == 0
    error('tfp:analysis:onlineDFF:emptyRoi', 'roi has no true pixels.');
end
if ~isnumeric(baselineFrames) || ~isvector(baselineFrames) ...
        || any(baselineFrames < 1) || any(baselineFrames > T) ...
        || any(baselineFrames ~= round(baselineFrames))
    error('tfp:analysis:onlineDFF:badBaseline', ...
        'baselineFrames must be a vector of integer indices in 1..T.');
end

framesFlat = reshape(frames, T, H*W);
roiFlat    = roi(:);
meanPerFrame = mean(framesFlat(:, roiFlat), 2);   % T x 1

F0 = mean(meanPerFrame(baselineFrames));
if F0 == 0
    trace = meanPerFrame - F0;
else
    trace = (meanPerFrame - F0) ./ F0;
end
end
