%ALPSMOKETEST43  ALP-4.3 / DLP650LNIR smoke test: load, allocate, project.
%
% First hardware bring-up check for the NIR DMD on the DAQ PC. Confirms the
% ALP-4.3 DLL loads, the board allocates, the DMD identifies itself as a
% DLP650LNIR, and mirrors respond to an uploaded pattern.
%
% Usage:
%   alpSmokeTest43                % 'checker' — visually unmistakable, low fill
%   alpSmokeTest43('disc')        % Ø324 px disc = the 3.5 mm optical patch
%   alpSmokeTest43('off')         % all mirrors off (dark reference)
%   alpSmokeTest43('on')          % REFUSED by the 50% cap — see safety note
%   alpSmokeTest43('checker', 5)  % project 5 s then halt (batch-safe)
%
% With no second argument, projection holds until a key is pressed. Pass
% holdSec to run non-interactively (matlab -batch cannot service `pause`).
%
% ---------------------------------------------------------------------------
% SAFETY — read before running with the photostim laser live
% ---------------------------------------------------------------------------
% Run this with the CARBIDE/FS-50 OFF or heavily attenuated for first light.
% You are checking that mirrors move, which needs no meaningful optical power.
%
% 'on' (uniform full-field) is the single worst pattern for this optical
% train, not merely a dull one. Every 4f relay of a collimated DMD forms a
% real focus at its pupil; with a uniform ON field the entire pulse lands in
% one ~29 um spot in air there — 2.9e14 W/cm² at the 400 uJ the CARBIDE
% delivers at 100 kHz, above where air ionises for a 200 fs pulse.
%
% This script therefore enforces the handoff §7 rule: NEVER MORE THAN 50% OF
% THE CHIP ON. 'on' is refused by that cap, deliberately. Pupil intensity
% scales as the SQUARE of the ON fraction, so 50% buys ~4x margin and the only
% thing forbidden is the full-power alignment frame nobody needs.
%
% Laser context matters: those are CARBIDE numbers. A Ti:Sapph oscillator
% (Chameleon Ultra II, 80 MHz, 1 W ~ 12.5 nJ/pulse) sits ~5000x below the
% ceiling, so the pupil hazard does not bind during oscillator bring-up.
% Check which laser is on the arm before reasoning about power.
%
% This script does not command the laser and cannot enforce the ~68 uJ pulse
% limit; that interlock lives in tfp.util.assertPulseEnergySafe. Laser state
% is your responsibility when running this directly.
% ---------------------------------------------------------------------------

function alpSmokeTest43(mode, holdSec)

if nargin < 1 || isempty(mode),    mode    = 'checker'; end
if nargin < 2 || isempty(holdSec), holdSec = [];        end
% holdSec empty  -> project until a key is pressed (interactive default)
% holdSec numeric-> project for that many seconds, then halt (batch-safe)

% --- Installed ALP-4.3 SDK (x64) ------------------------------------------
% The header must match the DLL. vendor/alp/official/alp.h is byte-identical
% to the installed copy apart from line endings, so either works; prefer the
% installed one so an SDK upgrade is picked up automatically.
DLL_PATH = 'C:\Program Files\ALP-4.3\ALP-4.3 API\x64\alp4395.dll';
HDR_PATH = 'C:\Program Files\ALP-4.3\ALP-4.3 API\alp.h';
LIB      = 'alp4395';

% --- ALP constants, verbatim from vendor/alp/official/alp.h (Version 28) --
ALP_OK                  = 0;
ALP_DEFAULT             = 0;
ALP_NOT_ONLINE          = 1001;    % alp.h:55  board not found / not ready
ALP_DEV_DMDTYPE         = 2021;    % alp.h:141
ALP_DMDTYPE_WXGA_S450   = 12;      % alp.h:153  DLP650LNIR for DLPC410
ALP_DMDTYPE_DISCONNECT  = 255;     % alp.h:155  no DMD on the controller
ALP_DEV_DISPLAY_HEIGHT  = 2057;    % alp.h:157
ALP_DEV_DISPLAY_WIDTH   = 2058;    % alp.h:158
ALP_PROJ_MODE           = 2300;    % alp.h:321
ALP_MASTER              = 2301;    % alp.h:322  internal timing

% Expected geometry for the DLP650LNIR
EXPECT_W = 1280;
EXPECT_H = 800;

% Usable patch, from docs/dmd_control_handoff.md §4 (build 3.5mm 50/400 250/60).
% NOT 556 px: that was the Ø6 mm patch of an earlier revision that assumed the
% periscope demagnified. The periscope order was measured 2026-07-27 and it
% magnifies, which shrank the patch to Ø3.5 mm. Mirrors outside it are not
% illuminated, so lighting them achieves nothing.
%
% STALE 2026-08-06: that handoff revision assumes a Nikon CFI75 LWD 16x/0.8,
% which is not the objective on the bench. Patch size and both um/px constants
% move with the objective. Regenerate the handoff before trusting this for
% calibrated work. It remains fine for a smoke test: undersizing the patch is
% harmless (fewer mirrors lit, all of them inside any plausible footprint) and
% it keeps the ON fraction well under the 50% cap either way.
PATCH_DIAM_PX = 324;               % 3.5 mm / 10.8 um pitch -- PROVISIONAL

% Hard software rule, handoff §7: never load a frame with >50% of the chip ON.
% Pupil intensity scales as the SQUARE of the ON fraction for a contiguous
% region, so 50% buys ~4x margin against air breakdown at the operating point.
MAX_ON_FRACTION = 0.50;

fprintf('=== ALP-4.3 smoke test (%s) ===\n', mode);

% MinGW is needed because loadlibrary compiles a thunk from the header. The
% precompiled proto file is deliberately not used: it mismarshals the void*
% data buffer in AlpSeqPut. See DLP650LNIR_DMD.m.
mingw = 'C:\ProgramData\MATLAB\SupportPackages\R2020b\3P.instrset\mingw_w64.instrset';
if isfolder(mingw), setenv('MW_MINGW64_LOC', mingw); end

if ~isfile(DLL_PATH)
    error('alpSmokeTest43:noDLL', 'DLL not found: %s', DLL_PATH);
end
if ~isfile(HDR_PATH)
    error('alpSmokeTest43:noHeader', 'Header not found: %s', HDR_PATH);
end

% Live IDs live in a containers.Map because it is a handle class: the cleanup
% closure captures the handle and therefore sees later updates. A nested
% function cannot be used here — onCleanup runs its task after the parent
% workspace is destroyed, so uplevel variables are already gone.
% onCleanup rather than try/catch because Ctrl-C during the pause below is
% the likely exit, and that must still halt projection.
st = containers.Map({'devId', 'seqId'}, {[], []});
cleanupObj = onCleanup(@() doCleanup(LIB, st));

% --- Load library ---------------------------------------------------------
if ~libisloaded(LIB)
    fprintf('Loading %s ...\n', DLL_PATH);
    loadlibrary(DLL_PATH, HDR_PATH, 'alias', LIB);
end
fprintf('  DLL loaded (%s)\n', fileVersion(DLL_PATH));

% --- Allocate device ------------------------------------------------------
devPtr = libpointer('uint32Ptr', uint32(0));
ret = calllib(LIB, 'AlpDevAlloc', int32(0), int32(ALP_DEFAULT), devPtr);
if ret == ALP_NOT_ONLINE
    error('alpSmokeTest43:notOnline', ...
        ['AlpDevAlloc returned ALP_NOT_ONLINE (1001): no board found.\n' ...
         'Check: DLPC410 powered on, USB cable to this PC, and the ViALUX\n' ...
         'device visible in Device Manager (not under Unknown devices).']);
end
checkRet(ret, ALP_OK, 'AlpDevAlloc');
devId = devPtr.Value;
st('devId') = devId;
fprintf('Device allocated (id=0x%08X)\n', devId);

% --- Identify the DMD -----------------------------------------------------
p = libpointer('int32Ptr', int32(0));
calllib(LIB, 'AlpDevInquire', devId, int32(ALP_DEV_DMDTYPE), p);
dmdType = double(p.Value);
calllib(LIB, 'AlpDevInquire', devId, int32(ALP_DEV_DISPLAY_WIDTH),  p); W = double(p.Value);
calllib(LIB, 'AlpDevInquire', devId, int32(ALP_DEV_DISPLAY_HEIGHT), p); H = double(p.Value);

fprintf('DMD type code : %d', dmdType);
switch dmdType
    case ALP_DMDTYPE_WXGA_S450
        fprintf('  (DLP650LNIR — expected)\n');
    case ALP_DMDTYPE_DISCONNECT
        fprintf('  (DISCONNECT)\n');
        error('alpSmokeTest43:dmdDisconnected', ...
            ['DMD type 255 = ALP_DMDTYPE_DISCONNECT: the controller is\n' ...
             'reachable but no DMD is detected on it. Check the flex cable\n' ...
             'between the DLPC410 and the DLP650LNIR head. Dimensions\n' ...
             'reported in this state default to 1080p and are meaningless.']);
    otherwise
        fprintf('  (UNEXPECTED)\n');
        warning('alpSmokeTest43:unexpectedDmdType', ...
            'Expected %d (DLP650LNIR), got %d. Continuing.', ...
            ALP_DMDTYPE_WXGA_S450, dmdType);
end

fprintf('Dimensions    : %d x %d\n', W, H);
if W ~= EXPECT_W || H ~= EXPECT_H
    warning('alpSmokeTest43:unexpectedDims', ...
        'Expected %dx%d for DLP650LNIR, board reports %dx%d.', ...
        EXPECT_W, EXPECT_H, W, H);
end

% --- Internal timing (no external trigger for a smoke test) ---------------
% ALP_PROJ_MODE is a projection control type (alp.h:321, in the ALP_PROJ_*
% block), so it goes to AlpProjControl (alp.h:589) -- NOT AlpDevControl,
% which only accepts ALP_DEV_* types and returns ALP_PARM_INVALID (1005).
% ALP_MASTER is already the default; set explicitly so the script does not
% inherit a slave/trigger configuration left behind by an earlier session.
ret = calllib(LIB, 'AlpProjControl', devId, int32(ALP_PROJ_MODE), int32(ALP_MASTER));
checkRet(ret, ALP_OK, 'AlpProjControl(ALP_PROJ_MODE, ALP_MASTER)');

% --- Build the pattern ----------------------------------------------------
[img, label, fillPct] = buildPattern(mode, W, H, PATCH_DIAM_PX);
fprintf('Pattern       : %s  (%.2f%% of mirrors ON)\n', label, fillPct);

% Enforce the 50% cap before anything is uploaded. One comparison per frame.
if fillPct > 100 * MAX_ON_FRACTION
    error('alpSmokeTest43:onFractionTooHigh', ...
        ['Pattern lights %.1f%% of the chip; the cap is %.0f%% ' ...
         '(docs/dmd_control_handoff.md §7).\n' ...
         'Pupil intensity scales as the SQUARE of the ON fraction, so a ' ...
         'full-field frame\nsits above air breakdown at the CARBIDE ' ...
         'operating point. If you genuinely need\na solid high-fill target, ' ...
         'drop the laser power first and raise MAX_ON_FRACTION\ndeliberately ' ...
         'rather than by accident.'], fillPct, 100 * MAX_ON_FRACTION);
end

% ALP default data format is ALP_DATA_MSB_ALIGN: one byte per pixel for a
% 1-bit sequence, MSB is the active bit. ALP wants row-major order, so
% transpose before linearising (MATLAB is column-major).
patternData = uint8(img') * uint8(255);
patternData = reshape(patternData, 1, []);
nBytes = numel(patternData);
if nBytes ~= W * H
    error('alpSmokeTest43:badBufferSize', ...
        'Buffer is %d bytes, expected %d (=%dx%d).', nBytes, W*H, W, H);
end

% --- Allocate and upload a 1-picture, 1-bit sequence ----------------------
seqPtr = libpointer('uint32Ptr', uint32(0));
ret = calllib(LIB, 'AlpSeqAlloc', devId, int32(1), int32(1), seqPtr);
checkRet(ret, ALP_OK, 'AlpSeqAlloc');
seqId = seqPtr.Value;
st('seqId') = seqId;

dataPtr = libpointer('uint8Ptr', patternData);
ret = calllib(LIB, 'AlpSeqPut', devId, seqId, int32(0), int32(1), dataPtr);
checkRet(ret, ALP_OK, 'AlpSeqPut');
fprintf('Uploaded      : %d bytes\n', nBytes);

% --- Project continuously -------------------------------------------------
ret = calllib(LIB, 'AlpProjStartCont', devId, seqId);
checkRet(ret, ALP_OK, 'AlpProjStartCont');
if isempty(holdSec)
    fprintf('\nProjecting. Press any key to halt...\n');
    pause;
else
    fprintf('\nProjecting for %g s...\n', holdSec);
    pause(holdSec);
end

calllib(LIB, 'AlpProjHalt', devId);
fprintf('Projection halted.\n');

% Clearing these is load-bearing: doCleanup still holds `st` and would
% otherwise double-free on the way out. Code Analyzer flags the assignments as
% unused because it cannot see the handle captured by the cleanup closure.
calllib(LIB, 'AlpSeqFree', devId, seqId);   st('seqId') = [];
calllib(LIB, 'AlpDevFree', devId);          st('devId') = [];   %#ok<NASGU>
fprintf('Resources freed.\n=== smoke test complete ===\n');

end

% ==========================================================================
function [img, label, fillPct] = buildPattern(mode, W, H, patchDiam)
%buildPattern Logical H x W mirror map. true = mirror ON.
%   Patterns stay inside the Ø556 px optical patch where that is meaningful:
%   mirrors outside it are not illuminated, so lighting them achieves nothing.

img = false(H, W);
cx  = (W + 1) / 2;
cy  = (H + 1) / 2;
r   = patchDiam / 2;

switch lower(mode)
    case 'checker'
        % 64 px squares, restricted to the patch. Coarse enough to see by eye
        % on a card, and 50% fill keeps the pupil peak far below the limit.
        [X, Y] = meshgrid(1:W, 1:H);
        checker = mod(floor((X - 1) / 64) + floor((Y - 1) / 64), 2) == 0;
        inPatch = (X - cx).^2 + (Y - cy).^2 <= r^2;
        img = checker & inPatch;
        label = sprintf('checkerboard, 64 px squares, inside O%d px patch', patchDiam);

    case 'disc'
        [X, Y] = meshgrid(1:W, 1:H);
        img = (X - cx).^2 + (Y - cy).^2 <= r^2;
        label = sprintf('filled disc, O%d px = 3.5 mm patch', patchDiam);

    case 'off'
        label = 'all mirrors OFF';

    case 'on'
        img = true(H, W);
        label = 'all mirrors ON (full field)';

    otherwise
        error('alpSmokeTest43:badMode', ...
            'mode must be ''checker'', ''disc'', ''off'' or ''on''; got ''%s''.', mode);
end

fillPct = 100 * nnz(img) / numel(img);
end

% --------------------------------------------------------------------------
function checkRet(ret, ALP_OK, fnName)
if ret ~= ALP_OK
    error('alpSmokeTest43:alpError', '%s returned %d (see alp.h lines 54-69).', ...
        fnName, ret);
end
end

% --------------------------------------------------------------------------
function doCleanup(lib, st)
%doCleanup Halt and release anything still open, then unload the library.
%   Runs on normal exit, on error, and on Ctrl-C, so it must never throw.
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

% --------------------------------------------------------------------------
function s = fileVersion(p)
try
    info = System.Diagnostics.FileVersionInfo.GetVersionInfo(p);
    s = char(info.FileVersion);
catch
    s = 'version unknown';
end
end

