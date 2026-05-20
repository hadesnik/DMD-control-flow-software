function centroid = findSpotCentroid(frame, frameIdx)
%findSpotCentroid Detect the largest bright-region centroid in a camera frame.
%   Shared private helper used by alignDMDtoCamera and calibrationGUI.
%
%   frame:    double 2D array, any intensity range
%   frameIdx: scalar used in error messages (default 0)
%   centroid: [x y] in image coordinates ([col row])
%
%   Throws tfp:calibration:findSpotCentroid:blankFrame  — uniform image
%   Throws tfp:calibration:findSpotCentroid:noSpot      — Otsu finds nothing
%
%   Requires Image Processing Toolbox (graythresh, bwconncomp, regionprops).

if nargin < 2 || isempty(frameIdx)
    frameIdx = 0;
end

lo = min(frame(:));
hi = max(frame(:));
if hi <= lo
    error('tfp:calibration:findSpotCentroid:blankFrame', ...
        'Frame %d is blank (uniform intensity %.3g).', frameIdx, lo);
end

img   = (frame - lo) / (hi - lo);
level = graythresh(img);
bw    = img > level;
cc    = bwconncomp(bw);

if cc.NumObjects == 0
    error('tfp:calibration:findSpotCentroid:noSpot', ...
        'No bright region found in frame %d (Otsu threshold %.3f).', frameIdx, level);
end

props    = regionprops(cc, 'Area', 'Centroid');
[~, idx] = max([props.Area]);
centroid = props(idx).Centroid;   % [x y] = [col row] in image coords
end
