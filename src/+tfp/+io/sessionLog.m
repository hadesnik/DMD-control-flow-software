function line = sessionLog(sessionId, eventType, payload)
%sessionLog Append a tab-separated entry to <sessionId>/log.txt.
%
%   Inputs:
%     sessionId - path to the session directory.
%     eventType - char/string describing the event.
%     payload   - any jsonencode-able value (use [] or struct() for none).
%
%   Output:
%     line - the line written to disk, without the trailing newline.

if ~(ischar(sessionId) || (isstring(sessionId) && isscalar(sessionId)))
    error('tfp:io:sessionLog:badSessionId', ...
        'sessionId must be a char or string scalar.');
end
sessionId = char(sessionId);

if ~isfolder(sessionId)
    mkdir(sessionId);
end

dt = datetime('now', 'Format', 'yyyy-MM-dd''T''HH:mm:ss.SSS');
ts = char(dt);
line = sprintf('%s\t%s\t%s', ts, char(eventType), jsonencode(payload));

logFile = fullfile(sessionId, 'log.txt');
fid = fopen(logFile, 'a');
if fid < 0
    error('tfp:io:sessionLog:writeFailed', ...
        'failed to open %s for append.', logFile);
end
closer = onCleanup(@() fclose(fid)); %#ok<NASGU>
fprintf(fid, '%s\n', line);
end
