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
        configuredDiLines_ = {}
        aiRangeV_ = []
        queuedAo_ = []
        queuedPulses_ = struct('lineNames', {}, 'times', {}, 'durations', {})
        fakeCells_ = []
        startTime_ = NaT
        log_ = struct('timestamp', {}, 'eventType', {}, 'payload', {})

        % --- Continuous-session state (T-SYNC-2, see docs/SYNC_FRAME.md) ---
        continuousCfg_ = []
        continuousStartTic_ = []
        continuousStartDatetime_ = NaT
        continuousAoSamplesWritten_ = uint64(0)
        continuousFinalSampleCount_ = uint64(0)
        continuousEverStarted_ = false
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
            obj.configuredDiLines_    = {};
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

        function configureDigitalInput(obj, lines)
            %configureDigitalInput Register DI lines for frame clock capture.
            %   lines must be a subset of digitalInChannels (from config).
            obj.requireInitialized('configureDigitalInput');
            linesC = cellstr(lines);
            availC = obj.digitalInChannels;
            if ~isempty(availC)
                availC = cellstr(availC);
                if ~all(ismember(linesC, availC))
                    error('tfp:hardware:MockDAQ:badLines', ...
                        'lines must be a subset of digitalInChannels.');
                end
            end
            obj.configuredDiLines_ = linesC;
            obj.logEvent('configureDigitalInput', struct('lines', {linesC}));
        end

        function data = readDigitalInput(obj, lineName, nSamples)
            %readDigitalInput Return a synthetic 30 Hz frame clock vector.
            %   Returns nSamples × 1 double with 1s at each frame onset.
            %   Simulates ScanImage frame acquisition pulses at 30 Hz.
            obj.requireInitialized('readDigitalInput');
            framePeriod = max(1, round(obj.sampleRate / 30));
            data        = zeros(nSamples, 1);
            data(1:framePeriod:end) = 1;
            obj.logEvent('readDigitalInput', struct( ...
                'lineName', char(lineName), 'nSamples', nSamples));
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
            obj.configuredDiLines_    = {};
            obj.aiRangeV_             = [];
            obj.queuedAo_             = [];
            obj.queuedPulses_         = struct('lineNames', {}, 'times', {}, 'durations', {});
            obj.fakeCells_            = [];
            obj.startTime_            = NaT;

            obj.continuousCfg_              = [];
            obj.continuousStartTic_         = [];
            obj.continuousStartDatetime_    = NaT;
            obj.continuousAoSamplesWritten_ = uint64(0);
            obj.continuousFinalSampleCount_ = uint64(0);
            obj.continuousEverStarted_      = false;

            obj.logEvent('cleanup', []);
        end

        function outputSingleAnalog(obj, channelName, voltageV)
            %outputSingleAnalog Immediately output a constant voltage on one AO channel.
            %   Mock implementation: validates args and logs the call; does not
            %   drive any real hardware.
            obj.requireInitialized('outputSingleAnalog');
            if ~isnumeric(voltageV) || ~isscalar(voltageV) || ~isfinite(voltageV)
                error('tfp:hardware:MockDAQ:outputSingleAnalog:badVoltage', ...
                    'voltageV must be a finite scalar; got %s.', mat2str(voltageV));
            end
            obj.logEvent('outputSingleAnalog', struct( ...
                'channel', char(channelName), 'voltageV', voltageV));
        end

        function startContinuousSession(obj, cfg)
            %startContinuousSession Begin the single hardware-clocked session.
            %   Snapshots cfg, arms a synthetic master clock (wall-clock via
            %   tic), and begins accumulating synthetic AI/DI for return at
            %   stopContinuousSession. See docs/SYNC_FRAME.md §4.1.
            if obj.isRunning
                error('tfp:hardware:DAQ:alreadyRunning', ...
                    'startContinuousSession called while a session is already running.');
            end
            if ~isstruct(cfg) || ~isscalar(cfg)
                error('tfp:hardware:DAQ:badConfig', ...
                    'cfg must be a scalar struct.');
            end
            if ~isfield(cfg, 'sampleRate') || ~isnumeric(cfg.sampleRate) ...
                    || ~isscalar(cfg.sampleRate) || ~isfinite(cfg.sampleRate) ...
                    || cfg.sampleRate <= 0
                error('tfp:hardware:DAQ:badConfig', ...
                    'cfg.sampleRate must be a positive finite scalar.');
            end

            aiChannels           = configField(cfg, 'aiChannels', []);
            aiRangeV             = configField(cfg, 'aiRangeV', []);
            aoChannels           = configField(cfg, 'aoChannels', []);
            diLinesRaw           = configField(cfg, 'diLines', {});
            doLinesRaw           = configField(cfg, 'doLines', {});
            frameClockLine       = configField(cfg, 'frameClockLine', '');
            syntheticFrameRateHz = configField(cfg, 'syntheticFrameRateHz', 30);

            if ~isnumeric(aiChannels) || (~isempty(aiChannels) && ~isvector(aiChannels))
                error('tfp:hardware:DAQ:badConfig', ...
                    'cfg.aiChannels must be a numeric vector (may be empty).');
            end
            if ~isnumeric(aoChannels) || (~isempty(aoChannels) && ~isvector(aoChannels))
                error('tfp:hardware:DAQ:badConfig', ...
                    'cfg.aoChannels must be a numeric vector (may be empty).');
            end
            if isempty(diLinesRaw)
                diLines = {};
            else
                diLines = cellstr(diLinesRaw);
                diLines = diLines(:)';
            end
            if isempty(doLinesRaw)
                doLines = {};
            else
                doLines = cellstr(doLinesRaw);
                doLines = doLines(:)';
            end
            if isempty(frameClockLine)
                frameClockLineC = '';
            else
                frameClockLineC = char(frameClockLine);
                if ~any(strcmp(frameClockLineC, diLines))
                    error('tfp:hardware:DAQ:badConfig', ...
                        'cfg.frameClockLine (''%s'') must appear in cfg.diLines.', ...
                        frameClockLineC);
                end
            end
            if ~isnumeric(syntheticFrameRateHz) || ~isscalar(syntheticFrameRateHz) ...
                    || ~isfinite(syntheticFrameRateHz) || syntheticFrameRateHz <= 0
                error('tfp:hardware:DAQ:badConfig', ...
                    'cfg.syntheticFrameRateHz must be a positive finite scalar.');
            end

            snap = struct();
            snap.sampleRate           = double(cfg.sampleRate);
            snap.aiChannels           = aiChannels;
            snap.aiRangeV             = aiRangeV;
            snap.aoChannels           = aoChannels;
            snap.diLines              = diLines;
            snap.doLines              = doLines;
            snap.frameClockLine       = frameClockLineC;
            snap.syntheticFrameRateHz = double(syntheticFrameRateHz);

            obj.sampleRate                  = snap.sampleRate;
            obj.continuousCfg_              = snap;
            obj.continuousStartTic_         = tic;
            obj.continuousStartDatetime_    = datetime('now');
            obj.continuousAoSamplesWritten_ = uint64(0);
            obj.continuousFinalSampleCount_ = uint64(0);
            obj.continuousEverStarted_      = true;
            obj.isRunning                   = true;

            obj.logEvent('startContinuousSession', snap);
        end

        function result = stopContinuousSession(obj)
            %stopContinuousSession Stop the master clock; return captured data.
            %   Returns the schema documented in docs/SYNC_FRAME.md §4.2.
            if ~obj.isRunning || isempty(obj.continuousCfg_)
                error('tfp:hardware:DAQ:notRunning', ...
                    'stopContinuousSession called without an active continuous session.');
            end

            snap     = obj.continuousCfg_;
            elapsed  = toc(obj.continuousStartTic_);
            nSamples = uint64(max(0, floor(elapsed * snap.sampleRate)));
            nS       = double(nSamples);

            nAi = numel(snap.aiChannels);
            if nAi > 0 && nS > 0
                noise = randn(nS, nAi) * 0.01;
                drift = cumsum(randn(nS, nAi) * 1e-5);
                aiData = noise + drift;
            else
                aiData = zeros(nS, nAi);
            end

            nDi    = numel(snap.diLines);
            diData = zeros(nS, nDi);
            if ~isempty(snap.frameClockLine) && nS > 0 && nDi > 0
                framePeriod = max(1, round(snap.sampleRate / snap.syntheticFrameRateHz));
                col         = find(strcmp(snap.frameClockLine, snap.diLines), 1);
                pulseIdx    = 1:framePeriod:nS;
                diData(pulseIdx, col) = 1;
            end

            lineNames                = struct();
            lineNames.aiChannels     = snap.aiChannels;
            lineNames.aoChannels     = snap.aoChannels;
            lineNames.diLines        = snap.diLines;
            lineNames.doLines        = snap.doLines;
            lineNames.frameClockLine = snap.frameClockLine;

            result                       = struct();
            result.aiData                = aiData;
            result.diData                = diData;
            result.aoSamplesWritten      = obj.continuousAoSamplesWritten_;
            result.nSamplesTotal         = nSamples;
            result.sampleRate            = snap.sampleRate;
            result.sessionStartDatetime  = obj.continuousStartDatetime_;
            result.lineNames             = lineNames;

            obj.continuousFinalSampleCount_ = nSamples;
            obj.isRunning                   = false;

            obj.logEvent('stopContinuousSession', struct( ...
                'nSamplesTotal',    nSamples, ...
                'aoSamplesWritten', obj.continuousAoSamplesWritten_));
        end

        function idx = currentSampleIndex(obj)
            %currentSampleIndex 1-based DAQ sample index since session start.
            %   Returns count-of-samples-acquired + 1 while running; the
            %   frozen final count after stopContinuousSession. See
            %   docs/SYNC_FRAME.md §4.3.
            if ~obj.continuousEverStarted_
                error('tfp:hardware:DAQ:notRunning', ...
                    'currentSampleIndex called without an active continuous session.');
            end
            if obj.isRunning
                elapsed = toc(obj.continuousStartTic_);
                rate    = obj.continuousCfg_.sampleRate;
                idx     = uint64(max(0, floor(elapsed * rate)) + 1);
            else
                idx = obj.continuousFinalSampleCount_;
            end
        end

        function startSampleIdx = queueClockedAO(obj, samples, rate, startTrigger)
            %queueClockedAO Queue a hardware-clocked AO waveform.
            %   Returns the DAQ sample index at which the first queued
            %   sample will be output (use as t_onset_daq_samples). See
            %   docs/SYNC_FRAME.md §4.4.
            if ~obj.isRunning || isempty(obj.continuousCfg_)
                error('tfp:hardware:DAQ:notRunning', ...
                    'queueClockedAO requires an active continuous session.');
            end
            snap = obj.continuousCfg_;
            nAo  = numel(snap.aoChannels);
            if ~isnumeric(samples) || ndims(samples) > 2 || size(samples, 2) ~= nAo
                error('tfp:hardware:DAQ:badShape', ...
                    'samples must be (nSamples x %d) numeric; got size [%s].', ...
                    nAo, num2str(size(samples)));
            end
            if ~isnumeric(rate) || ~isscalar(rate) || rate ~= snap.sampleRate
                error('tfp:hardware:DAQ:badRate', ...
                    'rate (%g) must equal the active session sampleRate (%g).', ...
                    double(rate), snap.sampleRate);
            end
            trigC = char(startTrigger);
            switch trigC
                case 'immediate'
                    % Round-1 default; nothing to do.
                case 'sync'
                    error('tfp:hardware:DAQ:notImplemented', ...
                        'startTrigger=''sync'' is reserved for future use.');
                otherwise
                    error('tfp:hardware:DAQ:badConfig', ...
                        'startTrigger must be ''immediate'' or ''sync''; got ''%s''.', ...
                        trigC);
            end

            startSampleIdx = obj.currentSampleIndex();
            obj.continuousAoSamplesWritten_ = ...
                obj.continuousAoSamplesWritten_ + uint64(size(samples, 1));

            obj.logEvent('queueClockedAO', struct( ...
                'startSampleIdx', startSampleIdx, ...
                'nSamples',       uint64(size(samples, 1)), ...
                'nChans',         nAo, ...
                'rate',           rate, ...
                'startTrigger',   trigC));
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
