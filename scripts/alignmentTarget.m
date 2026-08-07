%ALIGNMENTTARGET  Ring/diagonal/fiducial alignment target for the DLP650LNIR.
%
% A measuring instrument rather than a "is it alive" pattern. Three elements,
% each answering a question that all-ON cannot:
%
%   CONCENTRIC RINGS every RING_STEP px from chip centre.
%       The Gaussian illumination falls off with radius, so the last ring still
%       visibly lit gives the footprint radius as a NUMBER, not an eyeballed
%       blob edge. Every 5th ring is drawn double-thick as a counting aid.
%       This is the measurement that should replace the stale Ø3.5 mm / 324 px
%       figure in docs/dmd_control_handoff.md.
%
%   DIAGONALS along (1,1) and (1,-1).
%       The chip is mounted clocked 45°, so the optical axes -- dispersion and
%       groove -- run along the chip DIAGONALS, not its rows and columns
%       (handoff §1). These lines are those axes. Everything optical should be
%       symmetric about them; if it is not, the clocking is off.
%
%   ASYMMETRIC FIDUCIAL: a filled square on ONE diagonal arm, plus a short bar
%       on one adjacent arm.
%       Breaks both the 4-fold rotational symmetry and the mirror symmetry, so
%       a flip is distinguishable from a rotation. The handoff is explicit that
%       sign conventions are NOT specified and must be fixed on the bench --
%       this is the feature that lets you fix them.
%
% Fill is ~7% of the chip, well under the 50% cap of handoff §7, so this needs
% no override and is safe on either laser.
%
% Usage:
%   alignmentTarget('preview')          % build + save a PNG, no hardware
%   alignmentTarget                     % project and hold until stopped
%   alignmentTarget('project', 30)      % project for 30 s then halt
%   alignmentTarget('project', [], 10)  % 10 px lines -- brighter still
%
% Third argument is line thickness in px (default 6). Raise it when the laser
% is dim -- e.g. a Chameleon in alignment mode. Light scales roughly linearly
% with it until rings start merging, which happens near half the 40 px ring
% spacing, so ~16 px is the practical ceiling before the pattern stops being
% readable as discrete rings.
%
% Stop a held field with a STOP_PROJECTION file next to this script, or Ctrl-C.

function alignmentTarget(mode, holdSec, ringThick)

if nargin < 1 || isempty(mode),    mode = 'project'; end
if nargin < 2, holdSec = []; end
if nargin < 3 || isempty(ringThick), ringThick = 6; end

W = 1280; H = 800;          % overwritten by the board when projecting
RING_STEP  = 40;            % px between rings  (40 px = 432 µm on chip)
RING_THICK = ringThick;     % default 6 px: doubled from the original 3 px so
                            % there is enough light to align against a
                            % Chameleon in alignment mode. Every 5th ring is
                            % drawn at 2x this, so 12 px.
LINE_THICK = ringThick;     % diagonals track the rings -- at 3 px against 6 px
                            % rings the optical axes wash out, and they are the
                            % feature you actually align to.
FID_SIZE   = 34;            % filled square, px
FID_RADIUS = 200;           % how far out the fiducial sits, px

switch lower(mode)
    case 'preview'
        img = buildTarget(W, H, RING_STEP, RING_THICK, LINE_THICK, FID_SIZE, FID_RADIUS);
        reportTarget(img, RING_STEP);
        out = fullfile(fileparts(mfilename('fullpath')), 'alignmentTarget_preview.png');
        imwrite(uint8(img) * 255, out);
        fprintf('preview written: %s\n', out);
        return
    case 'project'
        % fall through
    otherwise
        error('tfp:scripts:alignmentTarget:badMode', ...
            'mode must be ''preview'' or ''project''; got ''%s''.', mode);
end

% ---------------------------------------------------------------- project --
HERE       = fileparts(mfilename('fullpath'));
STOP_FILE  = fullfile(HERE, 'STOP_PROJECTION');
MAX_HOLD_S = 4 * 3600;

DLL = 'C:\Program Files\ALP-4.3\ALP-4.3 API\x64\alp4395.dll';
HDR = 'C:\Program Files\ALP-4.3\ALP-4.3 API\alp.h';
LIB = 'alp4395';

% Constants verbatim from vendor/alp/official/alp.h (Version 28)
ALP_OK = 0; ALP_DEFAULT = 0;
ALP_DEV_DMDTYPE        = 2021;   % alp.h:141
ALP_DMDTYPE_WXGA_S450  = 12;     % alp.h:153
ALP_DEV_DISPLAY_HEIGHT = 2057;   % alp.h:157
ALP_DEV_DISPLAY_WIDTH  = 2058;   % alp.h:158
ALP_PROJ_MODE          = 2300;   % alp.h:321
ALP_MASTER             = 2301;   % alp.h:322
MAX_ON_FRACTION        = 0.50;   % handoff §7

if isfile(STOP_FILE), delete(STOP_FILE); end

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
    error('tfp:scripts:alignmentTarget:devAlloc', ...
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
    error('tfp:scripts:alignmentTarget:projControl', 'AlpProjControl returned %d', ret);
end

img = buildTarget(W, H, RING_STEP, RING_THICK, LINE_THICK, FID_SIZE, FID_RADIUS);
fillPct = reportTarget(img, RING_STEP);

if fillPct > 100 * MAX_ON_FRACTION
    error('tfp:scripts:alignmentTarget:onFractionTooHigh', ...
        'Target lights %.1f%% of the chip; cap is %.0f%% (handoff §7).', ...
        fillPct, 100 * MAX_ON_FRACTION);
end

% Row-major, one byte per pixel, 0xFF = ON (ALP_DATA_MSB_ALIGN default).
patternData = reshape(uint8(img') * uint8(255), 1, []);

seqPtr = libpointer('uint32Ptr', uint32(0));
ret = calllib(LIB, 'AlpSeqAlloc', devId, int32(1), int32(1), seqPtr);
if ret ~= ALP_OK
    error('tfp:scripts:alignmentTarget:seqAlloc', 'AlpSeqAlloc returned %d', ret);
end
% Recording seqId in `st` is load-bearing -- doCleanup reads it to free the
% sequence. Code Analyzer flags it as unused because it cannot see the handle
% captured by the cleanup closure.
seqId = seqPtr.Value; st('seqId') = seqId;   %#ok<NASGU>

dataPtr = libpointer('uint8Ptr', patternData);
ret = calllib(LIB, 'AlpSeqPut', devId, seqId, int32(0), int32(1), dataPtr);
if ret ~= ALP_OK
    error('tfp:scripts:alignmentTarget:seqPut', 'AlpSeqPut returned %d', ret);
end

ret = calllib(LIB, 'AlpProjStartCont', devId, seqId);
if ret ~= ALP_OK
    error('tfp:scripts:alignmentTarget:projStart', 'AlpProjStartCont returned %d', ret);
end

fprintf('\n*** ALIGNMENT TARGET ON AND HELD ***\n');
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
end

% ==========================================================================
function img = buildTarget(W, H, step, ringThick, lineThick, fidSize, fidRadius)
%buildTarget Logical H x W mirror map. true = mirror ON.

img = false(H, W);
cx  = (W + 1) / 2;
cy  = (H + 1) / 2;
[X, Y] = meshgrid(1:W, 1:H);
dx = X - cx;
dy = Y - cy;
R  = hypot(dx, dy);

% --- concentric rings, every 5th double-thick for counting ----------------
maxR = min(cx, cy);                       % largest fully on-chip radius
for k = 1:floor(maxR / step)
    r = k * step;
    t = ringThick;
    if mod(k, 5) == 0, t = ringThick * 2; end
    img = img | (abs(R - r) <= t/2);
end

% --- diagonals: the real optical axes under 45° clocking ------------------
% Distance from a point to the line y = x  is |dx-dy|/sqrt(2); to y = -x is
% |dx+dy|/sqrt(2). These are the groove and dispersion axes respectively.
img = img | (abs(dx - dy) / sqrt(2) <= lineThick/2);
img = img | (abs(dx + dy) / sqrt(2) <= lineThick/2);

% --- asymmetric fiducial -------------------------------------------------
% Filled square on the +(1,1) arm, and a short bar on the +(1,-1) arm. Two
% different shapes on two different arms kills both rotational and mirror
% ambiguity: a 90° rotation moves the square to where the bar is, and a flip
% swaps which arm each sits on.
fx = cx + fidRadius / sqrt(2);
fy = cy + fidRadius / sqrt(2);
img = img | (abs(X - fx) <= fidSize/2 & abs(Y - fy) <= fidSize/2);

bx = cx + fidRadius / sqrt(2);
by = cy - fidRadius / sqrt(2);
img = img | (abs(X - bx) <= fidSize & abs(Y - by) <= fidSize/6);

% Never light a mirror outside the array (defensive; meshgrid already bounds).
img(:, [1 end]) = img(:, [1 end]);
end

% --------------------------------------------------------------------------
function fillPct = reportTarget(img, step)
%reportTarget Print what the target encodes, so ring counting is unambiguous.
[H, W] = size(img);
fillPct = 100 * nnz(img) / numel(img);
maxR = min((W+1)/2, (H+1)/2);
nRings = floor(maxR / step);
fprintf('Target: %d rings at %d px spacing (outermost %d px radius)\n', ...
    nRings, step, nRings * step);
fprintf('        every 5th ring double-thick; ring 5 = %d px, ring 10 = %d px\n', ...
    5*step, 10*step);
fprintf('        at 10.8 um pitch: %d px = %.2f mm on chip\n', ...
    step, step * 10.8e-3);
fprintf('        fill %.2f%% of chip (cap 50%%)\n', fillPct);
end

% --------------------------------------------------------------------------
function doCleanup(lib, st)
%doCleanup Halt and release everything. Runs on error and Ctrl-C; never throws.
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
