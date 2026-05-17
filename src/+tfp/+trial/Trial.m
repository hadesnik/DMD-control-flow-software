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
end
