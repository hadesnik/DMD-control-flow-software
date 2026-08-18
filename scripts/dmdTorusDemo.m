%DMDTORUSDEMO  Spinning shaded 3-D torus on the DLP650LNIR. Showpiece demo.
%
% A tumbling torus, Lambertian-shaded against a fixed light, hidden surfaces
% resolved by depth sort, and the continuous-tone shading converted to binary
% by 4x4 ordered (Bayer) dithering. Uploaded as one ALP sequence and looped
% on-board.
%
% Why this looks better than line art on a binary device: the DMD has only ON
% and OFF, but at 10.8 um pitch the eye (and the optics) average neighbouring
% mirrors, so a dither pattern reads as GREY. The torus therefore shows a
% genuine shaded highlight and terminator rather than an outline -- which also
% means it lights far more mirrors, so it is much brighter than the stick man.
%
% Usage:
%   dmdTorusDemo('preview')             % GIF + montage, no hardware
%   dmdTorusDemo                        % project, loop until stopped
%   dmdTorusDemo('project', 20)         % 20 fps
%   dmdTorusDemo('project', 20, 700)    % big -- see SIZING
%
%   dmdTorusDemo(mode, fps, sizePx, tiltDeg)
%
% Stop with a STOP_PROJECTION file next to this script, or Ctrl-C.
%
% SIZING drives both impressiveness and brightness, and the right value
% depends on where you are looking:
%   340 (default)  fits inside the illuminated patch -- correct downstream of
%                  the relay, where only the central Ø463 px is passed.
%   700            fills the chip's short axis. Use when viewing the DMD
%                  directly, where the Gaussian covers all 800 rows. Renders
%                  slower (sample count scales with size) and lights ~4x the
%                  mirrors.
%
% TILT. Pre-rotates by -tiltDeg to cancel the 45 deg chip clocking in the
% ViALUX mount. tiltDeg = -45 is the measured bench value (see CLAUDE.md,
% "Mount clocking handedness"). Barely visible on a centred torus, but it
% keeps the convention consistent with dmdStickman and alignmentTarget.

function dmdTorusDemo(mode, fps, sizePx, tiltDeg)

if nargin < 1 || isempty(mode),    mode    = 'project'; end
if nargin < 2 || isempty(fps),     fps     = 20;   end
if nargin < 3 || isempty(sizePx),  sizePx  = 340;  end
if nargin < 4 || isempty(tiltDeg), tiltDeg = -45;  end

N_FRAMES = 24;
W = 1280; H = 800;              % replaced by the board's own report when projecting

switch lower(mode)
    case 'preview'
        frames = buildTorusCycle(W, H, N_FRAMES, sizePx, tiltDeg);
        reportFill(frames);
        here = fileparts(mfilename('fullpath'));
        gif  = fullfile(here, 'dmdTorusDemo_preview.gif');
        for k = 1:N_FRAMES
            im = uint8(frames(:,:,k)) * 255;
            if k == 1
                imwrite(im, gif, 'gif', 'LoopCount', Inf, 'DelayTime', 1/fps);
            else
                imwrite(im, gif, 'gif', 'WriteMode', 'append', 'DelayTime', 1/fps);
            end
        end
        fprintf('GIF written: %s\n', gif);

        png = fullfile(here, 'dmdTorusDemo_frame.png');
        imwrite(uint8(frames(:,:,1)) * 255, png);
        fprintf('Frame 1 written: %s\n', png);
        return

    case 'project'
        % fall through

    otherwise
        error('tfp:scripts:dmdTorusDemo:badMode', ...
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
    error('tfp:scripts:dmdTorusDemo:devAlloc', ...
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
    error('tfp:scripts:dmdTorusDemo:projControl', 'AlpProjControl returned %d', ret);
end

frames  = buildTorusCycle(W, H, N_FRAMES, sizePx, tiltDeg);
maxFill = reportFill(frames);
if maxFill > 100 * MAX_ON_FRACTION
    error('tfp:scripts:dmdTorusDemo:onFractionTooHigh', ...
        ['Frame lights %.1f%% of the chip; cap is %.0f%% (handoff §7).\n' ...
         'Reduce sizePx.'], maxFill, 100*MAX_ON_FRACTION);
end

nPx     = W * H;
allData = zeros(1, nPx * N_FRAMES, 'uint8');
for k = 1:N_FRAMES
    allData((k-1)*nPx + (1:nPx)) = reshape(uint8(frames(:,:,k)') * uint8(255), 1, []);
end

seqPtr = libpointer('uint32Ptr', uint32(0));
ret = calllib(LIB, 'AlpSeqAlloc', devId, int32(1), int32(N_FRAMES), seqPtr);
if ret ~= ALP_OK
    error('tfp:scripts:dmdTorusDemo:seqAlloc', 'AlpSeqAlloc returned %d', ret);
end
% doCleanup reads seqId from `st`; Code Analyzer cannot see the handle held by
% the cleanup closure, so it flags this as unused.
seqId = seqPtr.Value; st('seqId') = seqId;   %#ok<NASGU>

dataPtr = libpointer('uint8Ptr', allData);
ret = calllib(LIB, 'AlpSeqPut', devId, seqId, int32(0), int32(N_FRAMES), dataPtr);
if ret ~= ALP_OK
    error('tfp:scripts:dmdTorusDemo:seqPut', 'AlpSeqPut returned %d', ret);
end
fprintf('Uploaded %d frames (%.1f MB)\n', N_FRAMES, numel(allData)/2^20);

pictureUs    = round(1e6 / fps);
illuminateUs = round(pictureUs * 0.9);
ret = calllib(LIB, 'AlpSeqTiming', devId, seqId, ...
    int32(illuminateUs), int32(pictureUs), int32(0), int32(0), int32(0));
if ret ~= ALP_OK
    error('tfp:scripts:dmdTorusDemo:seqTiming', 'AlpSeqTiming returned %d', ret);
end
fprintf('Timing: %g fps (%.1f ms/frame), cycle %.2f s\n', fps, pictureUs/1e3, N_FRAMES/fps);

ret = calllib(LIB, 'AlpProjStartCont', devId, seqId);
if ret ~= ALP_OK
    error('tfp:scripts:dmdTorusDemo:projStart', 'AlpProjStartCont returned %d', ret);
end

fprintf('\n*** SPINNING ***\n');
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
function frames = buildTorusCycle(W, H, nFrames, sizePx, tiltDeg)
%buildTorusCycle Logical H x W x nFrames of a tumbling shaded torus.

R = 1.00;                 % major radius
r = 0.42;                 % minor radius
scale = (sizePx/2) / (R + r);

% Sample density scales with on-screen size so the surface stays gap-free.
nT = max(600, round(2.2 * sizePx));    % around the major circle
nP = max(220, round(0.8 * sizePx));    % around the tube

[T, P] = meshgrid(linspace(0, 2*pi, nT), linspace(0, 2*pi, nP));
T = T(:).'; P = P(:).';

% Jitter the samples by up to half a step. A perfectly regular parametric grid
% beats against the pixel grid and lays faint concentric arcs across the
% shading -- an artifact of the sampling, not of the surface. Fixed seed so
% frames stay reproducible run to run.
rs = RandStream('mt19937ar', 'Seed', 7);
T = T + (rand(rs, size(T)) - 0.5) * (2*pi/nT);
P = P + (rand(rs, size(P)) - 0.5) * (2*pi/nP);

% Surface points and outward normals
ct = cos(T); stt = sin(T); cp = cos(P); sp = sin(P);
X0 = (R + r*cp) .* ct;
Y0 = (R + r*cp) .* stt;
Z0 = r * sp;
NX0 = cp .* ct;  NY0 = cp .* stt;  NZ0 = sp;

L = [-0.42, -0.66, 0.62];  L = L / norm(L);   % fixed world light

cx = (W + 1)/2;  cy = (H + 1)/2;
tilt = -tiltDeg * pi/180;
ctl = cos(tilt); stl = sin(tilt);

bayer = [ 0  8  2 10
         12  4 14  6
          3 11  1  9
         15  7 13  5] / 16;

frames = false(H, W, nFrames);

for k = 1:nFrames
    % Two tumble axes at 1 and 2 cycles per loop -- both integer, so the
    % animation closes seamlessly when AlpProjStartCont wraps the sequence.
    a = 2*pi*(k-1)/nFrames;
    b = 4*pi*(k-1)/nFrames;

    Rx = [1 0 0; 0 cos(a) -sin(a); 0 sin(a) cos(a)];
    Rz = [cos(b) -sin(b) 0; sin(b) cos(b) 0; 0 0 1];
    M  = Rx * Rz;

    V = M * [X0; Y0; Z0];
    N = M * [NX0; NY0; NZ0];

    % Orthographic projection, then the chip-clocking pre-rotation.
    px =  V(1,:) * scale;
    py = -V(2,:) * scale;
    sx = cx + px*ctl - py*stl;
    sy = cy + px*stl + py*ctl;
    depth = V(3,:);

    lum = 0.16 + 0.84 * max(0, L * N);      % ambient + Lambertian

    ix = round(sx); iy = round(sy);
    ok = ix >= 1 & ix <= W & iy >= 1 & iy <= H;

    % Painter's algorithm: sort far-to-near and let nearer samples overwrite.
    % Cheaper than a real z-buffer here and exact for a convex-in-depth sort,
    % because duplicate linear indices resolve to the last (nearest) write.
    ixo = ix(ok); iyo = iy(ok); lo = lum(ok); zo = depth(ok);
    [~, ord] = sort(zo, 'ascend');
    lin = (double(ixo(ord)) - 1) * H + double(iyo(ord));

    grey = zeros(H, W);
    grey(lin) = lo(ord);

    % 4x4 ordered dither -- coarse on purpose. A finer kernel would carry more
    % tone but is the first thing lost to blur downstream of the relay.
    thr = repmat(bayer, ceil(H/4), ceil(W/4));
    frames(:,:,k) = grey > thr(1:H, 1:W);
end
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
