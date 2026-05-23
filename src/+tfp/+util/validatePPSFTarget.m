function target = validatePPSFTarget(targets, dmd, callerId)
%validatePPSFTarget Enforce single, near-central target for PPSF experiments.
%
%   target = tfp.util.validatePPSFTarget(targets, dmd, callerId)
%
%   PPSF experiments sweep the stim spot away from the target cell (laterally
%   or axially) and need the response to falloff cleanly. To prevent the
%   offset spot from clipping the illuminated DMD region, the target cell must
%   sit within 80 px of the DMD geometric center, and there must be exactly
%   one target per session.
%
%   Inputs:
%     targets  - Nx2 [col row] in DMD pixel coordinates (output of the
%                experiment's resolveTargets).
%     dmd      - DMD object/struct with .nCols and .nRows.
%     callerId - char, e.g. 'exp_ppsf_lateral'; used to namespace the error
%                identifier as tfp:experiments:<callerId>:<reason>.
%
%   Output:
%     target   - 1x2 [col row], the validated single target.
%
%   Throws (on failure):
%     tfp:experiments:<callerId>:tooManyTargets - if numel(targets,1) ~= 1.
%     tfp:experiments:<callerId>:targetOffCenter - if the target is > 80 px
%       from the DMD geometric center.

MAX_RADIUS_PX = 80;

if ~isnumeric(targets) || ndims(targets) ~= 2 || size(targets, 2) ~= 2 ...
        || size(targets, 1) < 1
    error(sprintf('tfp:experiments:%s:badTargets', callerId), ...
        'PPSF target list must be Nx2 [col row] with N >= 1.');
end

nTargets = size(targets, 1);
if nTargets ~= 1
    error(sprintf('tfp:experiments:%s:tooManyTargets', callerId), ...
        ['PPSF requires exactly 1 target cell per session, got %d. ' ...
         'PPSF measures the response falloff for a single cell while ' ...
         'the stim spot is swept away from it; multiple targets would ' ...
         'interfere. Pick a single ROI in ScanImage and re-send.'], ...
        nTargets);
end

target = double(targets(1, :));
cCenter = floor(double(dmd.nCols) / 2);
rCenter = floor(double(dmd.nRows) / 2);
dist = hypot(target(1) - cCenter, target(2) - rCenter);

if dist > MAX_RADIUS_PX
    error(sprintf('tfp:experiments:%s:targetOffCenter', callerId), ...
        ['PPSF target at (col=%g, row=%g) is %.1f px from the DMD ' ...
         'geometric center (col=%d, row=%d); limit is %d px. The PPSF ' ...
         'sweep would push the stim spot outside the illuminated DMD ' ...
         'region. Either pick a more central cell as the PPSF target in ' ...
         'ScanImage, or translate the scope so the target cell is near ' ...
         'the center and re-take the ROI.'], ...
        target(1), target(2), dist, cCenter, rCenter, MAX_RADIUS_PX);
end
end
