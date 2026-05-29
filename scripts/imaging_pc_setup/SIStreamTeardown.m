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

% Remove si_frame_callback from ScanImage user functions.
% Remove (not just disable) ALL matching entries — re-running SIStreamSetup
% could have stacked duplicates, and `cfg(idx).Enable = false` fails when idx
% selects more than one element.
%
% ScanImage forbids touching userFunctionsCfg during an active acquisition,
% so bail out with a clear instruction if a Focus/Grab is still running.
if isprop(hSI, 'acqState') && ~strcmpi(hSI.acqState, 'idle')
    fprintf(['ScanImage is acquiring (%s) — cannot modify user functions now.\n' ...
             'Stop Focus/Grab, then re-run SIStreamTeardown to remove the callback.\n'], ...
             hSI.acqState);
    return;
end
try
    cfg = hSI.hUserFunctions.userFunctionsCfg;
    if ~isempty(cfg)
        idx = strcmp({cfg.UserFcnName}, 'si_frame_callback');
        if any(idx)
            hSI.hUserFunctions.userFunctionsCfg = cfg(~idx);
            fprintf('Frame callback removed (%d entries).\n', nnz(idx));
        else
            disp('Frame callback was not registered.');
        end
    else
        disp('Frame callback was not registered.');
    end
catch ME
    fprintf('Could not remove callback: %s\n', ME.message);
end

disp('F streaming stopped.');
