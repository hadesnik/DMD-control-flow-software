function [centroid, stats] = findSpotCentroid(frame, frameIdx, options)
%findSpotCentroid Detect the largest bright-region centroid in a camera frame.
%   Shared private helper used by alignDMDtoCamera, calibrationGUI and the
%   z-calibration (throughFocusSweep).
%
%   centroid           = findSpotCentroid(frame, frameIdx)
%   [centroid, stats]  = findSpotCentroid(frame, frameIdx, options)
%
%   frame:    double 2D array, any intensity range
%   frameIdx: scalar used in error messages (default 0)
%   options:  optional struct:
%     .backgroundFrame — same-size frame subtracted before detection
%                        (a no-stim dark frame; essential for the broad dim
%                        spots of a through-focus sweep)
%     .threshFrac      — fixed fraction-of-peak threshold in (0,1). Default
%                        [] = Otsu (the original behaviour). Otsu is
%                        fragile on broad low-contrast blobs; sweeps pass
%                        ~0.3 (the crossRegisterScanImage convention).
%
%   centroid: [x y] in image coordinates ([col row])
%   stats:    struct (computed only when requested):
%     .sigmaPx   — intensity-weighted RMS radius of the blob:
%                  sqrt((var_x + var_y)/2). The through-focus size metric.
%     .areaPx    — thresholded blob pixel count
%     .peak      — max background-subtracted intensity inside the blob
%     .bgLevel   — median intensity outside the blob (post-subtraction)
%     .integrated— sum of background-subtracted intensity over the blob
%
%   Throws tfp:calibration:findSpotCentroid:blankFrame  — uniform image
%   Throws tfp:calibration:findSpotCentroid:noSpot      — threshold finds nothing
%
%   Requires Image Processing Toolbox (graythresh, bwconncomp, regionprops).

if nargin < 2 || isempty(frameIdx)
    frameIdx = 0;
end
if nargin < 3 || isempty(options)
    options = struct();
end

if isfield(options, 'backgroundFrame') && ~isempty(options.backgroundFrame)
    bg = options.backgroundFrame;
    if ~isequal(size(bg), size(frame))
        error('tfp:calibration:findSpotCentroid:badBackground', ...
            'backgroundFrame size [%s] does not match frame [%s].', ...
            num2str(size(bg)), num2str(size(frame)));
    end
    frame = frame - bg;
end

lo = min(frame(:));
hi = max(frame(:));
if hi <= lo
    error('tfp:calibration:findSpotCentroid:blankFrame', ...
        'Frame %d is blank (uniform intensity %.3g).', frameIdx, lo);
end

img = (frame - lo) / (hi - lo);
if isfield(options, 'threshFrac') && ~isempty(options.threshFrac)
    level = double(options.threshFrac);
else
    level = graythresh(img);
end
bw = img > level;
cc = bwconncomp(bw);

if cc.NumObjects == 0
    error('tfp:calibration:findSpotCentroid:noSpot', ...
        'No bright region found in frame %d (threshold %.3f).', frameIdx, level);
end

props    = regionprops(cc, 'Area', 'Centroid');
[~, idx] = max([props.Area]);
centroid = props(idx).Centroid;   % [x y] = [col row] in image coords

if nargout < 2
    return
end

% --- Blob statistics for the z-calibration ---
blobMask = false(size(bw));
blobMask(cc.PixelIdxList{idx}) = true;

bgLevel = median(frame(~blobMask));
net     = frame - bgLevel;           % local background removed
w       = net .* double(blobMask);   % intensity weights inside the blob
w(w < 0) = 0;
wSum    = sum(w(:));

[rows, cols] = ndgrid(1:size(frame, 1), 1:size(frame, 2));
if wSum > 0
    mx   = sum(w(:) .* cols(:)) / wSum;
    my   = sum(w(:) .* rows(:)) / wSum;
    varX = sum(w(:) .* (cols(:) - mx).^2) / wSum;
    varY = sum(w(:) .* (rows(:) - my).^2) / wSum;
    stats.sigmaPx = sqrt((varX + varY) / 2);
else
    stats.sigmaPx = NaN;
end
stats.areaPx     = props(idx).Area;
stats.peak       = max(net(blobMask));
stats.bgLevel    = bgLevel;
stats.integrated = sum(net(blobMask));
end
