%ALPRANDOMENSEMBLE  Cycle through random multi-spot ensemble patterns slowly.
%
% Usage:
%   alpRandomEnsemble              % 8 patterns, 10 spots each, 0.2 s/pattern (5 Hz)
%   alpRandomEnsemble(12, 5, 2)    % 12 patterns, 5 spots, 2 s/pattern

function alpRandomEnsemble(nPatterns, nSpotsPerPattern, secondsPerPattern)

if nargin < 1, nPatterns         = 8;   end
if nargin < 2, nSpotsPerPattern  = 10;  end
if nargin < 3, secondsPerPattern = 0.2; end

[DLL_PATH, HEADER_PATH, LIB_ALIAS] = alpPaths();

% Geometry comes from docs/optics_handoff.md at runtime. The figures hard-coded
% here before were DLP7000 numbers on a superseded path (13.68 um pitch,
% 0.342 um/px, a 6x6 mm SQUARE ROI) and were wrong on all three counts for the
% DLP650LNIR merged arm.
%
% The patch is a DISC, not a square: handoff section 4 is explicit that a square
% presents sqrt(2) of its side to the grating and the SLM fill, and its corners
% sit where the Gaussian is dimmest. Spots are placed by radius below.
CELL_RADIUS_UM = 5;    % 10 um soma
try
    hc          = tfp.util.readHandoffConstants();
    PATCH_R_PX  = double(hc.patch_diameter_px) / 2;
    umPerPx     = mean([hc.um_per_px_groove, hc.um_per_px_disp]);
    constSrc    = sprintf('handoff rev %g', hc.handoff_rev);
catch
    PATCH_R_PX  = 231.5;   % O463 px, handoff rev 4
    umPerPx     = 2.4469;  % mean of 2.3040 / 2.5897
    constSrc    = 'built-in fallback (src/ not on path)';
end
% ~2 px, not the old 15: this arm trades resolution for a field of order 1 mm,
% so one DMD pixel is ~2 um at the sample and a soma is only ~4 px across.
% Both branches above inherit rev 4's f7=250 scale, which the bench has since
% contradicted (f7 is a 300 -- USER 2026-08-19), so the true figure is 1.2x
% smaller: ~2.0 um/px over ~889x999 um. SPOT_RADIUS is 2 px either way, so
% nothing here changes; the numbers correct themselves when the optics repo
% regenerates. Do not hand-patch them -- see CLAUDE.md "Provisional f7 = 300".
SPOT_RADIUS = max(2, round(CELL_RADIUS_UM / umPerPx));

rng('shuffle');     % different pattern each run
% Ids land in a handle container so the cleanup closure sees them. See
% alpCleanup for why the order there matters.
st = containers.Map({'devId','seqId'}, {[], []});
cleanup = onCleanup(@() alpCleanup(LIB_ALIAS, st));

if ~libisloaded(LIB_ALIAS)
    loadlibrary(DLL_PATH, HEADER_PATH, 'alias', LIB_ALIAS);
end

devIdPtr = libpointer('uint32Ptr', uint32(0));
ret = calllib(LIB_ALIAS, 'AlpDevAlloc', int32(0), int32(0), devIdPtr);
if ret ~= int32(0), error('AlpDevAlloc failed: %d', ret); end
devId = devIdPtr.Value;
st('devId') = devId;

dimPtr = libpointer('int32Ptr', int32(0));
calllib(LIB_ALIAS, 'AlpDevInquire', devId, int32(2058), dimPtr); W = double(dimPtr.Value);
calllib(LIB_ALIAS, 'AlpDevInquire', devId, int32(2057), dimPtr); H = double(dimPtr.Value);
fprintf('DMD: %d x %d  |  %d patterns  |  %d spots each  |  %.1f s/pattern\n', ...
    W, H, nPatterns, nSpotsPerPattern, secondsPerPattern);
fprintf('Patch: O%.0f px disc  |  spot radius %d px (~%.1f um)  [%s]\n', ...
    2*PATCH_R_PX, SPOT_RADIUS, SPOT_RADIUS * umPerPx, constSrc);

% Spot centres are drawn inside the patch DISC, with the spot's own radius held
% back from the edge so no lit mirror crosses it.
cxC = round(W/2);
cyC = round(H/2);
placeR = max(1, PATCH_R_PX - SPOT_RADIUS);

[XX, YY] = meshgrid(1:W, 1:H);
allData  = uint8([]);
fprintf('\nPatterns:\n');
for p = 1:nPatterns
    img = zeros(H, W);
    % Uniform over the disc: sqrt() on the radius, else points bunch at centre.
    ang = 2*pi*rand(1, nSpotsPerPattern);
    rad = placeR * sqrt(rand(1, nSpotsPerPattern));
    cx  = round(cxC + rad .* cos(ang));
    cy  = round(cyC + rad .* sin(ang));
    for s = 1:nSpotsPerPattern
        img = img | (sqrt((XX-cx(s)).^2 + (YY-cy(s)).^2) <= SPOT_RADIUS);
    end
    allData = [allData, uint8(reshape(img', 1, []) * 255)]; %#ok<AGROW>
    coordStr = sprintf('(%d,%d) ', [cx; cy]);
    fprintf('  %2d: spots at %s\n', p, strtrim(coordStr));
end

seqIdPtr = libpointer('uint32Ptr', uint32(0));
ret = calllib(LIB_ALIAS, 'AlpSeqAlloc', devId, int32(1), int32(nPatterns), seqIdPtr);
if ret ~= int32(0), error('AlpSeqAlloc failed: %d', ret); end
seqId = seqIdPtr.Value;
% alpCleanup reads seqId from st; Code Analyzer cannot see the handle held
% by the cleanup closure, so it flags this as unused.
st('seqId') = seqId;   %#ok<NASGU>

dataPtr = libpointer('uint8Ptr', allData);
ret = calllib(LIB_ALIAS, 'AlpSeqPut', devId, seqId, int32(0), int32(nPatterns), dataPtr);
if ret ~= int32(0), error('AlpSeqPut failed: %d', ret); end

picUs       = int32(round(secondsPerPattern * 1e6));
illuminUs   = int32(round(secondsPerPattern * 0.95e6));
calllib(LIB_ALIAS, 'AlpSeqTiming', devId, seqId, illuminUs, picUs, ...
    int32(0), int32(0), int32(0));

ret = calllib(LIB_ALIAS, 'AlpProjStartCont', devId, seqId);
if ret ~= int32(0), error('AlpProjStartCont failed: %d', ret); end
fprintf('\nCycling. Press any key to stop...\n');
pause;

% Halting and freeing is left to alpCleanup, which runs on the normal exit
% below, on error, and on Ctrl-C alike.

end
