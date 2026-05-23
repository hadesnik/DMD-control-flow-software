classdef Trial < handle
    %Trial One stimulation event plus its metadata and acquired data.
    %   A Trial is the unit of work for the Sequencer. Created with
    %   the planning fields populated; data and status are filled in
    %   during execution.
    %
    %   See docs/SYNC_FRAME.md §6 for the canonical sample-anchor and
    %   frame-alignment schema added by TASK-SYNC-ALIGN.

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

        % --- DAQ sample anchors (filled during execution; see SYNC_FRAME.md §6.1) ---
        t_onset_daq_samples       = NaN   % uint64 sample index of stim onset
        t_offset_daq_samples      = NaN   % uint64 sample index of stim offset
        daq_master_sample_rate_hz = NaN   % Hz, snapshot of session sampleRate
        session_start_datetime    = NaT   % wall-clock anchor for the session

        % --- Frame alignment (filled post-hoc; see SYNC_FRAME.md §6.2) ---
        t_onset_si_aux_edge_index = NaN   % index into SI aux rising-edge list
        frame_indices_during_stim = uint64([])  % SI frames overlapping stim
        frame_indices_baseline    = uint64([])  % SI frames in pre-stim window
    end

    methods
        function markRunning(obj, onsetSample, sampleRate, sessionStartDatetime)
            %markRunning Transition status to 'running'.
            %   markRunning(obj) — backward-compatible no-arg form.
            %   markRunning(obj, onsetSample, sampleRate, sessionStartDatetime)
            %       records the DAQ sample anchor for stim onset plus the
            %       session-level invariants. All three extended args are
            %       required together.
            if ~ismember(obj.status, {'pending', 'running'})
                error('tfp:trial:Trial:badTransition', ...
                    'markRunning requires status pending or running; got %s.', ...
                    obj.status);
            end
            if nargin > 1
                if nargin ~= 4
                    error('tfp:trial:Trial:badArgs', ...
                        ['markRunning extended form requires ' ...
                         '(onsetSample, sampleRate, sessionStartDatetime); ' ...
                         'got %d args.'], nargin - 1);
                end
                obj.t_onset_daq_samples       = onsetSample;
                obj.daq_master_sample_rate_hz = sampleRate;
                obj.session_start_datetime    = sessionStartDatetime;
            end
            obj.status = 'running';
        end

        function markComplete(obj, data, offsetSample)
            %markComplete Store data and transition status to 'complete'.
            %   markComplete(obj, data) — backward-compatible.
            %   markComplete(obj, data, offsetSample) records the DAQ sample
            %   anchor for stim offset.
            if ~ismember(obj.status, {'pending', 'running'})
                error('tfp:trial:Trial:badTransition', ...
                    'markComplete requires status pending or running; got %s.', ...
                    obj.status);
            end
            obj.data   = data;
            if nargin >= 3
                obj.t_offset_daq_samples = offsetSample;
            end
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

        function attachFrameAlignment(obj, frameIndicesDuringStim, ...
                frameIndicesBaseline, siAuxEdgeIndex)
            %attachFrameAlignment Populate post-hoc frame alignment fields.
            %   Callable only after markComplete; otherwise throws
            %   tfp:trial:Trial:badTransition. Idempotent if called twice
            %   with the same values; conflicting re-application throws
            %   tfp:trial:Trial:frameAlignmentMismatch.
            if ~strcmp(obj.status, 'complete')
                error('tfp:trial:Trial:badTransition', ...
                    'attachFrameAlignment requires status complete; got %s.', ...
                    obj.status);
            end
            newDuring   = uint64(frameIndicesDuringStim(:).');
            newBaseline = uint64(frameIndicesBaseline(:).');
            alreadySet = ~isempty(obj.frame_indices_during_stim) ...
                      || ~isempty(obj.frame_indices_baseline) ...
                      || ~isnan(obj.t_onset_si_aux_edge_index);
            if alreadySet
                same = isequal(obj.frame_indices_during_stim, newDuring) ...
                    && isequal(obj.frame_indices_baseline,   newBaseline) ...
                    && isequaln(obj.t_onset_si_aux_edge_index, siAuxEdgeIndex);
                if ~same
                    error('tfp:trial:Trial:frameAlignmentMismatch', ...
                        'attachFrameAlignment called twice with different values.');
                end
                return
            end
            obj.frame_indices_during_stim = newDuring;
            obj.frame_indices_baseline    = newBaseline;
            obj.t_onset_si_aux_edge_index = siAuxEdgeIndex;
        end
    end
end
