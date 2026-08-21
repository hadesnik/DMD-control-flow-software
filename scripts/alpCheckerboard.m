%ALPCHECKERBOARD  Project a checkerboard pattern on the DLP7000.
%
% Usage:
%   alpCheckerboard          % default 32x32 pixel squares
%   alpCheckerboard(64)      % 64x64 pixel squares

function alpCheckerboard(squareSize)

if nargin < 1, squareSize = 32; end

[DLL_PATH, HEADER_PATH, LIB_ALIAS] = alpPaths();
ALP_OK      = int32(0);

% Ids land in a handle container so the cleanup closure sees them. See
% alpCleanup for why the order there matters.
st = containers.Map({'devId','seqId'}, {[], []});
cleanup = onCleanup(@() alpCleanup(LIB_ALIAS, st));

if ~libisloaded(LIB_ALIAS)
    loadlibrary(DLL_PATH, HEADER_PATH, 'alias', LIB_ALIAS);
end

% Allocate device
devIdPtr = libpointer('uint32Ptr', uint32(0));
ret = calllib(LIB_ALIAS, 'AlpDevAlloc', int32(0), int32(0), devIdPtr);
if ret ~= ALP_OK, error('AlpDevAlloc failed: %d', ret); end
devId = devIdPtr.Value;
st('devId') = devId;

% Query dimensions
dimPtr = libpointer('int32Ptr', int32(0));
calllib(LIB_ALIAS, 'AlpDevInquire', devId, int32(2058), dimPtr);
W = double(dimPtr.Value);
calllib(LIB_ALIAS, 'AlpDevInquire', devId, int32(2057), dimPtr);
H = double(dimPtr.Value);
fprintf('DMD: %d x %d,  square size: %d px\n', W, H, squareSize);

% Build checkerboard (1 byte per pixel, MSB-aligned: 255=on, 0=off)
[cols, rows] = meshgrid(0:W-1, 0:H-1);
pattern = uint8(255 * double(mod(floor(cols/squareSize) + floor(rows/squareSize), 2) == 0));
patternData = reshape(pattern', 1, []);

% Allocate sequence and upload
seqIdPtr = libpointer('uint32Ptr', uint32(0));
ret = calllib(LIB_ALIAS, 'AlpSeqAlloc', devId, int32(1), int32(1), seqIdPtr);
if ret ~= ALP_OK, error('AlpSeqAlloc failed: %d', ret); end
seqId = seqIdPtr.Value;
% Load-bearing: alpCleanup reads seqId from `st` to free the sequence.
% Code Analyzer flags it because it cannot see the handle the cleanup
% closure holds, so the suppression says so rather than looking dead.
st('seqId') = seqId;   %#ok<NASGU>

dataPtr = libpointer('uint8Ptr', patternData);
ret = calllib(LIB_ALIAS, 'AlpSeqPut', devId, seqId, int32(0), int32(1), dataPtr);
if ret ~= ALP_OK, error('AlpSeqPut failed: %d', ret); end

% Project
ret = calllib(LIB_ALIAS, 'AlpProjStartCont', devId, seqId);
if ret ~= ALP_OK, error('AlpProjStartCont failed: %d', ret); end
fprintf('Projecting checkerboard. Press any key to stop...\n');
pause;

% Halting and freeing is left to alpCleanup, which runs on the normal exit
% below, on error, and on Ctrl-C alike. Doing it here as well would just
% double-free on the way out.

end
