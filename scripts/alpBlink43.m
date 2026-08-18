%ALPBLINK43  Blink the DLP650LNIR between a bright frame and all-mirrors-OFF.
%
% A two-picture ALP sequence (bright, dark) started with AlpProjStartCont, so
% the blink is timed by the board and repeats indefinitely until you stop it.
% Press any key or Ctrl-C to halt; either path runs the same cleanup.
%
% The point of a blink rather than a static frame: a moving signal is findable
% on a card or a camera when a static one is lost in room light, and it tells
% you the mirrors are actually being clocked rather than stuck in a state a
% previous session left behind.
%
% Usage:
%   alpBlink43                     % disc at the design patch, 1 Hz
%   alpBlink43('checker')          % 64 px checker inside the patch
%   alpBlink43('disc', 0.25)       % 4 Hz blink
%   alpBlink43('disc', 1, 10)      % blink for 10 s then halt (batch-safe)
%   alpBlink43('on')               % REFUSED by the 50% cap -- see safety note
%
% With no holdSec, the blink runs until a key is pressed. Pass holdSec to run
% non-interactively (matlab -batch cannot service `pause`).
%
% ---------------------------------------------------------------------------
% SAFETY -- read before running with the photostim laser live
% ---------------------------------------------------------------------------
% Same rule as alpSmokeTest43, and for the same reason: docs/optics_handoff.md
% sec 7 caps the ON fraction at 50% of the chip. Blinking does NOT relax it.
% The cap is on the INSTANTANEOUS pupil intensity during the bright half, and
% that is identical to the static case -- the 50% duty cycle halves the mean
% power at the sample and changes the peak not at all. The bright frame is
% checked against the cap before anything is uploaded; 'on' is refused.
%
% The dark half is genuinely dark: every mirror in the OFF state, so the pulse
% goes to the beam dump, not to the sample.
%
% This script does not command the laser. Laser state is your responsibility.
% ---------------------------------------------------------------------------

function alpBlink43(mode, periodSec, holdSec)

if nargin < 1 || isempty(mode),      mode      = 'disc'; end
if nargin < 2 || isempty(periodSec), periodSec = 1.0;    end
if nargin < 3 || isempty(holdSec),   holdSec   = [];     end

validateattributes(periodSec, {'numeric'}, {'scalar', 'positive', 'finite'}, ...
    mfilename, 'periodSec');

[DLL_PATH, HDR_PATH, LIB] = alpPaths('4.3');

% --- ALP constants, verbatim from vendor/alp/official/alp.h (Version 28) --
ALP_OK                  = 0;
ALP_DEFAULT             = 0;
ALP_NOT_ONLINE          = 1001;    % alp.h:55
ALP_DEV_DMDTYPE         = 2021;    % alp.h:141
ALP_DMDTYPE_WXGA_S450   = 12;      % alp.h:153  DLP650LNIR for DLPC410
ALP_DMDTYPE_DISCONNECT  = 255;     % alp.h:155
ALP_DEV_DISPLAY_HEIGHT  = 2057;    % alp.h:157
ALP_DEV_DISPLAY_WIDTH   = 2058;    % alp.h:158
ALP_PICTURE_TIME        = 2203;    % alp.h:269
ALP_ILLUMINATE_TIME     = 2204;    % alp.h:272
ALP_MIN_PICTURE_TIME    = 2211;    % alp.h:281
ALP_MAX_PICTURE_TIME    = 2213;    % alp.h:284
ALP_PROJ_MODE           = 2300;    % alp.h:321
ALP_MASTER              = 2301;    % alp.h:322  internal timing

EXPECT_W = 1280;
EXPECT_H = 800;

% Patch diameter and ON cap are READ FROM THE HANDOFF at runtime -- see the
% same block in alpSmokeTest43.m for why this script asks rather than
% remembers. Falls back to the current generated values if src/ is off path.
try
    hc              = tfp.util.readHandoffConstants();
    PATCH_DIAM_PX   = hc.patch_diameter_px;
    MAX_ON_FRACTION = hc.on_fraction_cap;
    constSrc        = sprintf('handoff rev %g', hc.handoff_rev);
catch
    PATCH_DIAM_PX   = 463;    % O5.0 mm at 10.8 um pitch, handoff rev 4
    MAX_ON_FRACTION = 0.50;   % handoff sec 7
    constSrc        = 'built-in fallback (src/ not on path)';
end

fprintf('=== ALP-4.3 blink (%s, %.3g Hz) ===\n', mode, 1 / periodSec);
fprintf('patch %g px, ON cap %.0f%%  [%s]\n', ...
    PATCH_DIAM_PX, 100 * MAX_ON_FRACTION, constSrc);

mingw = 'C:\ProgramData\MATLAB\SupportPackages\R2020b\3P.instrset\mingw_w64.instrset';
if isfolder(mingw), setenv('MW_MINGW64_LOC', mingw); end

if ~isfile(DLL_PATH)
    error('alpBlink43:noDLL', 'DLL not found: %s', DLL_PATH);
end
if ~isfile(HDR_PATH)
    error('alpBlink43:noHeader', 'Header not found: %s', HDR_PATH);
end

% Handle-class map so the cleanup closure sees later updates; onCleanup rather
% than try/catch because Ctrl-C during the wait is the expected exit and it
% must still halt projection. Same construction as alpSmokeTest43.
st = containers.Map({'devId', 'seqId'}, {[], []});
cleanupObj = onCleanup(@() doCleanup(LIB, st));

% --- Load library ---------------------------------------------------------
if ~libisloaded(LIB)
    fprintf('Loading %s ...\n', DLL_PATH);
    loadlibrary(DLL_PATH, HDR_PATH, 'alias', LIB);
end

% --- Allocate device ------------------------------------------------------
devPtr = libpointer('uint32Ptr', uint32(0));
ret = calllib(LIB, 'AlpDevAlloc', int32(0), int32(ALP_DEFAULT), devPtr);
if ret == ALP_NOT_ONLINE
    error('alpBlink43:notOnline', ...
        ['AlpDevAlloc returned ALP_NOT_ONLINE (1001): no board found.\n' ...
         'Check the DLPC410 is powered and visible in Device Manager.']);
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

if dmdType == ALP_DMDTYPE_DISCONNECT
    error('alpBlink43:dmdDisconnected', ...
        ['DMD type 255 = ALP_DMDTYPE_DISCONNECT: the controller is reachable\n' ...
         'but no DMD is detected. Check the flex cable to the DLP650LNIR.']);
elseif dmdType ~= ALP_DMDTYPE_WXGA_S450
    warning('alpBlink43:unexpectedDmdType', ...
        'Expected %d (DLP650LNIR), got %d. Continuing.', ALP_DMDTYPE_WXGA_S450, dmdType);
end
if W ~= EXPECT_W || H ~= EXPECT_H
    warning('alpBlink43:unexpectedDims', ...
        'Expected %dx%d for DLP650LNIR, board reports %dx%d.', EXPECT_W, EXPECT_H, W, H);
end
fprintf('DMD %d x %d, type code %d\n', W, H, dmdType);

% --- Internal timing ------------------------------------------------------
% ALP_PROJ_MODE is an ALP_PROJ_* type so it goes to AlpProjControl, not
% AlpDevControl (which returns ALP_PARM_INVALID for it). Set explicitly so a
% slave/trigger configuration left by an earlier session is not inherited.
ret = calllib(LIB, 'AlpProjControl', devId, int32(ALP_PROJ_MODE), int32(ALP_MASTER));
checkRet(ret, ALP_OK, 'AlpProjControl(ALP_PROJ_MODE, ALP_MASTER)');

% --- Build the two frames -------------------------------------------------
[bright, label, fillPct] = buildPattern(mode, W, H, PATCH_DIAM_PX);
dark = false(H, W);
fprintf('Bright frame  : %s  (%.2f%% of mirrors ON)\n', label, fillPct);
fprintf('Dark frame    : all mirrors OFF (0.00%%)\n');

% Cap check on the BRIGHT frame. Blinking does not relax it: the pupil peak
% during the bright half is what the cap is about, and a 50% duty cycle does
% not change it.
if fillPct > 100 * MAX_ON_FRACTION
    error('alpBlink43:onFractionTooHigh', ...
        ['Bright frame lights %.1f%% of the chip; the cap is %.0f%% ' ...
         '(docs/optics_handoff.md sec 7).\nBlinking halves the MEAN power ' ...
         'and leaves the pupil PEAK unchanged, so the cap still binds.\n' ...
         'Use ''disc'' or ''checker'', or drop the laser power and raise the ' ...
         'cap deliberately.'], fillPct, 100 * MAX_ON_FRACTION);
end

% ALP_DATA_MSB_ALIGN: one byte per pixel, MSB active. ALP wants row-major, so
% transpose before linearising (MATLAB is column-major). Frame 0 = bright,
% frame 1 = dark; AlpSeqPut takes them as one contiguous buffer.
frameBytes = @(img) reshape(uint8(img') * uint8(255), 1, []);
patternData = [frameBytes(bright), frameBytes(dark)];
if numel(patternData) ~= 2 * W * H
    error('alpBlink43:badBufferSize', ...
        'Buffer is %d bytes, expected %d (=2x%dx%d).', numel(patternData), 2*W*H, W, H);
end

% --- Allocate and upload a 2-picture, 1-bit sequence ----------------------
seqPtr = libpointer('uint32Ptr', uint32(0));
ret = calllib(LIB, 'AlpSeqAlloc', devId, int32(1), int32(2), seqPtr);
checkRet(ret, ALP_OK, 'AlpSeqAlloc');
seqId = seqPtr.Value;
st('seqId') = seqId;

dataPtr = libpointer('uint8Ptr', patternData);
ret = calllib(LIB, 'AlpSeqPut', devId, seqId, int32(0), int32(2), dataPtr);
checkRet(ret, ALP_OK, 'AlpSeqPut');

% --- Timing: each frame holds for half the blink period -------------------
% ALP_PICTURE_TIME = ALP_ON_TIME + ALP_OFF_TIME (alp.h:286), so illuminate
% time is set EQUAL to picture time -- any shortfall would insert an extra
% dark interval inside the bright half and make the duty cycle a lie.
halfUs = round(periodSec * 1e6 / 2);
calllib(LIB, 'AlpSeqInquire', devId, seqId, int32(ALP_MIN_PICTURE_TIME), p);
minPicUs = double(p.Value);
calllib(LIB, 'AlpSeqInquire', devId, seqId, int32(ALP_MAX_PICTURE_TIME), p);
maxPicUs = double(p.Value);
if halfUs < minPicUs || halfUs > maxPicUs
    error('alpBlink43:periodOutOfRange', ...
        ['Half-period %g us is outside what the board allows for this ' ...
         'sequence (%g to %g us).\nThat is a blink period of %g to %g s.'], ...
        halfUs, minPicUs, maxPicUs, 2e-6 * minPicUs, 2e-6 * maxPicUs);
end

ret = calllib(LIB, 'AlpSeqTiming', devId, seqId, int32(halfUs), int32(halfUs), ...
    int32(0), int32(0), int32(0));
checkRet(ret, ALP_OK, 'AlpSeqTiming');

% Report what the board ACCEPTED, not what was asked for -- ALP is entitled to
% round these, and a blink that is not the rate you asked for is worth seeing.
calllib(LIB, 'AlpSeqInquire', devId, seqId, int32(ALP_PICTURE_TIME), p);
picUs = double(p.Value);
calllib(LIB, 'AlpSeqInquire', devId, seqId, int32(ALP_ILLUMINATE_TIME), p);
illUs = double(p.Value);
fprintf('Timing        : picture %g us, illuminate %g us per frame\n', picUs, illUs);
fprintf('Blink         : %.4g Hz (%.4g s period), 50%% duty\n', ...
    1e6 / (2 * picUs), 2e-6 * picUs);

% --- Project continuously -------------------------------------------------
% AlpProjStartCont loops the 2-frame sequence indefinitely
% (ALP_FLAG_SEQUENCE_INDEFINITE, alp.h:457) until AlpProjHalt. Nothing in
% MATLAB is in the timing loop, so a busy DAQ PC cannot make the blink stutter.
ret = calllib(LIB, 'AlpProjStartCont', devId, seqId);
checkRet(ret, ALP_OK, 'AlpProjStartCont');

if isempty(holdSec)
    fprintf('\nBlinking. Press any key (or Ctrl-C) to halt...\n');
    pause;
else
    fprintf('\nBlinking for %g s...\n', holdSec);
    pause(holdSec);
end

calllib(LIB, 'AlpProjHalt', devId);
fprintf('Projection halted.\n');

% Clearing these is load-bearing: doCleanup still holds `st` and would
% otherwise double-free on the way out.
calllib(LIB, 'AlpSeqFree', devId, seqId);   st('seqId') = [];
calllib(LIB, 'AlpDevFree', devId);          st('devId') = [];   %#ok<NASGU>
fprintf('Resources freed.\n=== blink complete ===\n');

end

% ==========================================================================
function [img, label, fillPct] = buildPattern(mode, W, H, patchDiam)
%buildPattern Logical H x W mirror map for the bright half. true = mirror ON.
%   Patterns stay inside the illuminated patch: mirrors outside it are dark
%   anyway, so lighting them adds stray light and no signal.

cx  = (W + 1) / 2;
cy  = (H + 1) / 2;
r   = patchDiam / 2;
[X, Y] = meshgrid(1:W, 1:H);

switch lower(mode)
    case 'disc'
        img = (X - cx).^2 + (Y - cy).^2 <= r^2;
        label = sprintf('filled disc, O%d px = %.1f mm patch', patchDiam, patchDiam*10.8e-3);

    case 'checker'
        checker = mod(floor((X - 1) / 64) + floor((Y - 1) / 64), 2) == 0;
        img = checker & ((X - cx).^2 + (Y - cy).^2 <= r^2);
        label = sprintf('checkerboard, 64 px squares, inside O%d px patch', patchDiam);

    case 'on'
        img = true(H, W);
        label = 'all mirrors ON (full field)';

    otherwise
        error('alpBlink43:badMode', ...
            'mode must be ''disc'', ''checker'' or ''on''; got ''%s''.', mode);
end

fillPct = 100 * nnz(img) / numel(img);
end

% --------------------------------------------------------------------------
function checkRet(ret, ALP_OK, fnName)
if ret ~= ALP_OK
    error('alpBlink43:alpError', '%s returned %d (see alp.h lines 54-69).', fnName, ret);
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
