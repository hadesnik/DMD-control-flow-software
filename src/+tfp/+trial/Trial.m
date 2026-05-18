classdef Trial < handle
    %Trial One stimulation event plus its metadata and acquired data.
    %   A Trial is the unit of work for the Sequencer. Created with
    %   the planning fields populated; data and status are filled in
    %   during execution.

    properties
        trialIdx
        sessionId = ''
        timestamp = NaT
        targetSpec       % struct: .cellIds, .dmdCoords, .patternRef
        powerMw          % at sample
        duration_s
        pulseTrain       % struct: .nPulses, .interPulse_s, .pulseWidth_s
        preStim_s        % baseline period
        postStim_s       % response window
        metadata         % free-form struct
    end

    properties (SetAccess = private)
        data = []            % populated after trial runs
        status = 'pending'   % 'pending' | 'running' | 'complete' | 'failed'
    end

    methods
        function markRunning(obj)
            %markRunning Transition status to 'running'.
            if ~ismember(obj.status, {'pending', 'running'})
                error('tfp:trial:Trial:badTransition', ...
                    'markRunning requires status pending or running; got %s.', ...
                    obj.status);
            end
            obj.status = 'running';
        end

        function markComplete(obj, data)
            %markComplete Store data and transition status to 'complete'.
            if ~ismember(obj.status, {'pending', 'running'})
                error('tfp:trial:Trial:badTransition', ...
                    'markComplete requires status pending or running; got %s.', ...
                    obj.status);
            end
            obj.data   = data;
            obj.status = 'complete';
        end

        function markFailed(obj, errOrMsg)
            %markFailed Transition status to 'failed' and attach error info.
            %   errOrMsg may be an MException (.identifier + .message
            %   captured) or a char/string (.message only). Stored at
            %   obj.data.error.
            if ~ismember(obj.status, {'pending', 'running'})
                error('tfp:trial:Trial:badTransition', ...
                    'markFailed requires status pending or running; got %s.', ...
                    obj.status);
            end
            if nargin < 2 || isempty(errOrMsg)
                err = struct('message', '');
            elseif isa(errOrMsg, 'MException')
                err = struct('identifier', errOrMsg.identifier, ...
                             'message',    errOrMsg.message);
            else
                err = struct('message', char(errOrMsg));
            end
            if isstruct(obj.data)
                obj.data.error = err;
            else
                obj.data = struct('error', err);
            end
            obj.status = 'failed';
        end
    end
end
