% SIStreamTeardown  Close the F-streaming socket and deregister the callback.
%
% Run at the end of each session on the imaging PC.
% Safe to run even if SIStreamSetup was not called this session.

global SIStreamSocket %#ok<GVMIS>

if ~isempty(SIStreamSocket)
    try
        mssend(SIStreamSocket, 'F_STREAM_DONE');
        msclose(SIStreamSocket);
    catch
    end
    SIStreamSocket = [];
    disp('F-streaming socket closed.');
else
    disp('No streaming socket was open.');
end

% Disable si_frame_callback in ScanImage user functions.
try
    cfg = hSI.hUserFunctions.userFunctionsCfg;
    idx = strcmp({cfg.UserFcnName}, 'si_frame_callback');
    if any(idx)
        hSI.hUserFunctions.userFunctionsCfg(idx).Enable = false;
        disp('Frame callback disabled.');
    else
        disp('Frame callback was not registered.');
    end
catch ME
    fprintf('Could not disable callback: %s\n', ME.message);
end

disp('F streaming stopped.');
