function safetyChecks(command)
%safetyChecks Phase 1 placeholder for laser/Pockels safety interlocks.
%
%   Forms:
%     tfp.util.safetyChecks('arm')   - clear the in-process abort flag
%     tfp.util.safetyChecks('check') - throw tfp:util:safetyAbort if set
%     tfp.util.safetyChecks('abort') - set the abort flag
%
%   The flag lives in a persistent variable, so it survives across
%   calls within a single MATLAB session.
%
%   TODO(Phase 2): replace this with real laser-path interlocks
%   (Pockels-cell closed during trial gaps, shutter state, requested
%   power under configured maximum, hardware-level abort signaling).

persistent abortFlag
if isempty(abortFlag)
    abortFlag = false;
end

if nargin < 1
    error('tfp:util:safetyChecks:badCommand', ...
        'command must be one of: ''arm'', ''check'', ''abort''.');
end

switch lower(char(command))
    case 'arm'
        abortFlag = false;
    case 'abort'
        abortFlag = true;
    case 'check'
        if abortFlag
            error('tfp:util:safetyAbort', ...
                'safety abort flag is set; aborting.');
        end
    otherwise
        error('tfp:util:safetyChecks:badCommand', ...
            'unknown command: ''%s''. Expected ''arm'', ''check'', ''abort''.', ...
            char(command));
end
end
