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
%   packet.frame  — integer frame counter from ScanImage
%   packet.F      — nROIs × 1 double, ROI integration values
%   packet.t      — datenum timestamp at time of callback

global SIStreamSocket %#ok<GVMIS>

if isempty(SIStreamSocket)
    return;
end

try
    %VERIFY frameCounter property name with Masato.
    %  ASSUME: hSI.hScan2D.frameCounter increments by 1 each frameAcquired event.
    %  TEST:   Add disp(hSI.hScan2D.frameCounter) in the callback and watch it.
    %  CHANGE: Replace frameCounter with the correct property if it differs.
    frameNum = src.hSI.hScan2D.frameCounter;

    %VERIFY ROI integration output property path with Masato.
    %  ASSUME: hSI.hIntegrationRoiManager.roiGroup.rois is an array of roi objects,
    %          each with a scanfields(1).integrationValue scalar.
    %  TEST:   In ScanImage MATLAB console (with ROI Integration enabled):
    %            r = hSI.hIntegrationRoiManager.roiGroup.rois;
    %            disp(r(1).scanfields(1).integrationValue)
    %  CHANGE: Update the property path to match the actual ScanImage API.
    rois = src.hSI.hIntegrationRoiManager.roiGroup.rois;
    F = zeros(numel(rois), 1);
    for k = 1:numel(rois)
        F(k) = rois(k).scanfields(1).integrationValue;
    end

    packet.frame = frameNum;
    packet.F     = F;
    packet.t     = now;  % datenum; scope PC converts with datetime(...,'ConvertFrom','datenum')

    mssend(SIStreamSocket, packet);

catch
    % CRITICAL: never let the callback propagate an error to ScanImage.
    % Silently drop this frame if the socket is closed or any property lookup fails.
end
end
