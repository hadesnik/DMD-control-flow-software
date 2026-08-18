%ALPCLEANUP  Release an ALP device and unload the library. Never throws.
%
% Ctrl-C and errors both run onCleanup handlers, so this is the only thing
% standing between an interrupted bench script and a MATLAB crash.
%
%   st = containers.Map({'devId','seqId'}, {[], []});
%   cleanup = onCleanup(@() alpCleanup(LIB_ALIAS, st));
%   ...
%   devId = devIdPtr.Value;  st('devId') = devId;
%   seqId = seqIdPtr.Value;  st('seqId') = seqId;
%
% containers.Map is a handle class, so the closure captured above sees ids
% recorded after onCleanup was armed. A nested function cannot do this job:
% onCleanup runs after the parent workspace is destroyed, so uplevel
% variables are already gone by then.
%
% ORDER IS LOAD-BEARING -- halt, free the sequence, free the device, and only
% then unload. Calling unloadlibrary while a sequence is still projecting rips
% the DLL out from under an active driver context and takes MATLAB down with
% it, which is not an interruptible error: the crash IS the cleanup.
%
% Every step is wrapped, because a handler that throws masks the original
% error and leaves the device allocated for the next run to trip over (1004).

function alpCleanup(alias, st)

if nargin < 2 || isempty(st), st = containers.Map(); end
if ~libisloaded(alias), return; end

devId = mapGet(st, 'devId');
seqId = mapGet(st, 'seqId');

if ~isempty(devId)
    try calllib(alias, 'AlpProjHalt', devId); catch, end   %#ok<CTCH>
    if ~isempty(seqId)
        try calllib(alias, 'AlpSeqFree', devId, seqId); catch, end   %#ok<CTCH>
    end
    try calllib(alias, 'AlpDevFree', devId); catch, end   %#ok<CTCH>
    fprintf('[cleanup] projection halted, device freed.\n');
end

try unloadlibrary(alias); catch, end   %#ok<CTCH>

end

% -------------------------------------------------------------------------
function v = mapGet(st, key)
%mapGet Read a key that may never have been set, without throwing.
v = [];
try
    if isKey(st, key), v = st(key); end
catch   %#ok<CTCH>
end
end
