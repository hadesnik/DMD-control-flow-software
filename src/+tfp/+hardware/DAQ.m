classdef DAQ < handle
    %DAQ Abstract interface for the DAQ board.
    %   Subclasses include MockDAQ (simulator) and NI6323_DAQ (real
    %   NI PCIe-6323). Experiment code talks to this interface.

    properties (Abstract, SetAccess = protected)
        sampleRate
        analogInChannels
        analogOutChannels
        digitalInChannels
        digitalOutChannels
        isRunning
    end

    methods (Abstract)
        initialize(obj, config)
        configureAnalogInput(obj, channels, rangeV)
        configureAnalogOutput(obj, channels)
        configureDigitalOutput(obj, lines)

        % configure digital input lines (e.g. ScanImage frame clock)
        configureDigitalInput(obj, lines)

        % data: nSamples × nChannels
        queueAnalogOutput(obj, data)

        queueDigitalPulses(obj, lineNames, times, durations)
        start(obj)
        stop(obj)

        % blocking until nSamples acquired
        data = readAnalogInput(obj, nSamples)

        % returns nSamples × 1 double (0/1); call after readAnalogInput, before stop()
        data = readDigitalInput(obj, lineName, nSamples)

        sendDigitalPulse(obj, lineName, durationS)

        % Immediately drive one AO channel to a constant voltage (no waveform queue).
        % channelName: string, e.g. 'ao1'.  voltageV: scalar.
        outputSingleAnalog(obj, channelName, voltageV)

        % --- Continuous-session API (TASK-SYNC-ALIGN, see docs/SYNC_FRAME.md) ---

        % Start the single hardware-clocked session that runs for the whole
        % experiment. cfg fields: sampleRate, aiChannels, aiRangeV (optional),
        % aoChannels, diLines, doLines, frameClockLine (optional).
        % Side effects: arms the master clock, sets isRunning=true, snapshots
        % sessionStartDatetime.
        startContinuousSession(obj, cfg)

        % Stop the master clock and return captured data as a struct with
        % fields: aiData, diData, aoSamplesWritten, nSamplesTotal,
        % sampleRate, sessionStartDatetime, lineNames.
        result = stopContinuousSession(obj)

        % Return the current DAQ sample index (uint64, 1-based) since the
        % start of the active continuous session. Errors if not running.
        idx = currentSampleIndex(obj)

        % Queue a hardware-clocked AO waveform on cfg.aoChannels.
        %   samples       : nSamples x nAo double, volts
        %   rate          : Hz, must match the active session sampleRate
        %   startTrigger  : 'immediate' (Round-1 required) | 'sync' (reserved)
        % Returns the DAQ sample index (uint64) at which the first queued
        % sample will be output — use this as t_onset_daq_samples.
        startSampleIdx = queueClockedAO(obj, samples, rate, startTrigger)

        cleanup(obj)
    end
end
