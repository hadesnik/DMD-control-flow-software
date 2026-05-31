%ALPSEQUENCETEST  Upload and cycle through multiple DMD patterns.
%
% Usage:
%   alpSequenceTest            % default: 8 patterns at 1 fps
%   alpSequenceTest(500000)    % 500 ms per pattern (2 fps)
%   alpSequenceTest(100000)    % 100 ms per pattern (10 fps)
%
% PictureTime is in microseconds.

function alpSequenceTest(pictureTimeUs)

if nargin < 1, pictureTimeUs = 1000000; end  % 1 fps default

DLL_PATH    = 'C:\Program Files\ALP-4.1\ALP-4.1 high-speed API\x64\alpD41.dll';
HEADER_PATH = fullfile(fileparts(mfilename('fullpath')), '..', ...
                       'vendor', 'alp', 'official-4.1', 'alp.h');
LIB_ALIAS   = 'alp41';
ALP_OK      = int32(0);

cleanup = onCleanup(@() doCleanup(LIB_ALIAS));

if ~libisloaded(LIB_ALIAS)
    loadlibrary(DLL_PATH, HEADER_PATH, 'alias', LIB_ALIAS);
end

% Allocate device
devIdPtr = libpointer('uint32Ptr', uint32(0));
ret = calllib(LIB_ALIAS, 'AlpDevAlloc', int32(0), int32(0), devIdPtr);
if ret ~= ALP_OK, error('AlpDevAlloc failed: %d', ret); end
devId = devIdPtr.Value;

% Query dimensions
dimPtr = libpointer('int32Ptr', int32(0));
calllib(LIB_ALIAS, 'AlpDevInquire', devId, int32(2058), dimPtr); W = double(dimPtr.Value);
calllib(LIB_ALIAS, 'AlpDevInquire', devId, int32(2057), dimPtr); H = double(dimPtr.Value);
fprintf('DMD: %d x %d\n', W, H);

% Build pattern library
[cols, rows] = meshgrid(0:W-1, 0:H-1);
sq = 32;
checker  = mod(floor(cols/sq) + floor(rows/sq), 2) == 0;
patterns = {
    ones(H, W),           'All ON';
    zeros(H, W),          'All OFF';
    checker,              'Checkerboard';
    ~checker,             'Inv checkerboard';
    cols < W/2,           'Left half';
    cols >= W/2,          'Right half';
    rows < H/2,           'Top half';
    rows >= H/2,          'Bottom half';
};
nPat = size(patterns, 1);

% Concatenate all patterns into one flat uint8 buffer (row-major)
allData = uint8([]);
for i = 1:nPat
    p = uint8(255 * double(patterns{i}));
    allData = [allData, reshape(p', 1, [])]; %#ok<AGROW>
end

% Allocate sequence for all patterns
seqIdPtr = libpointer('uint32Ptr', uint32(0));
ret = calllib(LIB_ALIAS, 'AlpSeqAlloc', devId, int32(1), int32(nPat), seqIdPtr);
if ret ~= ALP_OK, error('AlpSeqAlloc failed: %d', ret); end
seqId = seqIdPtr.Value;

% Upload all patterns in one call
dataPtr = libpointer('uint8Ptr', allData);
ret = calllib(LIB_ALIAS, 'AlpSeqPut', devId, seqId, int32(0), int32(nPat), dataPtr);
if ret ~= ALP_OK, error('AlpSeqPut failed: %d', ret); end
fprintf('Uploaded %d patterns (%d bytes total)\n', nPat, numel(allData));

% Set timing: illuminate for 90% of frame, dark for 10%
illuminateUs = int32(round(pictureTimeUs * 0.9));
ret = calllib(LIB_ALIAS, 'AlpSeqTiming', devId, seqId, ...
    illuminateUs, int32(pictureTimeUs), int32(0), int32(0), int32(0));
if ret ~= ALP_OK, error('AlpSeqTiming failed: %d', ret); end
fprintf('Timing: %.1f fps (%.0f ms/pattern)\n', 1e6/pictureTimeUs, pictureTimeUs/1e3);

% List patterns
fprintf('\nPattern sequence:\n');
for i = 1:nPat
    fprintf('  %d: %s\n', i, patterns{i,2});
end

% Project
ret = calllib(LIB_ALIAS, 'AlpProjStartCont', devId, seqId);
if ret ~= ALP_OK, error('AlpProjStartCont failed: %d', ret); end
fprintf('\nCycling through patterns. Press any key to stop...\n');
pause;

calllib(LIB_ALIAS, 'AlpProjHalt', devId);
calllib(LIB_ALIAS, 'AlpSeqFree', devId, seqId);
calllib(LIB_ALIAS, 'AlpDevFree', devId);

end

function doCleanup(alias)
    if libisloaded(alias), unloadlibrary(alias); end
end
