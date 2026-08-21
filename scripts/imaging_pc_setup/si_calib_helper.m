function si_calib_helper(options)
%si_calib_helper Serve calibration requests on the imaging PC (port 3048).
%
%   si_calib_helper()
%   si_calib_helper(struct('port', 3048))
%
%   Runs INSIDE the ScanImage MATLAB on the imaging PC, where hSI lives —
%   the same constraint as si_motor_helper (port 3047), and for the same
%   reason: hSI is a base-workspace object in that process and nothing
%   outside it can reach it. This helper is the calibration counterpart,
%   and it exists so the guided bringup does not have to say "now walk to
%   the other PC and set the pixel count by hand" three times per session.
%
%   WHAT IT DOES NOT DO. It never modifies ScanImage internals — it sets
%   documented properties and calls documented methods on hSI, exactly as a
%   person clicking the GUI would. If a property name below turns out to be
%   wrong on this ScanImage version, fix it in the patch-point functions at
%   the bottom and nowhere else.
%
%   Wire format (bare numeric vectors only — msocket-safe, same discipline
%   as si_motor_helper):
%     [1 nFast nSlow]   set pixels/line and lines/frame  -> [0]
%     [2 0]             enter Focus                      -> [0]
%     [3 0]             abort (idle)                     -> [0]
%     [4 nPlanes]       per-plane mean brightness        -> [0 b1 b2 ... bN]
%     [5 nPlanes]       grab one volume, return pixels   -> [0 nRows nCols nFrames pixels...]
%     [6 x y w h]       command a centred mROI (um)      -> [0]
%     [7 0]             report configuration             -> [0 nFast nSlow nSlices zoom]
%     [99 0]            shutdown the helper              -> [0], loop exits
%   First reply element ~= 0 is an error code; detail prints on this console.
%
%   Opcode 5 sends a whole volume as a flat vector after three size
%   elements. That is deliberately dumb: msocket round-trips bare numeric
%   arrays reliably and structs only when flat, so the shape travels as
%   numbers and the client reshapes. Keep volumes small — this link is for
%   calibration, never for experiment data.
%
%   %VERIFY on this rig's ScanImage version before first use, the same way
%   si_motor_helper's motorPosition access was verified: every hSI property
%   touched here is listed in the patch-point functions below.

if nargin < 1
    options = struct();
end
port     = getOpt(options, 'port', 3048);
msockDir = getOpt(options, 'msocketPath', '');
if ~isempty(msockDir) && isfolder(msockDir)
    addpath(msockDir);
end

fprintf('[si_calib_helper] Listening on port %d. Ctrl-C to stop.\n', port);

while true
    srvsock = mslisten(port);
    sock    = msaccept(srvsock, inf);
    msclose(srvsock);
    fprintf('[si_calib_helper] Client connected.\n');

    clientAlive = true;
    while clientAlive
        req = msrecv(sock, 0.2);
        if isempty(req)
            continue
        end
        try
            if ~isnumeric(req) || numel(req) < 2
                mssend(sock, -2);   % bad request
                continue
            end
            switch req(1)
                case 1
                    setPixelCounts_(double(req(2)), double(req(3)));
                    mssend(sock, 0);
                case 2
                    startFocus_();
                    mssend(sock, 0);
                case 3
                    abortAll_();
                    mssend(sock, 0);
                case 4
                    b = planeBrightness_(double(req(2)));
                    mssend(sock, [0, b(:)']);
                case 5
                    vol = grabVolume_(double(req(2)));
                    mssend(sock, [0, size(vol, 1), size(vol, 2), size(vol, 3), ...
                                  double(vol(:))']);
                case 6
                    commandRoi_(double(req(2)), double(req(3)), ...
                                double(req(4)), double(req(5)));
                    mssend(sock, 0);
                case 7
                    mssend(sock, [0, reportConfig_()]);
                case 99
                    mssend(sock, 0);
                    fprintf('[si_calib_helper] Shutdown requested.\n');
                    try, msclose(sock); catch, end %#ok<TRYNC>
                    return
                otherwise
                    mssend(sock, -3);   % unknown opcode
            end
        catch ME
            fprintf(2, '[si_calib_helper] %s: %s\n', ME.identifier, ME.message);
            try, mssend(sock, -1); catch, end %#ok<TRYNC>
            clientAlive = false;   % drop the client; back to accept
        end
    end

    try, msclose(sock); catch, end %#ok<TRYNC>
    fprintf('[si_calib_helper] Client disconnected; back to accept.\n');
end
end

% --- hSI patch points (the ONLY places that touch ScanImage) -------------
%
% Every one of these is a %VERIFY item on first use. They are separated out
% so a ScanImage version difference is a one-line edit here rather than a
% hunt through the protocol above.

function setPixelCounts_(nFast, nSlow)
% %VERIFY hSI.hRoiManager.pixelsPerLine / linesPerFrame.
% A NON-SQUARE count is what makes the fast (resonant) axis identifiable in
% the substage camera's view of the raster — see BRINGUP_GUIDE section 4b.
assignin('base', 'tfp_px__', [nFast nSlow]);
evalin('base', 'hSI.hRoiManager.pixelsPerLine = tfp_px__(1);');
evalin('base', 'hSI.hRoiManager.linesPerFrame = tfp_px__(2);');
evalin('base', 'clear tfp_px__');
end

function startFocus_()
% %VERIFY hSI.startFocus() on this version.
evalin('base', 'hSI.startFocus();');
end

function abortAll_()
% %VERIFY hSI.abort() on this version.
evalin('base', 'hSI.abort();');
end

function b = planeBrightness_(nPlanes)
%planeBrightness_ Mean of the most recent frame of each imaging plane.
%
% %VERIFY hSI.hDisplay.lastAveragedFrame — the per-channel frame buffer.
% On a multi-plane (fastZ) acquisition the display holds one entry per
% slice; the mean of each is what calibrateEtlPlanes wants, because a plane
% is brightest when the film sits at its focal depth.
frames = evalin('base', 'hSI.hDisplay.lastAveragedFrame');
b = zeros(1, nPlanes);
for k = 1:nPlanes
    b(k) = planeMean_(frames, k);
end
end

function m = planeMean_(frames, k)
if iscell(frames)
    if k <= numel(frames)
        f = frames{k};
        if iscell(f) && ~isempty(f), f = f{1}; end
        m = mean(double(f(:)));
    else
        m = NaN;
    end
elseif isnumeric(frames) && ndims(frames) >= 3 && k <= size(frames, 3)
    f = frames(:, :, k);
    m = mean(double(f(:)));
else
    m = NaN;
end
end

function vol = grabVolume_(nPlanes)
%grabVolume_ One plane-interleaved volume as a numeric array.
%
% %VERIFY the acquisition route. This uses the display buffer rather than
% writing and re-reading a TIFF, because the DAQ PC only needs pixels and a
% file round trip adds a share, a path and a race.
frames = evalin('base', 'hSI.hDisplay.lastAveragedFrame');
first  = firstFrame_(frames);
vol    = zeros(size(first, 1), size(first, 2), nPlanes, 'like', double(first));
for k = 1:nPlanes
    vol(:, :, k) = double(nthFrame_(frames, k));
end
end

function f = firstFrame_(frames)
f = nthFrame_(frames, 1);
end

function f = nthFrame_(frames, k)
if iscell(frames)
    f = frames{min(k, numel(frames))};
    if iscell(f) && ~isempty(f), f = f{1}; end
elseif isnumeric(frames) && ndims(frames) >= 3
    f = frames(:, :, min(k, size(frames, 3)));
else
    f = frames;
end
end

function commandRoi_(xUm, yUm, wUm, hUm)
%commandRoi_ Centre a small scan region at a commanded sample position.
%
% %VERIFY the mROI surface on this version. This is the section 4c verify
% step: the DAQ PC predicts where a DMD spot should appear and asks for a
% region there, and the operator says whether the spot is centred in it.
assignin('base', 'tfp_roi__', [xUm yUm wUm hUm]);
evalin('base', ['hSI.hRoiManager.mroiEnable = true; ' ...
                'hSI.hStackManager.numSlices = hSI.hStackManager.numSlices;']);
evalin('base', 'hSI.hRoiManager.setRoiCenterAndSize(tfp_roi__(1:2), tfp_roi__(3:4));');
evalin('base', 'clear tfp_roi__');
end

function v = reportConfig_()
% %VERIFY property names as above.
nFast   = evalin('base', 'hSI.hRoiManager.pixelsPerLine');
nSlow   = evalin('base', 'hSI.hRoiManager.linesPerFrame');
nSlices = evalin('base', 'hSI.hStackManager.numSlices');
zoom    = evalin('base', 'hSI.hRoiManager.scanZoomFactor');
v = double([nFast nSlow nSlices zoom]);
end

function v = getOpt(s, name, default)
if isfield(s, name), v = s.(name); else, v = default; end
end
