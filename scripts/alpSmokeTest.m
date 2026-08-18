%ALPSMOKETEST  Minimal ALP smoke test: projects an all-on pattern.
%
% Version-agnostic: alpPaths() resolves whichever SDK is installed. For the
% DLP650LNIR on ALP-4.3 prefer alpSmokeTest43, which checks the DMD type and
% enforces the 50% ON-fraction cap of docs/optics_handoff.md §7. This
% script projects a full-field frame with no such check.
%
% Confirms the ALP DLL loads, the device allocates, and the DMD responds.
% Queries actual DMD dimensions from the board at runtime — do not hardcode.
%
% Usage:
%   alpSmokeTest            % loads DLL from DLL_PATH below
%   alpSmokeTest('off')     % all-mirrors-off pattern instead
%
% Press any key to halt projection and free resources.

function alpSmokeTest(mode)

if nargin < 1, mode = 'on'; end

% Resolved by alpPaths(), which finds whichever ALP SDK is actually installed
% and returns a matching DLL/header pair. Pass a version to pin it, e.g.
% alpPaths('4.1').
[DLL_PATH, HEADER_PATH, LIB_ALIAS] = alpPaths();

ALP_OK      = int32(0);
ALP_DEFAULT = int32(0);

% Ids land in a handle container so the cleanup closure sees them. See
% alpCleanup for why the order there matters.
st = containers.Map({'devId','seqId'}, {[], []});
cleanup = onCleanup(@() alpCleanup(LIB_ALIAS, st));

% --- Load library ---------------------------------------------------------
if ~exist(DLL_PATH, 'file')
    error('alpSmokeTest:noDLL', ...
        'DLL not found: %s\nEdit DLL_PATH at the top of this script.', DLL_PATH);
end

if ~libisloaded(LIB_ALIAS)
    fprintf('Loading %s ...\n', DLL_PATH);
    % loadlibrary with header compiles a thunk once; requires MinGW or MSVC.
    % alpPaths() sets MW_MINGW64_LOC. On this PC only R2020b has a compiler.
    loadlibrary(DLL_PATH, HEADER_PATH, 'alias', LIB_ALIAS);
    fprintf('  OK\n');
end

% --- Allocate device ------------------------------------------------------
devIdPtr = libpointer('uint32Ptr', uint32(0));
ret = calllib(LIB_ALIAS, 'AlpDevAlloc', int32(0), ALP_DEFAULT, devIdPtr);
checkRet(ret, ALP_OK, 'AlpDevAlloc');
devId = devIdPtr.Value;
st('devId') = devId;
fprintf('Device allocated  (id=0x%08X)\n', devId);

% --- Query DMD type and dimensions from board ------------------------------
dimPtr = libpointer('int32Ptr', int32(0));
calllib(LIB_ALIAS, 'AlpDevInquire', devId, int32(2021), dimPtr);  % ALP_DEV_DMDTYPE
dmdType = dimPtr.Value;
% 255=DISCONNECT (no DMD detected, defaults to 1080p), 4=DLP7000 XGA, 3=1080p
fprintf('DMD type code: %d%s\n', dmdType, ...
    iif(dmdType==255, ' (DISCONNECT — no DMD detected!)', ''));

calllib(LIB_ALIAS, 'AlpDevInquire', devId, int32(2057), dimPtr);  % ALP_DEV_DISPLAY_HEIGHT
DMD_HEIGHT = double(dimPtr.Value);
calllib(LIB_ALIAS, 'AlpDevInquire', devId, int32(2058), dimPtr);  % ALP_DEV_DISPLAY_WIDTH
DMD_WIDTH  = double(dimPtr.Value);
fprintf('DMD dimensions from board: %d x %d\n', DMD_WIDTH, DMD_HEIGHT);

% --- Allocate 1-pattern sequence (1 bit plane, 1 picture) -----------------
seqIdPtr = libpointer('uint32Ptr', uint32(0));
ret = calllib(LIB_ALIAS, 'AlpSeqAlloc', devId, int32(1), int32(1), seqIdPtr);
checkRet(ret, ALP_OK, 'AlpSeqAlloc');
seqId = seqIdPtr.Value;
st('seqId') = seqId;
fprintf('Sequence allocated (id=0x%08X)\n', seqId);

% --- Build pattern data ---------------------------------------------------
% ALP default data format is ALP_DATA_MSB_ALIGN: 1 byte per pixel regardless
% of bit depth. For a 1-bit sequence the MSB of each byte is the active bit.
nBytes = DMD_WIDTH * DMD_HEIGHT;
fprintf('Data buffer: %d bytes (1 byte/pixel)\n', nBytes);

switch lower(mode)
    case 'on'
        patternData = uint8(255 * ones(1, nBytes, 'uint8'));
        modeStr = 'ALL ON';
    case 'off'
        patternData = uint8(zeros(1, nBytes, 'uint8'));
        modeStr = 'ALL OFF';
    otherwise
        error('alpSmokeTest:badMode', 'mode must be ''on'' or ''off''');
end

% --- Upload pattern -------------------------------------------------------
dataPtr = libpointer('uint8Ptr', patternData);
fprintf('dataPtr class: %s, isNull: %d\n', class(dataPtr), isNull(dataPtr));
ret = calllib(LIB_ALIAS, 'AlpSeqPut', devId, seqId, int32(0), int32(1), dataPtr);
checkRet(ret, ALP_OK, 'AlpSeqPut');
fprintf('Pattern uploaded  (%s, %d bytes)\n', modeStr, nBytes);

% --- Start continuous projection ------------------------------------------
ret = calllib(LIB_ALIAS, 'AlpProjStartCont', devId, seqId);
checkRet(ret, ALP_OK, 'AlpProjStartCont');
fprintf('Projecting %s. Press any key to stop...\n', modeStr);
pause;

% --- Halt and free are handled by alpCleanup ------------------------------
% It runs on the normal exit below, on error, and on Ctrl-C alike, so doing
% any of it here as well would only double-free on the way out.

end

% -------------------------------------------------------------------------
function checkRet(ret, ALP_OK, fnName)
    if ret ~= ALP_OK
        error('alpSmokeTest:alpError', '%s returned error code %d', fnName, ret);
    end
end

function out = iif(cond, a, b)
    if cond, out = a; else, out = b; end
end
