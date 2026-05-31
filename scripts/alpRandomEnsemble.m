%ALPRANDOMENSEMBLE  Cycle through random multi-spot ensemble patterns slowly.
%
% Usage:
%   alpRandomEnsemble              % 8 patterns, 10 spots each, 0.2 s/pattern (5 Hz)
%   alpRandomEnsemble(12, 5, 2)    % 12 patterns, 5 spots, 2 s/pattern

function alpRandomEnsemble(nPatterns, nSpotsPerPattern, secondsPerPattern)

if nargin < 1, nPatterns         = 8;   end
if nargin < 2, nSpotsPerPattern  = 10;  end
if nargin < 3, secondsPerPattern = 0.2; end

DLL_PATH    = 'C:\Program Files\ALP-4.1\ALP-4.1 high-speed API\x64\alpD41.dll';
HEADER_PATH = fullfile(fileparts(mfilename('fullpath')), '..', ...
                       'vendor', 'alp', 'official-4.1', 'alp.h');
LIB_ALIAS   = 'alp41';

% DLP7000 pixel scale: 13.68 µm pitch, ~40× optical demag → 0.342 µm/px.
% Central 6×6 mm active region: 6 mm / 13.68 µm/px = 439 px half = 219 px.
% 150 µm effective FOV → 0.342 µm/px → 10 µm cell body = 15 px radius.
% SPOT_RADIUS and ROI_HALF_PX need re-verification once optical path is measured.
SPOT_RADIUS = 15;    % pixels — ~5 µm radius at 0.342 µm/px (10 µm cell body)
ROI_HALF_PX = 219;   % pixels — half of 6 mm central region at 13.68 µm/px

rng('shuffle');     % different pattern each run
cleanup = onCleanup(@() doCleanup(LIB_ALIAS));

if ~libisloaded(LIB_ALIAS)
    loadlibrary(DLL_PATH, HEADER_PATH, 'alias', LIB_ALIAS);
end

devIdPtr = libpointer('uint32Ptr', uint32(0));
ret = calllib(LIB_ALIAS, 'AlpDevAlloc', int32(0), int32(0), devIdPtr);
if ret ~= int32(0), error('AlpDevAlloc failed: %d', ret); end
devId = devIdPtr.Value;

dimPtr = libpointer('int32Ptr', int32(0));
calllib(LIB_ALIAS, 'AlpDevInquire', devId, int32(2058), dimPtr); W = double(dimPtr.Value);
calllib(LIB_ALIAS, 'AlpDevInquire', devId, int32(2057), dimPtr); H = double(dimPtr.Value);
fprintf('DMD: %d x %d  |  %d patterns  |  %d spots each  |  %.1f s/pattern\n', ...
    W, H, nPatterns, nSpotsPerPattern, secondsPerPattern);
fprintf('Active region: central %d x %d px (6 x 6 mm)  |  spot radius: %d px (~%.0f µm)\n', ...
    2*ROI_HALF_PX, 2*ROI_HALF_PX, SPOT_RADIUS, SPOT_RADIUS * 0.342);

% Build patterns — spots placed only within central 6×6 mm ROI.
cxC = round(W/2);
cyC = round(H/2);
cxMin = cxC - ROI_HALF_PX + SPOT_RADIUS + 1;
cxMax = cxC + ROI_HALF_PX - SPOT_RADIUS;
cyMin = cyC - ROI_HALF_PX + SPOT_RADIUS + 1;
cyMax = cyC + ROI_HALF_PX - SPOT_RADIUS;

[XX, YY] = meshgrid(1:W, 1:H);
allData  = uint8([]);
fprintf('\nPatterns:\n');
for p = 1:nPatterns
    img = zeros(H, W);
    cx  = randi([cxMin, cxMax], 1, nSpotsPerPattern);
    cy  = randi([cyMin, cyMax], 1, nSpotsPerPattern);
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

calllib(LIB_ALIAS, 'AlpProjHalt', devId);
calllib(LIB_ALIAS, 'AlpSeqFree', devId, seqId);
calllib(LIB_ALIAS, 'AlpDevFree', devId);

end

function doCleanup(alias)
    if libisloaded(alias), unloadlibrary(alias); end
end
