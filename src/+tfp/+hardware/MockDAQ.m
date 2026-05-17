classdef MockDAQ < tfp.hardware.DAQ
    %MockDAQ Simulated DAQ board for pre-hardware development.
    %   Stores channel/line configs, validates queued waveforms and
    %   pulses, generates synthetic AI as Gaussian noise plus a small
    %   random-walk drift, and logs every public call with a timestamp
    %   so tests and trial scripts can be validated end-to-end.
    %
    %   Phase 1 simplification: fake-cell -> AI cross-coupling is NOT
    %   implemented here. config.fakeCells is accepted and stored but
    %   unused. The Sequencer layer (which sees both the DMD state and
    %   the DAQ) is where that coupling will be wired in. MockDAQ
    %   produces noise only.
    %
    %   See ARCHITECTURE.md "MockDAQ".

    properties (SetAccess = protected)
        sampleRate = []
        analogInChannels = []
        analogOutChannels = []
        digitalInChannels = []
        digitalOutChannels = []
        isRunning = false
        isInitialized = false
    end

    properties (Access = private)
        configuredAiChannels_ = []
        configuredAoChannels_ = []
        configuredDoLines_ = {}
        aiRangeV_ = []
        queuedAo_ = []
        queuedPulses_ = struct('lineNames', {}, 'times', {}, 'durations', {})
        fakeCells_ = []
        startTime_ = NaT
        log_ = struct('timestamp', {}, 'eventType', {}, 'payload', {})
    end

    methods
        function initialize(obj, config)
            if ~isstruct(config)
                error('tfp:hardware:MockDAQ:badConfig', ...
                    'config must be a struct.');
            end

            obj.sampleRate         = configField(config, 'sampleRate', 10000);
            obj.analogInChannels   = configField(config, 'analogInChannels', []);
            obj.analogOutChannels  = configField(config, 'analogOutChannels', []);
            obj.digitalInChannels  = configField(config, 'digitalInChannels', {});
            obj.digitalOutChannels = configField(config, 'digitalOutChannels', {});
            obj.fakeCells_         = configField(config, 'fakeCells', []);

            obj.isRunning             = false;
            obj.isInitialized         = true;
            obj.startTime_            = NaT;
            obj.queuedAo_             = [];
            obj.queuedPulses_         = struct('lineNames', {}, 'times', {}, 'durations', {});
            obj.configuredAiChannels_ = [];
            obj.configuredAoChannels_ = [];
            obj.configuredDoLines_    = {};
            obj.aiRangeV_             = [];

            obj.logEvent('initialize', config);
        end

        function configureAnalogInput(obj, channels, rangeV)
            obj.requireInitialized('configureAnalogInput');
            if ~all(ismember(channels, obj.analogInChannels))
                error('tfp:hardware:MockDAQ:badChannels', ...
                    'channels must be a subset of analogInChannels = [%s]; got [%s].', ...
                    num2str(obj.analogInChannels), num2str(channels));
            end
            obj.configuredAiChannels_ = channels;
            obj.aiRangeV_             = rangeV;
            obj.logEvent('configureAnalogInput', struct( ...
                'channels', channels, 'rangeV', rangeV));
        end

        function configureAnalogOutput(obj, channels)
            obj.requireInitialized('configureAnalogOutput');
            if ~all(ismember(channels, obj.analogOutChannels))
                error('tfp:hardware:MockDAQ:badChannels', ...
                    'channels must be a subset of analogOutChannels = [%s]; got [%s].', ...
                    num2str(obj.analogOutChannels), num2str(channels));
            end
            obj.configuredAoChannels_ = channels;
            obj.logEvent('configureAnalogOutput', struct('channels', channels));
        end

        function configureDigitalOutput(obj, lines)
            obj.requireInitialized('configureDigitalOutput');
            linesC = cellstr(lines);
            availC = cellstr(obj.digitalOutChannels);
            if ~all(ismember(linesC, availC))
                error('tfp:hardware:MockDAQ:badLines', ...
                    'lines must be a subset of digitalOutChannels.');
            end
            obj.configuredDoLines_ = linesC;
            obj.logEvent('configureDigitalOutput', struct('lines', {linesC}));
        end

        function queueAnalogOutput(obj, data)
            obj.requireInitialized('queueAnalogOutput');
            if isempty(obj.configuredAoChannels_)
                error('tfp:hardware:MockDAQ:noAoConfigured', ...
                    'configureAnalogOutput() required first.');
            end
            nChans = numel(obj.configuredAoChannels_);
            if ~isnumeric(data) || ndims(data) > 2 || size(data, 2) ~= nChans
                error('tfp:hardware:MockDAQ:badShape', ...
                    'data must be (nSamples x %d) numeric; got size [%s].', ...
                    nChans, num2str(size(data)));
            end
            obj.queuedAo_ = data;
            obj.logEvent('queueAnalogOutput', struct( ...
                'nSamples', size(data, 1), 'nChans', size(data, 2)));
        end

        function queueDigitalPulses(obj, lineNames, times, durations)
            obj.requireInitialized('queueDigitalPulses');
            lineNamesC = cellstr(lineNames);
            if numel(lineNamesC) ~= numel(times) || numel(lineNamesC) ~= numel(durations)
                error('tfp:hardware:MockDAQ:badLengths', ...
                    'lineNames, times, durations must be the same length.');
            end
            if ~all(ismember(lineNamesC, obj.configuredDoLines_))
                error('tfp:hardware:MockDAQ:badLines', ...
                    'all lineNames must be in configuredDoLines.');
            end
            obj.queuedPulses_(end+1) = struct( ...
                'lineNames', {lineNamesC}, ...
                'times',     {times}, ...
                'durations', {durations});
            obj.logEvent('queueDigitalPulses', struct('nPulses', numel(lineNamesC)));
        end

        function start(obj)
            obj.requireInitialized('start');
            obj.isRunning  = true;
            obj.startTime_ = datetime('now');
            obj.logEvent('start', []);
        end

        function stop(obj)
            obj.isRunning     = false;
            obj.queuedAo_     = [];
            obj.queuedPulses_ = struct('lineNames', {}, 'times', {}, 'durations', {});
            obj.logEvent('stop', []);
        end

        function data = readAnalogInput(obj, nSamples)
            obj.requireInitialized('readAnalogInput');
            if isempty(obj.configuredAiChannels_)
                error('tfp:hardware:MockDAQ:noAiConfigured', ...
                    'configureAnalogInput() required first.');
            end
            if ~isnumeric(nSamples) || ~isscalar(nSamples) || ~isfinite(nSamples) ...
                    || nSamples < 1 || nSamples ~= round(nSamples)
                error('tfp:hardware:MockDAQ:badNSamples', ...
                    'nSamples must be a positive integer scalar.');
            end
            nChans = numel(obj.configuredAiChannels_);
            % White Gaussian noise + a small random-walk drift.
            noise = randn(nSamples, nChans) * 0.01;
            drift = cumsum(randn(nSamples, nChans) * 1e-5);
            data  = noise + drift;
            obj.logEvent('readAnalogInput', struct( ...
                'nSamples', nSamples, 'nChans', nChans));
        end

        function sendDigitalPulse(obj, lineName, durationS)
            obj.requireInitialized('sendDigitalPulse');
            lineNameC = char(lineName);
            if ~any(strcmp(lineNameC, obj.configuredDoLines_))
                error('tfp:hardware:MockDAQ:badLines', ...
                    'lineName must be in configuredDoLines.');
            end
            if ~isnumeric(durationS) || ~isscalar(durationS) ...
                    || ~isfinite(durationS) || durationS <= 0
                error('tfp:hardware:MockDAQ:badDuration', ...
                    'durationS must be a positive finite numeric scalar.');
            end
            obj.logEvent('sendDigitalPulse', struct( ...
                'lineName', lineNameC, 'durationS', durationS));
        end

        function cleanup(obj)
            obj.isRunning             = false;
            obj.isInitialized         = false;
            obj.sampleRate            = [];
            obj.analogInChannels      = [];
            obj.analogOutChannels     = [];
            obj.digitalInChannels     = [];
            obj.digitalOutChannels    = [];
            obj.configuredAiChannels_ = [];
            obj.configuredAoChannels_ = [];
            obj.configuredDoLines_    = {};
            obj.aiRangeV_             = [];
            obj.queuedAo_             = [];
            obj.queuedPulses_         = struct('lineNames', {}, 'times', {}, 'durations', {});
            obj.fakeCells_            = [];
            obj.startTime_            = NaT;
            obj.logEvent('cleanup', []);
        end

        function entries = getLog(obj)
            %getLog Return the in-memory session log.
            %   entries is a struct array with fields
            %   {timestamp, eventType, payload}.
            entries = obj.log_;
        end
    end

    methods (Access = private)
        function logEvent(obj, eventType, payload)
            entry.timestamp = datetime('now');
            entry.eventType = eventType;
            entry.payload   = payload;
            obj.log_(end+1) = entry;
        end

        function requireInitialized(obj, callerName)
            if ~obj.isInitialized
                error('tfp:hardware:MockDAQ:notInitialized', ...
                    '%s requires initialize() to have been called first.', callerName);
            end
        end
    end
end

% --- Local helper ---

function value = configField(config, name, default)
if isfield(config, name)
    value = config.(name);
else
    value = default;
end
end
