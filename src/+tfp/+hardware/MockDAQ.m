classdef MockDAQ < tfp.hardware.DAQ
    %MockDAQ Simulated DAQ board for pre-hardware development.
    %   Synthetic AI generation: Gaussian noise + optional EPSP-like
    %   events on ephys channels, DC + slow drift on photodiode channels.
    %   Supports a list of "fake cells" with response models so the
    %   trial/analysis pipeline can be exercised end-to-end.

    properties (SetAccess = protected)
        sampleRate
        analogInChannels
        analogOutChannels
        digitalInChannels
        digitalOutChannels
        isRunning
    end

    methods
        function initialize(obj, config)
            %TODO Initialize sample rate, channel configs, fake-cell list, and noise parameters from config.
            error('not implemented');
        end

        function configureAnalogInput(obj, channels, rangeV)
            %TODO Record channel assignments and AI range for synthetic data generation.
            error('not implemented');
        end

        function configureAnalogOutput(obj, channels)
            %TODO Record AO channel assignments (e.g., Pockels modulation envelope).
            error('not implemented');
        end

        function configureDigitalOutput(obj, lines)
            %TODO Record DO line assignments (DMD advance, ScanImage start, etc.).
            error('not implemented');
        end

        function queueAnalogOutput(obj, data)
            %TODO Queue an AO waveform (data: nSamples × nChannels) for the next start().
            error('not implemented');
        end

        function queueDigitalPulses(obj, lineNames, times, durations)
            %TODO Queue a list of digital pulses (line, onset, duration) for the next start().
            error('not implemented');
        end

        function start(obj)
            %TODO Begin generating the queued waveform and recording synthetic AI.
            error('not implemented');
        end

        function stop(obj)
            %TODO Halt waveform output and AI acquisition.
            error('not implemented');
        end

        function data = readAnalogInput(obj, nSamples)
            %TODO Block until nSamples have been generated and return them.
            error('not implemented');
        end

        function sendDigitalPulse(obj, lineName, durationS)
            %TODO Emit a single digital pulse on lineName for durationS seconds and log its timing.
            error('not implemented');
        end

        function cleanup(obj)
            %TODO Stop any running tasks and clear internal state.
            error('not implemented');
        end
    end
end
