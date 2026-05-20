function si_frame_callback(src, event) %#ok<INUSD>
%si_frame_callback ScanImage frameAcquiredFcn callback — imaging PC side.
%   Sends ROI Integration fluorescence values to the scope PC after each
%   acquired frame.  The scope PC accumulates these in ScanImageBridge.liveF_
%   via pollLiveFrames / receiveLiveFrame (TASK-P3-09).
%
%   SETUP ON IMAGING PC:
%     1. Open ScanImage.
%     2. In the MATLAB console, register this callback:
%          hSI.hUserFunctions.userFunctionsCfg(end+1).Enable    = true;
%          hSI.hUserFunctions.userFunctionsCfg(end).EventName   = 'frameAcquired';
%          hSI.hUserFunctions.userFunctionsCfg(end).UserFcnName = 'si_frame_callback';
%     3. Ensure DAQSocket is set to the open msocket handle before acquisition:
%          global DAQSocket
%          DAQSocket = <socket returned by msaccept on scope PC side>
%        In practice the ScanImage-side setup script (DAQmSocketPrep.m or
%        equivalent) should set DAQSocket when it connects to the scope PC.
%
%   %VERIFY — all hSI property names below are ASSUMED; confirm with Masato
%   before enabling in production.  Run verifyProtocol() on scope PC
%   after each change.
%
%   See scripts/SImsocketPrep.m for the scope-PC side of the msocket setup.

global DAQSocket  % set during per-session msocket connection setup on imaging PC

if isempty(DAQSocket)
    return;  % socket not initialised — skip silently, never crash ScanImage
end

try
    %VERIFY hSI.hDisplay.lastFrame — exact property name for current frame index.
    %  ASSUME: hSI.hDisplay.lastFrame is a 1-based integer frame counter.
    %  TEST:   In ScanImage MATLAB console during acquisition: disp(hSI.hDisplay.lastFrame)
    %  CHANGE: Replace with the correct property (e.g. hSI.hScan2D.frameCounter or
    %          event.frameNumber if ScanImage passes it via the event struct).
    frameNum = hSI.hDisplay.lastFrame;  %VERIFY

    %VERIFY hSI.hIntegrationRoiManager.outputChannelsData — ROI integration output.
    %  ASSUME: outputChannelsData is an nRois × 1 (or 1 × nRois) vector of mean
    %          fluorescence values for each defined ROI, updated each frame.
    %  TEST:   In ScanImage MATLAB console with ROI Integration enabled:
    %            disp(hSI.hIntegrationRoiManager.outputChannelsData)
    %  CHANGE: Replace with the correct property/method if the struct shape differs.
    %          Also check whether values are in photon counts, raw ADC, or dF/F.
    F = hSI.hIntegrationRoiManager.outputChannelsData;  %VERIFY

    packet.frame     = frameNum;
    packet.F         = F(:);       % ensure column vector
    packet.timestamp = now;        % MATLAB datenum, for diagnostics only
    mssend(DAQSocket, packet);

catch ME
    % Never let a callback error propagate — that would crash ScanImage.
    warning('si_frame_callback: %s', ME.message);
end
end
