classdef Sequencer < handle
    %Sequencer State machine that runs a TrialSequence end-to-end.
    %   Per-trial steps:
    %     1. Load DMD pattern
    %     2. Configure DAQ for this trial duration
    %     3. Trigger ScanImage to start frame acquisition
    %     4. Wait for ScanImage ready signal
    %     5. Fire stim trigger sequence on DMD via DAQ digital out
    %     6. Acquire ephys/sync during trial window
    %     7. Wait for ScanImage to finish
    %     8. Save trial data + metadata
    %     9. Advance to next trial
    %
    %   Critical: run() must check a safetyAbort flag every iteration
    %   and command the Pockels cell closed at the start of every
    %   trial gap. Laser interlocks live in tfp.util.safetyChecks.

    properties
        dmd
        daq
        siBridge
        sequence
        log
    end

    methods
        function run(obj)
            %TODO Iterate over obj.sequence.trials and execute the 9 per-trial steps above; honor safetyAbort flag each iteration; call tfp.util.safetyChecks between trials.
            error('not implemented');
        end

        function abort(obj)
            %TODO Emergency stop: command Pockels cell closed, halt DMD and DAQ, save partial state.
            error('not implemented');
        end
    end
end
