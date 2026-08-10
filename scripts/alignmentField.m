%ALIGNMENTFIELD  Hold an all-mirrors-ON field on the DLP650LNIR for alignment.
%
% Lights the whole chip and holds it, so the Gaussian illumination footprint is
% directly visible. That is the measurement that establishes where the usable
% patch actually is -- worth doing independently, since the Ø3.5 mm / 324 px
% figure in docs/dmd_control_handoff.md is known stale (it assumes a Nikon
% CFI75 16×/0.8 and an Olympus 180 mm tube; neither matches the bench).
%
% Usage:
%   alignmentField                % all-ON, hold until stopped
%   alignmentField(0.5)           % 50% checker instead (respects the cap)
%   alignmentField([], 30)        % all-ON for 30 s, then halt (batch-safe)
%
% Stop a held field by creating a file named STOP_PROJECTION next to this
% script, or press Ctrl-C -- both halt projection and free the device.
%
% ---------------------------------------------------------------------------
% SAFETY -- this deliberately overrides the 50% ON-fraction cap
% ---------------------------------------------------------------------------
% docs/dmd_control_handoff.md §7 caps ON fraction at 50% because a uniform
% field focuses the whole pulse into one ~29 µm spot in air at the relay pupil.
% That cap is set by the CARBIDE, and does not bind on an oscillator:
%
%   CARBIDE CB3-40W     400 µJ @ 100 kHz, 200 fs  ->  ~2.9e14 W/cm² at the
%                       pupil for a uniform field. ABOVE air breakdown (~5e13).
%   Chameleon Ultra II  1 W @ 80 MHz = 12.5 nJ/pulse, ~140 fs
%                       ->  89 kW peak / pi*(14.5 µm)²  ~  1.4e10 W/cm²
%                       ~3700x BELOW breakdown; ~5000x below the 68 µJ ceiling.
%
% The handoff permits exactly this case: "If a solid alignment target is ever
% wanted, keep it under 50% AND drop the laser power." An oscillator IS the
% dropped-power condition, by four orders of magnitude.
%
% *** DO NOT RUN THIS WITH THE CARBIDE ON THE ARM. ***
% There is no interlock here that can tell which laser is connected -- that
% check is yours. tfp.util.assertPulseEnergySafe is the programmatic gate.
% ---------------------------------------------------------------------------

function alignmentField(onFraction, holdSec)

if nargin < 1 || isempty(onFraction), onFraction = 1.0; end
if nargin < 2, holdSec = []; end   % [] = hold until stopped

HERE       = fileparts(mfilename('fullpath'));
STOP_FILE  = fullfile(HERE, 'STOP_PROJECTION');
MAX_HOLD_S = 4 * 3600;

[DLL, HDR, LIB] = alpPaths('4.3');

% Constants verbatim from vendor/alp/official/alp.h (Version 28)
ALP_OK = 0; ALP_DEFAULT = 0;
ALP_DEV_DMDTYPE        = 2021;   % alp.h:141
ALP_DMDTYPE_WXGA_S450  = 12;     % alp.h:153  DLP650LNIR
ALP_DEV_DISPLAY_HEIGHT = 2057;   % alp.h:157
ALP_DEV_DISPLAY_WIDTH  = 2058;   % alp.h:158
ALP_PROJ_MODE          = 2300;   % alp.h:321
ALP_MASTER             = 2301;   % alp.h:322

if isfile(STOP_FILE), delete(STOP_FILE); end

% loadlibrary compiles a thunk from the header, so a C compiler is required.
% Only R2020b has MinGW on this PC.
mingw = 'C:\ProgramData\MATLAB\SupportPackages\R2020b\3P.instrset\mingw_w64.instrset';
if isfolder(mingw), setenv('MW_MINGW64_LOC', mingw); end

% containers.Map is a handle class, so the cleanup closure sees later updates.
% A nested function cannot be used: onCleanup runs after the parent workspace
% is destroyed, and uplevel variables are gone by then.
st = containers.Map({'devId','seqId'}, {[], []});
cleanupObj = onCleanup(@() doCleanup(LIB, st));

if ~libisloaded(LIB), loadlibrary(DLL, HDR, 'alias', LIB); end

devPtr = libpointer('uint32Ptr', uint32(0));
ret = calllib(LIB, 'AlpDevAlloc', int32(0), int32(ALP_DEFAULT), devPtr);
if ret ~= ALP_OK
    error('tfp:scripts:alignmentField:devAlloc', ...
        ['AlpDevAlloc returned %d. 1001 = no board (check power/USB); ' ...
         '1004 = already allocated by another MATLAB session.'], ret);
end
devId = devPtr.Value; st('devId') = devId;

p = libpointer('int32Ptr', int32(0));
calllib(LIB, 'AlpDevInquire', devId, int32(ALP_DEV_DMDTYPE), p);        dmdType = double(p.Value);
calllib(LIB, 'AlpDevInquire', devId, int32(ALP_DEV_DISPLAY_WIDTH),  p); W = double(p.Value);
calllib(LIB, 'AlpDevInquire', devId, int32(ALP_DEV_DISPLAY_HEIGHT), p); H = double(p.Value);
fprintf('DMD type %d%s, %d x %d\n', dmdType, ...
    repmat(' (DLP650LNIR)', 1, dmdType == ALP_DMDTYPE_WXGA_S450), W, H);

ret = calllib(LIB, 'AlpProjControl', devId, int32(ALP_PROJ_MODE), int32(ALP_MASTER));
if ret ~= ALP_OK
    error('tfp:scripts:alignmentField:projControl', 'AlpProjControl returned %d', ret);
end

% --- Build the field ------------------------------------------------------
% One byte per pixel, 0xFF = ON (ALP_DATA_MSB_ALIGN default; for a 1-bit
% sequence the MSB of each byte is the active bit).
if onFraction >= 1.0
    patternData = repmat(uint8(255), 1, W * H);
    label = 'ALL MIRRORS ON (100% fill)';
else
    % Checkerboard scaled to approximate the requested fraction over the chip.
    blk = 64;
    [X, Y] = meshgrid(1:W, 1:H);
    img = mod(floor((X-1)/blk) + floor((Y-1)/blk), 2) == 0;
    if onFraction < 0.5
        keep = rand(H, W) < (onFraction / 0.5);
        img = img & keep;
    end
    patternData = reshape(uint8(img') * uint8(255), 1, []);
    label = sprintf('checker, %.1f%% fill', 100*nnz(img)/numel(img));
end
fprintf('Pattern: %s, %d bytes\n', label, numel(patternData));

if onFraction > 0.5
    fprintf(2, ['\n!! 50%%%% ON-fraction cap OVERRIDDEN (handoff §7).\n' ...
                '!! Valid for an oscillator; NOT valid with the CARBIDE.\n' ...
                '!! Confirm which laser is on the arm.\n\n']);
end

seqPtr = libpointer('uint32Ptr', uint32(0));
ret = calllib(LIB, 'AlpSeqAlloc', devId, int32(1), int32(1), seqPtr);
if ret ~= ALP_OK
    error('tfp:scripts:alignmentField:seqAlloc', 'AlpSeqAlloc returned %d', ret);
end
% Recording seqId in `st` is load-bearing -- doCleanup reads it to free the
% sequence. Code Analyzer flags it as unused because it cannot see the handle
% captured by the cleanup closure.
seqId = seqPtr.Value; st('seqId') = seqId;   %#ok<NASGU>

dataPtr = libpointer('uint8Ptr', patternData);
ret = calllib(LIB, 'AlpSeqPut', devId, seqId, int32(0), int32(1), dataPtr);
if ret ~= ALP_OK
    error('tfp:scripts:alignmentField:seqPut', 'AlpSeqPut returned %d', ret);
end

ret = calllib(LIB, 'AlpProjStartCont', devId, seqId);
if ret ~= ALP_OK
    error('tfp:scripts:alignmentField:projStart', 'AlpProjStartCont returned %d', ret);
end

fprintf('\n*** FIELD IS ON AND HELD ***\n');
if isempty(holdSec)
    fprintf('stop with: %s\n', STOP_FILE);
    fprintf('auto-stop after %g h\n\n', MAX_HOLD_S/3600);
    t0 = tic;
    while ~isfile(STOP_FILE) && toc(t0) < MAX_HOLD_S
        pause(0.25);
    end
    if isfile(STOP_FILE)
        fprintf('stop file seen after %.1f s\n', toc(t0));
        delete(STOP_FILE);
    else
        fprintf('max hold reached (%.1f s)\n', toc(t0));
    end
else
    fprintf('holding %g s\n\n', holdSec);
    pause(holdSec);
end
% cleanupObj halts projection, frees the device and unloads on the way out.
end

% -------------------------------------------------------------------------
function doCleanup(lib, st)
%doCleanup Halt and release everything. Runs on normal exit, error and Ctrl-C,
%   so it must never throw.
if ~libisloaded(lib), return; end
devId = st('devId');
if ~isempty(devId)
    try calllib(lib, 'AlpProjHalt', devId); catch, end   %#ok<CTCH>
    seqId = st('seqId');
    if ~isempty(seqId)
        try calllib(lib, 'AlpSeqFree', devId, seqId); catch, end   %#ok<CTCH>
    end
    try calllib(lib, 'AlpDevFree', devId); catch, end   %#ok<CTCH>
    fprintf('[cleanup] projection halted, device freed.\n');
end
try unloadlibrary(lib); catch, end   %#ok<CTCH>
end
