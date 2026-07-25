function stats = uniformityStats(intensity, reachable)
%uniformityStats Summarise illumination uniformity from per-spot intensities.
%   Shared private helper for measureIlluminationUniformity and its _mock.
%
%   intensity : nPts×1 double, integrated 2p signal per projected spot
%               (NaN where the spot was not detected).
%   reachable : nPts×1 logical, true where the spot fell inside the
%               illuminated footprint and was measured.
%
%   Returns a struct describing the flat-field over the *reachable* spots:
%     .intensityNorm  - intensity ./ max(reachable intensity); NaN outside
%                       the footprint. The flat-field *correction* that
%                       equalises 2p response across the field is
%                       1 ./ intensityNorm (applied to the raw 2p-signal map).
%     .cv             - coefficient of variation std/mean over reachable spots
%     .minMaxRatio    - min/max over reachable spots
%     .meanIntensity  - mean over reachable spots
%     .stdIntensity   - std over reachable spots
%     .nReachable     - count of reachable spots

intensity = intensity(:);
reachable = logical(reachable(:));

vals = intensity(reachable);
stats.nReachable = numel(vals);

if isempty(vals)
    % No spot fell inside the illuminated footprint — nothing to normalise.
    stats.intensityNorm = nan(size(intensity));
    stats.cv            = NaN;
    stats.minMaxRatio   = NaN;
    stats.meanIntensity = NaN;
    stats.stdIntensity  = NaN;
    return;
end

peak = max(vals);
stats.intensityNorm            = nan(size(intensity));
stats.intensityNorm(reachable) = vals / peak;   % 0..1, peak spot == 1

stats.meanIntensity = mean(vals);
stats.stdIntensity  = std(vals);                % 0 for a single reachable spot
stats.cv            = stats.stdIntensity / stats.meanIntensity;
stats.minMaxRatio   = min(vals) / peak;
end
