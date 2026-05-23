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

        % --- Episodic alignment (filled post-hoc; see SYNC_EPISODIC.md §6) ---
        siTiffPath           = ''        % absolute path to per-trial SI TIFF
        alignmentDiscrepancy = NaN       % siMeta.numFrames - numel(diEdges); double (NaN sentinel)
        alignmentConfidence  = "none"    % "none" | "high" | "low" | "quarantine"
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

        function markComplete(obj, data, offsetSample, siTiffPath)
            %markComplete Store data and transition status to 'complete'.
            %   markComplete(obj, data) — backward-compatible.
            %   markComplete(obj, data, offsetSample) records the DAQ sample
            %   anchor for stim offset.
            %   markComplete(obj, data, offsetSample, siTiffPath) additionally
            %   records the absolute path to the per-trial ScanImage TIFF (see
            %   SYNC_EPISODIC.md §6). Omitted siTiffPath leaves the field at ''.
            if ~ismember(obj.status, {'pending', 'running'})
                error('tfp:trial:Trial:badTransition', ...
                    'markComplete requires status pending or running; got %s.', ...
                    obj.status);
            end
            obj.data   = data;
            if nargin >= 3
                obj.t_offset_daq_samples = offsetSample;
            end
            if nargin >= 4
                obj.siTiffPath = char(siTiffPath);
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
            %   DEPRECATED — use attachEpisodicAlignment instead (see
            %   SYNC_EPISODIC.md §13). Retained for back-compat; emits a
            %   one-shot warning per MATLAB session on first call.
            %
            %   Callable only after markComplete; otherwise throws
            %   tfp:trial:Trial:badTransition. Idempotent if called twice
            %   with the same values; conflicting re-application throws
            %   tfp:trial:Trial:frameAlignmentMismatch.
            tfp.trial.Trial.attachFrameAlignmentDeprecationGuard_(false);
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

        function attachEpisodicAlignment(obj, frameIndicesDuringStim, ...
                frameIndicesBaseline, discrepancy, confidence)
            %attachEpisodicAlignment Populate episodic-mode alignment fields.
            %   Callable only on a 'complete' trial; otherwise throws
            %   tfp:trial:Trial:badTransition.
            %
            %   Validates that frame-index arguments are uint64 row vectors
            %   (or empty) and that confidence is one of
            %   "none" | "high" | "low" | "quarantine". On bad input throws
            %   tfp:trial:Trial:badFrameIndices or
            %   tfp:trial:Trial:badConfidence.
            %
            %   Idempotent: calling twice with identical values succeeds.
            %   Conflicting re-application throws
            %   tfp:trial:Trial:alignmentMismatch. See SYNC_EPISODIC.md §6.
            if ~strcmp(obj.status, 'complete')
                error('tfp:trial:Trial:badTransition', ...
                    'attachEpisodicAlignment requires status complete; got %s.', ...
                    obj.status);
            end

            allowedConfidence = ["none", "high", "low", "quarantine"];
            try
                confStr = string(confidence);
            catch
                error('tfp:trial:Trial:badConfidence', ...
                    'confidence must be a string scalar; got %s.', class(confidence));
            end
            if ~isscalar(confStr) || ~ismember(confStr, allowedConfidence)
                error('tfp:trial:Trial:badConfidence', ...
                    'confidence must be one of {"none","high","low","quarantine"}.');
            end

            tfp.trial.Trial.validateFrameIndices_(frameIndicesDuringStim, 'frameIndicesDuringStim');
            tfp.trial.Trial.validateFrameIndices_(frameIndicesBaseline,   'frameIndicesBaseline');

            newDuring   = frameIndicesDuringStim;
            newBaseline = frameIndicesBaseline;
            if isempty(newDuring)
                newDuring = uint64.empty(1, 0);
            else
                newDuring = reshape(newDuring, 1, []);
            end
            if isempty(newBaseline)
                newBaseline = uint64.empty(1, 0);
            else
                newBaseline = reshape(newBaseline, 1, []);
            end

            if ~(isa(discrepancy, 'double') && isscalar(discrepancy))
                error('tfp:trial:Trial:badFrameIndices', ...
                    'discrepancy must be a scalar double.');
            end

            alreadySet = ~isempty(obj.frame_indices_during_stim) ...
                      || ~isempty(obj.frame_indices_baseline) ...
                      || ~isnan(obj.alignmentDiscrepancy) ...
                      || obj.alignmentConfidence ~= "none";
            if alreadySet
                same = isequal(obj.frame_indices_during_stim, newDuring) ...
                    && isequal(obj.frame_indices_baseline,   newBaseline) ...
                    && isequaln(obj.alignmentDiscrepancy,    discrepancy) ...
                    && obj.alignmentConfidence == confStr;
                if ~same
                    error('tfp:trial:Trial:alignmentMismatch', ...
                        'attachEpisodicAlignment called twice with different values.');
                end
                return
            end

            obj.frame_indices_during_stim = newDuring;
            obj.frame_indices_baseline    = newBaseline;
            obj.alignmentDiscrepancy      = discrepancy;
            obj.alignmentConfidence       = confStr;
        end
    end

    methods (Static, Hidden)
        function attachFrameAlignmentDeprecationGuard_(doReset)
            %attachFrameAlignmentDeprecationGuard_ Emit deprecation warning
            %   on first call; subsequent calls are silent (per MATLAB
            %   session). Pass true to reset the one-shot flag (tests only).
            persistent warnedDeprecated
            if nargin >= 1 && doReset
                warnedDeprecated = [];
                return
            end
            if isempty(warnedDeprecated)
                warning('tfp:trial:Trial:attachFrameAlignment:deprecated', ...
                    'attachFrameAlignment is deprecated; use attachEpisodicAlignment instead.');
                warnedDeprecated = true;
            end
        end
    end

    methods (Static, Access = private)
        function validateFrameIndices_(v, name)
            if isempty(v)
                if ~isa(v, 'uint64')
                    error('tfp:trial:Trial:badFrameIndices', ...
                        '%s must be uint64 (got %s).', name, class(v));
                end
                return
            end
            if ~isa(v, 'uint64')
                error('tfp:trial:Trial:badFrameIndices', ...
                    '%s must be uint64 (got %s).', name, class(v));
            end
            if ~isrow(v)
                error('tfp:trial:Trial:badFrameIndices', ...
                    '%s must be a row vector.', name);
            end
        end
    end
end
