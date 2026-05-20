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
        cleanup(obj)
    end
end
