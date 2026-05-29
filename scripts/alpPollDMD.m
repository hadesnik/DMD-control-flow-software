%ALPPOLLDMD  Poll DMD detection status while jiggling the flex cable.
% Prints DMD type every 0.5s. Type 255 = no DMD, 4 = DLP7000 detected.

DLL_PATH    = 'C:\Program Files\ALP-4.1\ALP-4.1 high-speed API\x64\alpD41.dll';
HEADER_PATH = fullfile(fileparts(mfilename('fullpath')), '..', ...
                       'vendor', 'alp', 'official-4.1', 'alp.h');
LIB_ALIAS   = 'alp41';
ALP_OK      = int32(0);

cleanup = onCleanup(@() doCleanup(LIB_ALIAS));

if ~libisloaded(LIB_ALIAS)
    loadlibrary(DLL_PATH, HEADER_PATH, 'alias', LIB_ALIAS);
end

devIdPtr = libpointer('uint32Ptr', uint32(0));
ret = calllib(LIB_ALIAS, 'AlpDevAlloc', int32(0), int32(0), devIdPtr);
if ret ~= ALP_OK
    error('AlpDevAlloc failed: error %d', ret);
end
devId = devIdPtr.Value;
fprintf('Device allocated (id=0x%X). Polling DMD type — jiggle the cable...\n\n', devId);

typePtr = libpointer('int32Ptr', int32(0));
fprintf('Press Ctrl+C to stop.\n\n');
prev = -1;
k = 0;
while true
    k = k + 1;
    calllib(LIB_ALIAS, 'AlpDevInquire', devId, int32(2021), typePtr);  % ALP_DEV_DMDTYPE
    t = typePtr.Value;
    if t ~= prev
        if t == 255
            fprintf('%6.2fs  NO DMD (255)\n', k*0.05);
        else
            fprintf('%6.2fs  *** DMD DETECTED: type=%d ***\n', k*0.05, t);
        end
        prev = t;
    end
    pause(0.05);
end

calllib(LIB_ALIAS, 'AlpDevFree', devId);

function doCleanup(alias)
    if libisloaded(alias), unloadlibrary(alias); end
end
