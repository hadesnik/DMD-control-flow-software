%ALPSMOKE TEST  Minimal ALP-4.1 smoke test: projects an all-on pattern.
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

% -----------------------------------------------------------------------
% CONFIGURE: set DLL_PATH to wherever the ALP SDK installed alp41.dll
% Typical locations after running the Vialux ALP-4.1 SDK installer:
%   C:\ALP-4.1\alp41.dll
%   C:\Program Files\ALP\alp41.dll
% -----------------------------------------------------------------------
DLL_PATH = 'C:\Program Files\ALP-4.1\ALP-4.1 high-speed API\x64\alpD41.dll';

LIB_ALIAS = 'alp41';

ALP_OK      = int32(0);
ALP_DEFAULT = int32(0);

cleanup = onCleanup(@() doCleanup(LIB_ALIAS));

% --- Load library ---------------------------------------------------------
if ~exist(DLL_PATH, 'file')
    error('alpSmokeTest:noDLL', ...
        'DLL not found: %s\nEdit DLL_PATH at the top of this script.', DLL_PATH);
end

if ~libisloaded(LIB_ALIAS)
    fprintf('Loading %s ...\n', DLL_PATH);
    HEADER_PATH = fullfile(fileparts(mfilename('fullpath')), '..', ...
                           'vendor', 'alp', 'official-4.1', 'alp.h');
    % loadlibrary with header compiles a thunk once; requires MinGW or MSVC.
    % Install MinGW free via MATLAB Add-Ons if not present.
    loadlibrary(DLL_PATH, HEADER_PATH, 'alias', LIB_ALIAS);
    fprintf('  OK\n');
end

% --- Allocate device ------------------------------------------------------
devIdPtr = libpointer('uint32Ptr', uint32(0));
ret = calllib(LIB_ALIAS, 'AlpDevAlloc', int32(0), ALP_DEFAULT, devIdPtr);
checkRet(ret, ALP_OK, 'AlpDevAlloc');
devId = devIdPtr.Value;
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

% --- Halt projection ------------------------------------------------------
calllib(LIB_ALIAS, 'AlpProjHalt', devId);
fprintf('Projection halted.\n');

% --- Free sequence and device are handled by onCleanup -------------------
calllib(LIB_ALIAS, 'AlpSeqFree', devId, seqId);
calllib(LIB_ALIAS, 'AlpDevFree', devId);
fprintf('Resources freed.\n');

end

% -------------------------------------------------------------------------
function checkRet(ret, ALP_OK, fnName)
    if ret ~= ALP_OK
        error('alpSmokeTest:alpError', '%s returned error code %d', fnName, ret);
    end
end

function doCleanup(libAlias)
    if libisloaded(libAlias)
        unloadlibrary(libAlias);
    end
end

function out = iif(cond, a, b)
    if cond, out = a; else, out = b; end
end
