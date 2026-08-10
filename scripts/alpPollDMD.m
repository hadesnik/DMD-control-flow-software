%ALPPOLLDMD  Poll DMD detection status while jiggling the flex cable.
% Prints DMD type when it changes. Type 255 = no DMD; 12 = DLP650LNIR,
% 4 = DLP7000. Ctrl-C to stop -- the device is freed on the way out.

[DLL_PATH, HEADER_PATH, LIB_ALIAS] = alpPaths();
ALP_OK      = int32(0);

% Device id lives in a handle container so the cleanup closure sees it once
% allocated. The loop below never exits normally, so the AlpDevFree after it
% is unreachable -- this is what actually frees the device on Ctrl-C.
st = containers.Map({'devId'}, {[]});
cleanup = onCleanup(@() doCleanup(LIB_ALIAS, st));

if ~libisloaded(LIB_ALIAS)
    loadlibrary(DLL_PATH, HEADER_PATH, 'alias', LIB_ALIAS);
end

devIdPtr = libpointer('uint32Ptr', uint32(0));
ret = calllib(LIB_ALIAS, 'AlpDevAlloc', int32(0), int32(0), devIdPtr);
if ret ~= ALP_OK
    error('AlpDevAlloc failed: error %d', ret);
end
devId = devIdPtr.Value;
st('devId') = devId;
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

function doCleanup(alias, st)
    % Runs on Ctrl-C, which is the only way out of the loop above.
    if ~libisloaded(alias), return; end
    devId = st('devId');
    if ~isempty(devId)
        try calllib(alias, 'AlpDevFree', devId); catch, end   %#ok<CTCH>
        fprintf('\n[cleanup] device freed.\n');
    end
    try unloadlibrary(alias); catch, end   %#ok<CTCH>
end
