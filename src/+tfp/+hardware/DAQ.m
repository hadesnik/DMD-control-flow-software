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

    % --- Laser-power safety (shared by all DAQ subclasses) -----------------
    % Every write to the FS-50 modulation channel (ao3) passes through the
    % policy in tfp.util.assertLaserPowerSafe. Defaults apply to every DAQ even
    % without config; configureLaserSafety(config.laser) tunes them. See
    % CLAUDE.md "Laser-power safety".
    properties (Access = protected)
        laserChannel_   = 3   % AO channel number driving the FS-50 (ao3)
        laserSafetyCfg_ = struct( ...
            'fullPowerVoltage',   5, ...   % V = 100% (full-rep-rate worst case)
            'offVoltage',         0, ...   % V = laser off
            'confirmPct',         10, ...  % > this % -> confirmation required
            'maxSustainedPct',    20, ...  % > this % held >= sustainedDurationS -> hard block
            'sustainedDurationS', 1, ...   % s
            'autoConfirmPower',   false)   % headless opt-in for >confirmPct
    end

    methods
        function configureLaserSafety(obj, laserCfg)
            %configureLaserSafety Set the FS-50 channel + power policy from config.laser.
            %   laserCfg: the config.laser struct. Recognised fields (missing
            %   ones keep the current value): fs50_ao_channel,
            %   modulation_voltage_max, modulation_voltage_min, confirm_power_pct,
            %   max_sustained_power_pct, sustained_duration_s, autoConfirmPower.
            if nargin < 2 || ~isstruct(laserCfg) || isempty(fieldnames(laserCfg))
                return
            end
            if isfield(laserCfg, 'fs50_ao_channel') && ~isempty(laserCfg.fs50_ao_channel)
                obj.laserChannel_ = obj.parseAoChannel_(laserCfg.fs50_ao_channel);
            end
            c   = obj.laserSafetyCfg_;
            map = { 'modulation_voltage_max',  'fullPowerVoltage';
                    'modulation_voltage_min',  'offVoltage';
                    'confirm_power_pct',       'confirmPct';
                    'max_sustained_power_pct', 'maxSustainedPct';
                    'sustained_duration_s',    'sustainedDurationS';
                    'autoConfirmPower',        'autoConfirmPower';
                    'interactive',             'interactive' };
            for i = 1:size(map, 1)
                if isfield(laserCfg, map{i, 1}) && ~isempty(laserCfg.(map{i, 1}))
                    c.(map{i, 2}) = laserCfg.(map{i, 1});
                end
            end
            c.autoConfirmPower  = logical(c.autoConfirmPower);
            obj.laserSafetyCfg_ = c;
        end
    end

    methods (Access = protected)
        function checkLaserAO_(obj, channelNum, peakVoltageV, onDurationS)
            %checkLaserAO_ Apply the laser-power policy if channelNum is the FS-50 channel.
            %   No-op for any non-laser channel. onDurationS: laser-on seconds
            %   (Inf for a constant/sustained hold).
            if channelNum ~= obj.laserChannel_
                return
            end
            tfp.util.assertLaserPowerSafe(peakVoltageV, onDurationS, obj.laserSafetyCfg_);
        end

        function n = parseAoChannel_(~, ch)
            %parseAoChannel_ 'ao3'/'3'/3 -> 3 (the numeric AO channel).
            if isnumeric(ch)
                n = double(ch);
            else
                n = str2double(regexprep(char(ch), '[^0-9]', ''));
            end
        end
    end
end
