function si_frame_callback(src, ~) %#ok<INUSL>
% si_frame_callback  ScanImage frameAcquired callback — runs on IMAGING PC.
%
% Sends ROI integration values to the scope PC after each frame.
% Never raises an error — drops the frame silently if anything fails,
% because an uncaught callback error can crash ScanImage.
%
% Prerequisites:
%   - ROI Integration must be enabled in ScanImage
%   - Integration ROIs must be defined around target cells
%   - SIStreamSetup.m must have been run this session (sets SIStreamSocket)
%   - msocket library must be on the MATLAB path
%
% The packet sent to scope PC is a struct:
%   packet.frame          — ScanImage absolute frame number (frameNumberAcqMode)
%   packet.F              — nROIs × 1 double, ROI integration values
%   packet.frameTimestamp — ScanImage frame timestamp (s), for alignment
%   packet.t              — datenum wall-clock at callback time
%
% NOTE — frame indexing: packet.frame is ScanImage's *absolute* acquisition
% frame number (e.g. 20214), not a per-trial 1..nFrames index. The scope-side
% accumulator (ScanImageBridge.receiveLiveFrame) anchors on the first frame of
% each trial and converts to a 1-based column index.
%
% NOTE — single-plane only: frameAcquired fires once per FRAME/slice (SI2018b
% SI.m ~L1178). On a single-plane scan frame == volume, so each callback yields
% one fresh integration value. On a multi-plane stack the callback fires N times
% per volume while integration values finalize per volume → duplicate sends and
% non-contiguous frame indices. Add dedupe-by-frame + volume indexing on both
% ends before streaming multi-plane.

global SIStreamSocket %#ok<GVMIS>

if isempty(SIStreamSocket)
    return;
end

try
    % Current per-ROI integration values via ScanImage's public user method.
    % getIntegrationValues handles the internal circular-buffer cursor and
    % returns, for each integration ROI, the newest value plus its frame
    % number and timestamp. This is the supported API — do NOT read the
    % hidden integrationValueHistory buffer directly (its rows are in
    % cursor order, not time order, so v(1,:)/v(end,:) are arbitrary-age).
    %
    % CONFIRMED against SI2018b on the rig (2026-05-29):
    %   F  : 1 x nROIs current integration values
    %   ts : 1 x nROIs frame timestamps (s) — identical across ROIs (one frame)
    %   fn : 1 x nROIs frame numbers       — identical across ROIs (one frame)
    % Earlier guesses (rois(k).scanfields(1).integrationValue and
    % hSI.hScan2D.frameCounter) do not exist / were unverified on this rig.
    [~, F, ts, fn] = src.hSI.hIntegrationRoiManager.getIntegrationValues();
    if isempty(F)
        return;  % integration not active this frame — drop silently
    end

    packet.frame          = fn(1);   % ScanImage absolute frame number (frameNumberAcqMode)
    packet.F              = F(:);    % nROIs x 1 column vector
    packet.frameTimestamp = ts(1);   % ScanImage frame timestamp (s), for alignment
    packet.t              = now;     % datenum wall-clock at callback time

    mssend(SIStreamSocket, packet);

catch
    % CRITICAL: never let the callback propagate an error to ScanImage.
    % Silently drop this frame if the socket is closed or any lookup fails.
end
end
