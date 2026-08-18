%DMDSTICKMAN  Run a looping stick-figure animation on the DLP650LNIR.
%
% A demo, not an instrument routine: a 16-frame run cycle uploaded as an ALP
% sequence and looped continuously with AlpProjStartCont. Fill is ~1-3%, far
% under the 50% cap of docs/optics_handoff.md §7, so it is safe on either
% laser and needs no override.
%
% Usage:
%   dmdStickman('preview')            % write GIF + montage PNG, no hardware
%   dmdStickman                       % project, loop until stopped
%   dmdStickman('project', 24)        % 24 fps
%   dmdStickman('project', 12, 600)   % 600 px tall figure
%
%   dmdStickman(mode, fps, figHeightPx, lineThick, tiltDeg)
%
% Stop with a STOP_PROJECTION file next to this script, or Ctrl-C.
%
% TILT. The chip is clocked 45 deg in the ViALUX mount, so anything drawn
% upright in DMD pixel coordinates arrives on the bench rotated 45 deg. The
% scene is pre-rotated by -tiltDeg to cancel it.
%
% tiltDeg = -45 is MEASURED, not assumed (bench, 2026-08-07): drawn upright
% the figure ran up a 45 deg slope; at tiltDeg = +45 it ran straight up a
% wall (90 deg, i.e. the correction added instead of cancelling); at -45 it
% is level. That fixes the mount's handedness, which the optical handoff
% explicitly leaves unspecified.
%
% tiltDeg = 0 draws in raw chip coordinates. Add 180 to compensate for the
% relay's image inversion if you want him upright downstream rather than at
% the chip.
%
% The preview renders CHIP coordinates, so a correct projection previews
% tilted. Tilted preview, level on the bench -- that is right, not a bug.
%
% SIZING. Default figure height is 320 px so the whole animation lands inside
% the illuminated patch (Ø463 px on the merged arm, docs/optics_handoff.md),
% which is what you want when viewing downstream of the relay. Viewing the chip
% directly, the Gaussian covers the full 800 px height, so pass figHeightPx up
% to ~700 for a much bigger figure.
%
% BRIGHTNESS. A stick figure is thin, so it is dim. lineThick is the lever:
% light scales roughly linearly with it. Default 9 px.

function dmdStickman(mode, fps, figHeightPx, lineThick, tiltDeg)

if nargin < 1 || isempty(mode),        mode        = 'project'; end
if nargin < 2 || isempty(fps),         fps         = 12;  end
if nargin < 3 || isempty(figHeightPx), figHeightPx = 320; end
if nargin < 4 || isempty(lineThick),   lineThick   = 9;   end
if nargin < 5 || isempty(tiltDeg),     tiltDeg     = -45; end

N_FRAMES = 16;
W = 1280; H = 800;              % replaced by the board's own report when projecting

switch lower(mode)
    case 'preview'
        frames = buildRunCycle(W, H, N_FRAMES, figHeightPx, lineThick, tiltDeg);
        reportFill(frames);
        here = fileparts(mfilename('fullpath'));
        gif  = fullfile(here, 'dmdStickman_preview.gif');
        for k = 1:N_FRAMES
            im = uint8(frames(:,:,k)) * 255;
            if k == 1
                imwrite(im, gif, 'gif', 'LoopCount', Inf, 'DelayTime', 1/fps);
            else
                imwrite(im, gif, 'gif', 'WriteMode', 'append', 'DelayTime', 1/fps);
            end
        end
        fprintf('GIF written: %s\n', gif);

        % Montage: 4x4 contact sheet, downsampled 4x so it is viewable.
        sheet = false(4 * H/4, 4 * W/4);
        for k = 1:N_FRAMES
            r = floor((k-1)/4); c = mod(k-1, 4);
            sheet(r*H/4 + (1:H/4), c*W/4 + (1:W/4)) = frames(1:4:end, 1:4:end, k);
        end
        png = fullfile(here, 'dmdStickman_montage.png');
        imwrite(uint8(sheet) * 255, png);
        fprintf('Montage written: %s\n', png);
        return

    case 'project'
        % fall through

    otherwise
        error('tfp:scripts:dmdStickman:badMode', ...
            'mode must be ''preview'' or ''project''; got ''%s''.', mode);
end

% ---------------------------------------------------------------- project --
HERE       = fileparts(mfilename('fullpath'));
STOP_FILE  = fullfile(HERE, 'STOP_PROJECTION');
MAX_HOLD_S = 2 * 3600;

[DLL, HDR, LIB] = alpPaths('4.3');

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

st = containers.Map({'devId','seqId'}, {[], []});
cleanupObj = onCleanup(@() doCleanup(LIB, st));

if ~libisloaded(LIB), loadlibrary(DLL, HDR, 'alias', LIB); end

devPtr = libpointer('uint32Ptr', uint32(0));
ret = calllib(LIB, 'AlpDevAlloc', int32(0), int32(ALP_DEFAULT), devPtr);
if ret ~= ALP_OK
    error('tfp:scripts:dmdStickman:devAlloc', ...
        ['AlpDevAlloc returned %d. 1001 = board not found OR already held by ' ...
         'another\nMATLAB session (ViALUX reports a busy device as NOT_ONLINE).'], ret);
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
    error('tfp:scripts:dmdStickman:projControl', 'AlpProjControl returned %d', ret);
end

frames  = buildRunCycle(W, H, N_FRAMES, figHeightPx, lineThick, tiltDeg);
maxFill = reportFill(frames);
if maxFill > 100 * MAX_ON_FRACTION
    error('tfp:scripts:dmdStickman:onFractionTooHigh', ...
        'Frame lights %.1f%% of the chip; cap is %.0f%%.', maxFill, 100*MAX_ON_FRACTION);
end

% Flatten to one buffer: N_FRAMES consecutive row-major W*H byte images.
% Preallocated -- growing this in a loop copies ~16 MB per iteration.
nPx    = W * H;
allData = zeros(1, nPx * N_FRAMES, 'uint8');
for k = 1:N_FRAMES
    allData((k-1)*nPx + (1:nPx)) = reshape(uint8(frames(:,:,k)') * uint8(255), 1, []);
end

seqPtr = libpointer('uint32Ptr', uint32(0));
ret = calllib(LIB, 'AlpSeqAlloc', devId, int32(1), int32(N_FRAMES), seqPtr);
if ret ~= ALP_OK
    error('tfp:scripts:dmdStickman:seqAlloc', 'AlpSeqAlloc returned %d', ret);
end
% doCleanup reads seqId from `st`; Code Analyzer cannot see the handle held by
% the cleanup closure, so it flags this as unused.
seqId = seqPtr.Value; st('seqId') = seqId;   %#ok<NASGU>

dataPtr = libpointer('uint8Ptr', allData);
ret = calllib(LIB, 'AlpSeqPut', devId, seqId, int32(0), int32(N_FRAMES), dataPtr);
if ret ~= ALP_OK
    error('tfp:scripts:dmdStickman:seqPut', 'AlpSeqPut returned %d', ret);
end
fprintf('Uploaded %d frames (%.1f MB)\n', N_FRAMES, numel(allData)/2^20);

pictureUs    = round(1e6 / fps);
illuminateUs = round(pictureUs * 0.9);   % 10% dark, as in alpSequenceTest
ret = calllib(LIB, 'AlpSeqTiming', devId, seqId, ...
    int32(illuminateUs), int32(pictureUs), int32(0), int32(0), int32(0));
if ret ~= ALP_OK
    error('tfp:scripts:dmdStickman:seqTiming', 'AlpSeqTiming returned %d', ret);
end
fprintf('Timing: %g fps (%.1f ms/frame), cycle %.2f s\n', ...
    fps, pictureUs/1e3, N_FRAMES/fps);

ret = calllib(LIB, 'AlpProjStartCont', devId, seqId);
if ret ~= ALP_OK
    error('tfp:scripts:dmdStickman:projStart', 'AlpProjStartCont returned %d', ret);
end

fprintf('\n*** RUNNING ***\n');
fprintf('stop with: %s\n', STOP_FILE);
fprintf('auto-stop after %g h\n\n', MAX_HOLD_S/3600);

t0 = tic;
while ~isfile(STOP_FILE) && toc(t0) < MAX_HOLD_S
    pause(0.25);
end
if isfile(STOP_FILE)
    fprintf('stopped after %.1f s\n', toc(t0));
    delete(STOP_FILE);
else
    fprintf('max hold reached (%.1f s)\n', toc(t0));
end
end

% ==========================================================================
function frames = buildRunCycle(W, H, nFrames, figH, thick, tiltDeg)
%buildRunCycle Logical H x W x nFrames run cycle, figure centred on the chip.
%
% Side view, running right, in place, with a ground line whose tick marks
% scroll left so the motion reads as running rather than jogging on the spot.
%
% The whole scene is PRE-ROTATED by -tiltDeg about the chip centre to cancel
% the 45 deg clocking of the chip in the ViALUX mount. Drawn upright in chip
% coordinates the figure arrives on the bench running up a 45 deg slope, for
% the same reason the alignment target's chip-frame diagonals arrive vertical
% and horizontal. Pass tiltDeg = 0 to draw in raw chip coordinates, or flip
% the sign if the rotation goes the wrong way -- the mount's handedness is not
% specified anywhere and is a bench fact.

frames = false(H, W, nFrames);

% Rotation about the chip centre, applied to every point before rasterising.
th  = -tiltDeg * pi / 180;
ccx = (W + 1) / 2;
ccy = (H + 1) / 2;
rot = @(p) [ccx + (p(1)-ccx)*cos(th) - (p(2)-ccy)*sin(th), ...
            ccy + (p(1)-ccx)*sin(th) + (p(2)-ccy)*cos(th)];

% Proportions as fractions of figure height (sum ~= 1.0 standing)
rHead  = 0.090 * figH;
neck   = 0.040 * figH;
torso  = 0.280 * figH;
upLeg  = 0.240 * figH;
loLeg  = 0.240 * figH;
upArm  = 0.190 * figH;
loArm  = 0.170 * figH;

cx = (W + 1) / 2;
groundY = (H + 1)/2 + 0.52 * figH;      % feet sit near here
bob     = 0.035 * figH;
lean    = 0.06  * figH;                 % shoulders forward of hips

tickSpacing = round(0.42 * figH);
groundHalf  = round(0.95 * figH);

d2r = @(deg) deg * pi / 180;

for k = 1:nFrames
    ph  = 2*pi * (k-1) / nFrames;
    img = false(H, W);

    % --- ground line + scrolling ticks -----------------------------------
    gy = groundY + 0.09*figH;                 % just under the feet
    img = drawSeg(img, rot([cx-groundHalf, gy]), rot([cx+groundHalf, gy]), max(3, thick*0.6));
    shift = mod((k-1)/nFrames * tickSpacing, tickSpacing);
    for xt = (cx - groundHalf + shift) : tickSpacing : (cx + groundHalf)
        img = drawSeg(img, rot([xt, gy+4]), ...
                           rot([xt - 0.10*figH, gy + 0.10*figH]), max(3, thick*0.5));
    end

    % --- body ------------------------------------------------------------
    hipY = groundY - (upLeg + loLeg) * 0.92 - bob*abs(cos(ph));
    hip  = [cx, hipY];
    sho  = [cx + lean, hipY - torso];
    headC = [sho(1) + 0.30*neck, sho(2) - neck - rHead];

    img = drawSeg(img, rot(hip), rot(sho), thick);           % spine
    img = drawDisc(img, rot(headC), rHead);                  % head

    % --- legs (phase-opposed) --------------------------------------------
    % Thigh swings on sin; the knee MUST key off cos, not sin. With both on
    % sin the two legs take identical poses wherever sin(legPh)=0 -- they
    % overlap exactly at the passing position and the figure loses a leg.
    % cos also matches the real gait: knee bent through mid-swing (legPh=0,
    % heel up), straight at mid-stance (legPh=pi) carrying the weight.
    for legPh = [ph, ph + pi]
        th1 = d2r(42) * sin(legPh);                          % thigh from vertical
        th2 = d2r(8) + d2r(68) * (0.5 + 0.5*cos(legPh));     % knee flexion
        knee  = hip  + upLeg * [sin(th1), cos(th1)];
        ankle = knee + loLeg * [sin(th1 - th2), cos(th1 - th2)];
        img = drawSeg(img, rot(hip),  rot(knee),  thick);
        img = drawSeg(img, rot(knee), rot(ankle), thick);
        foot = ankle + 0.10*figH * [cos(th1 - th2), -sin(th1 - th2)];
        img = drawSeg(img, rot(ankle), rot(foot), max(3, thick*0.8));
    end

    % --- arms (opposite to same-side leg) --------------------------------
    for armPh = [ph + pi, ph]
        a1 = -d2r(34) * sin(armPh);
        a2 =  d2r(62) + d2r(24) * cos(armPh);   % cos, for the same reason as the knee
        elb  = sho + upArm * [sin(a1), cos(a1)];
        hand = elb + loArm * [sin(a1 + a2), cos(a1 + a2)];
        img = drawSeg(img, rot(sho), rot(elb),  thick);
        img = drawSeg(img, rot(elb), rot(hand), thick);
    end

    frames(:,:,k) = img;
end
end

% --------------------------------------------------------------------------
function img = drawSeg(img, p1, p2, t)
%drawSeg Thick line segment, rasterised only inside its bounding box.
[H, W] = size(img);
pad = ceil(t/2) + 2;
x0 = max(1, floor(min(p1(1), p2(1)) - pad));  x1 = min(W, ceil(max(p1(1), p2(1)) + pad));
y0 = max(1, floor(min(p1(2), p2(2)) - pad));  y1 = min(H, ceil(max(p1(2), p2(2)) + pad));
if x1 < x0 || y1 < y0, return; end

[X, Y] = meshgrid(x0:x1, y0:y1);
d  = p2 - p1;
L2 = d(1)^2 + d(2)^2;
if L2 == 0
    dist = hypot(X - p1(1), Y - p1(2));
else
    u = ((X - p1(1))*d(1) + (Y - p1(2))*d(2)) / L2;
    u = max(0, min(1, u));
    dist = hypot(X - (p1(1) + u*d(1)), Y - (p1(2) + u*d(2)));
end
img(y0:y1, x0:x1) = img(y0:y1, x0:x1) | (dist <= t/2);
end

% --------------------------------------------------------------------------
function img = drawDisc(img, c, r)
[H, W] = size(img);
x0 = max(1, floor(c(1)-r-2)); x1 = min(W, ceil(c(1)+r+2));
y0 = max(1, floor(c(2)-r-2)); y1 = min(H, ceil(c(2)+r+2));
if x1 < x0 || y1 < y0, return; end
[X, Y] = meshgrid(x0:x1, y0:y1);
img(y0:y1, x0:x1) = img(y0:y1, x0:x1) | (hypot(X-c(1), Y-c(2)) <= r);
end

% --------------------------------------------------------------------------
function maxFill = reportFill(frames)
n = size(frames, 3);
f = zeros(1, n);
for k = 1:n
    f(k) = 100 * nnz(frames(:,:,k)) / numel(frames(:,:,k));
end
maxFill = max(f);
fprintf('%d frames, fill %.2f%%-%.2f%% of chip (cap 50%%)\n', n, min(f), maxFill);
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
