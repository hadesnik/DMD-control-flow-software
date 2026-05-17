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

        % data: nSamples × nChannels
        queueAnalogOutput(obj, data)

        queueDigitalPulses(obj, lineNames, times, durations)
        start(obj)
        stop(obj)

        % blocking until nSamples acquired
        data = readAnalogInput(obj, nSamples)

        sendDigitalPulse(obj, lineName, durationS)
        cleanup(obj)
    end
end
