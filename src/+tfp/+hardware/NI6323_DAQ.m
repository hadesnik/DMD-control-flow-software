classdef NI6323_DAQ < tfp.hardware.DAQ
%NI6323_DAQ Real NI PCIe-6323 DAQ using legacy daq.createSession interface.
%   Implements the DAQ abstract interface for MATLAB R2019a with NI-DAQmx
%   19.5.0. All hardware calls use the legacy daq.createSession('ni') API
%   (marked %LEGACY_API). Do NOT substitute dataacquisition() or daq().
%
%   Typical call sequence:
%     d = tfp.hardware.NI6323_DAQ(config)
%     d.configureAnalogInput(aiChannels, rangeV)
%     d.configureAnalogOutput(aoChannels)
%     d.configureDigitalOutput(doLines)
%     d.queueAnalogOutput(data)
%     d.queueDigitalPulses(lineNames, times, durations)
%     d.start()
%     aiData = d.readAnalogInput(nSamples)
%     d.stop()
%     d.cleanup()
%
%   Note: concurrent AO background output and AI foreground acquisition
%   share one session. When isRunning (background AO active), readAnalogInput
%   uses inputSingleScan() for single samples and a DataAvailable listener
%   for multi-sample reads. If the AI/AO interaction is problematic on the
%   scope PC, split into two sessions in initialize().
%
%   See ARCHITECTURE.md "DAQ" and CLAUDE.md "CONFIRMED HARDWARE ENVIRONMENT".

    properties (SetAccess = protected)
        sampleRate         = []
        analogInChannels   = []
        analogOutChannels  = []
        digitalInChannels  = {}
        digitalOutChannels = {}
        isRunning          = false
    end

    properties (Access = private)
        deviceName_           % e.g. 'Dev1'
        session_              % daq.createSession('ni') object %LEGACY_API
        isInitialized_        = false
        configuredAiChannels_ = []
        configuredAoChannels_ = []
        configuredDoLines_    = {}
        aiRangeV_             = []
        aoData_               = []   % nSamples × nAoCh, stored until start()
        digitalPulses_              % struct array: lineNames, times, durations
        aiBuf_                = []   % filled by DataAvailable listener
        aiListener_           = []   % event.listener handle
        log_                        % struct array {timestamp, eventType, payload}
    end

    methods
        function obj = NI6323_DAQ(config)
            %NI6323_DAQ Construct and initialize the NI PCIe-6323 session.
            %   config.deviceName  (default 'Dev1')
            %   config.sampleRate  (default 10000)
            %   config.analogInChannels / analogOutChannels / digitalOutChannels
            if nargin < 1
                config = struct();
            end
            obj.log_ = struct('timestamp', {}, 'eventType', {}, 'payload', {});
            obj.digitalPulses_ = struct('lineNames', {}, 'times', {}, 'durations', {});
            obj.initialize(config);
        end

        function initialize(obj, config)
            %initialize Create NI-DAQmx session and set sample rate.
            %   Throws tfp:hardware:NI6323_DAQ:driverNotFound when NI-DAQmx
            %   is absent or not operational.
            if ~isstruct(config)
                error('tfp:hardware:NI6323_DAQ:badConfig', ...
                    'config must be a struct.');
            end

            obj.deviceName_        = char(configField(config, 'deviceName', 'Dev1'));
            obj.sampleRate         = configField(config, 'sampleRate', 10000);
            obj.analogInChannels   = configField(config, 'analogInChannels',  []);
            obj.analogOutChannels  = configField(config, 'analogOutChannels', []);
            obj.digitalInChannels  = configField(config, 'digitalInChannels',  {});
            obj.digitalOutChannels = configField(config, 'digitalOutChannels', {});

            try
                s = daq.createSession('ni');  %LEGACY_API
            catch ME
                if contains(ME.message, 'vendor') || contains(ME.message, 'ni') || ...
                        contains(ME.identifier, 'daq')
                    error('tfp:hardware:NI6323_DAQ:driverNotFound', ...
                        ['NI-DAQmx driver not found or not operational. ' ...
                         'Verify NI-DAQmx 19.5.0+ is installed and ' ...
                         'daq.getVendors() shows ''ni'' with IsOperational=true. ' ...
                         'Original: %s'], ME.message);
                end
                rethrow(ME);
            end
            s.Rate = obj.sampleRate;  %LEGACY_API

            obj.session_           = s;
            obj.isRunning          = false;
            obj.isInitialized_     = true;
            obj.configuredAiChannels_ = [];
            obj.configuredAoChannels_ = [];
            obj.configuredDoLines_    = {};
            obj.aiRangeV_          = [];
            obj.aoData_            = [];
            obj.digitalPulses_     = struct('lineNames', {}, 'times', {}, 'durations', {});
            obj.aiBuf_             = [];
            obj.aiListener_        = [];

            obj.logEvent('initialize', struct( ...
                'deviceName', obj.deviceName_, 'sampleRate', obj.sampleRate));
        end

        function configureAnalogInput(obj, channels, rangeV)
            %configureAnalogInput Add AI voltage channels to the session.
            obj.requireInitialized('configureAnalogInput');
            for k = 1:numel(channels)
                ch = obj.session_.addAnalogInputChannel( ...  %LEGACY_API
                    obj.deviceName_, channels(k), 'Voltage');
                if nargin >= 3 && ~isempty(rangeV) && numel(rangeV) == 2
                    try
                        ch.Range = rangeV;  %LEGACY_API
                    catch
                        % Range property not available on all channel subtypes.
                    end
                end
            end
            obj.configuredAiChannels_ = channels(:)';
            obj.aiRangeV_             = rangeV;
            obj.logEvent('configureAnalogInput', struct( ...
                'channels', channels, 'rangeV', rangeV));
        end

        function configureAnalogOutput(obj, channels)
            %configureAnalogOutput Add AO voltage channels to the session.
            obj.requireInitialized('configureAnalogOutput');
            for k = 1:numel(channels)
                obj.session_.addAnalogOutputChannel( ...  %LEGACY_API
                    obj.deviceName_, channels(k), 'Voltage');
            end
            obj.configuredAoChannels_ = channels(:)';
            obj.logEvent('configureAnalogOutput', struct('channels', channels));
        end

        function configureDigitalOutput(obj, lines)
            %configureDigitalOutput Add digital output lines to the session.
            obj.requireInitialized('configureDigitalOutput');
            linesC = cellstr(lines);
            for k = 1:numel(linesC)
                obj.session_.addDigitalChannel( ...  %LEGACY_API
                    obj.deviceName_, linesC{k}, 'OutputOnly');
            end
            obj.configuredDoLines_ = linesC;
            obj.logEvent('configureDigitalOutput', struct('lines', {linesC}));
        end

        function queueAnalogOutput(obj, data)
            %queueAnalogOutput Store AO waveform for output during start().
            %   data: nSamples × nAoChans double matrix.
            obj.requireInitialized('queueAnalogOutput');
            if isempty(obj.configuredAoChannels_)
                error('tfp:hardware:NI6323_DAQ:noAoConfigured', ...
                    'configureAnalogOutput() required first.');
            end
            nChans = numel(obj.configuredAoChannels_);
            if ~isnumeric(data) || ndims(data) > 2 || size(data, 2) ~= nChans
                error('tfp:hardware:NI6323_DAQ:badShape', ...
                    'data must be nSamples × %d numeric; got size [%s].', ...
                    nChans, num2str(size(data)));
            end
            obj.aoData_ = data;
            obj.logEvent('queueAnalogOutput', struct( ...
                'nSamples', size(data, 1), 'nChans', size(data, 2)));
        end

        function queueDigitalPulses(obj, lineNames, times, durations)
            %queueDigitalPulses Store digital pulse specs for execution at start().
            %   lineNames: cell array of DO line names (must be in configuredDoLines)
            %   times:     pulse onset times (s), same length as lineNames
            %   durations: pulse durations (s), same length as lineNames
            %
            %   Phase 2 note: pulses are stored but not yet synthesised into
            %   a DO waveform; sendDigitalPulse() remains the low-latency path.
            obj.requireInitialized('queueDigitalPulses');
            lineNamesC = cellstr(lineNames);
            if numel(lineNamesC) ~= numel(times) || numel(lineNamesC) ~= numel(durations)
                error('tfp:hardware:NI6323_DAQ:badLengths', ...
                    'lineNames, times, durations must be the same length.');
            end
            obj.digitalPulses_(end+1) = struct( ...
                'lineNames', {lineNamesC}, ...
                'times',     {times(:)'}, ...
                'durations', {durations(:)'});
            obj.logEvent('queueDigitalPulses', struct('nPulses', numel(lineNamesC)));
        end

        function start(obj)
            %start Queue AO data and start background output.
            obj.requireInitialized('start');
            if ~isempty(obj.aoData_)
                obj.session_.queueOutputData(obj.aoData_);  %LEGACY_API
            end
            obj.session_.startBackground();  %LEGACY_API
            obj.isRunning = true;
            obj.logEvent('start', []);
        end

        function stop(obj)
            %stop Stop the background session and clear queued data.
            if obj.isInitialized_
                try
                    obj.session_.stop();  %LEGACY_API
                catch
                end
                if ~isempty(obj.aiListener_)
                    try, delete(obj.aiListener_); catch, end
                    obj.aiListener_ = [];
                end
            end
            obj.isRunning      = false;
            obj.aoData_        = [];
            obj.aiBuf_         = [];
            obj.digitalPulses_ = struct('lineNames', {}, 'times', {}, 'durations', {});
            obj.logEvent('stop', []);
        end

        function data = readAnalogInput(obj, nSamples)
            %readAnalogInput Blocking read of nSamples from AI channels.
            %   When isRunning (background AO active):
            %     nSamples == 1  → inputSingleScan()
            %     nSamples  > 1  → DataAvailable listener accumulates samples
            %   When not running:
            %     nSamples == 1  → inputSingleScan()
            %     nSamples  > 1  → NumberOfScans + startForeground()
            obj.requireInitialized('readAnalogInput');
            if isempty(obj.configuredAiChannels_)
                error('tfp:hardware:NI6323_DAQ:noAiConfigured', ...
                    'configureAnalogInput() required first.');
            end
            if ~isnumeric(nSamples) || ~isscalar(nSamples) || ~isfinite(nSamples) ...
                    || nSamples < 1 || nSamples ~= round(nSamples)
                error('tfp:hardware:NI6323_DAQ:badNSamples', ...
                    'nSamples must be a positive integer scalar.');
            end
            nChans = numel(obj.configuredAiChannels_);

            if nSamples == 1
                raw  = obj.session_.inputSingleScan();  %LEGACY_API
                data = reshape(raw(1:nChans), 1, nChans);
            elseif obj.isRunning
                % Background AO is active — collect AI via DataAvailable listener.
                obj.aiBuf_    = zeros(0, nChans);
                obj.aiListener_ = obj.session_.addlistener( ...  %LEGACY_API
                    'DataAvailable', @(src, evt) obj.onDataAvailable(evt, nChans));
                timeout = nSamples / obj.sampleRate * 3;  % 3× headroom
                t0      = tic;
                while size(obj.aiBuf_, 1) < nSamples && toc(t0) < timeout
                    pause(0.001);
                end
                delete(obj.aiListener_);
                obj.aiListener_ = [];
                if size(obj.aiBuf_, 1) < nSamples
                    error('tfp:hardware:NI6323_DAQ:readTimeout', ...
                        'readAnalogInput timed out after %.1f s (got %d/%d samples).', ...
                        timeout, size(obj.aiBuf_, 1), nSamples);
                end
                data       = obj.aiBuf_(1:nSamples, :);
                obj.aiBuf_ = [];
            else
                obj.session_.NumberOfScans = nSamples;  %LEGACY_API
                [raw, ~] = obj.session_.startForeground();  %LEGACY_API
                data     = raw(:, 1:nChans);
            end

            obj.logEvent('readAnalogInput', struct( ...
                'nSamples', nSamples, 'nChans', nChans));
        end

        function sendDigitalPulse(obj, lineName, durationS)
            %sendDigitalPulse Immediately output a high-then-low digital pulse.
            %   lineName must be in configuredDoLines.  durationS > 0.
            obj.requireInitialized('sendDigitalPulse');
            lineNameC = char(lineName);
            if ~any(strcmp(lineNameC, obj.configuredDoLines_))
                error('tfp:hardware:NI6323_DAQ:badLines', ...
                    'lineName ''%s'' not in configuredDoLines.', lineNameC);
            end
            if ~isnumeric(durationS) || ~isscalar(durationS) ...
                    || ~isfinite(durationS) || durationS <= 0
                error('tfp:hardware:NI6323_DAQ:badDuration', ...
                    'durationS must be a positive finite scalar.');
            end
            nLines       = numel(obj.configuredDoLines_);
            idx          = find(strcmp(lineNameC, obj.configuredDoLines_), 1);
            highVec      = zeros(1, nLines);
            highVec(idx) = 1;
            lowVec       = zeros(1, nLines);
            obj.session_.outputSingleScan(highVec);  %LEGACY_API
            pause(durationS);
            obj.session_.outputSingleScan(lowVec);   %LEGACY_API
            obj.logEvent('sendDigitalPulse', struct( ...
                'lineName', lineNameC, 'durationS', durationS));
        end

        function outputSingleAnalog(obj, channelName, voltageV)
            %outputSingleAnalog Output a constant voltage on one AO channel.
            %   channelName: 'aoN' string or integer channel number. Auto-adds the
            %   channel to the session if not already configured.
            %   voltageV must be in [-10, 10] V.
            obj.requireInitialized('outputSingleAnalog');
            chNum = obj.parseChannelName_(channelName);
            if ~isnumeric(voltageV) || ~isscalar(voltageV) || ~isfinite(voltageV)
                error('tfp:hardware:NI6323_DAQ:outputSingleAnalog:badVoltage', ...
                    'voltageV must be a finite scalar; got %s.', mat2str(voltageV));
            end
            if voltageV < -10 || voltageV > 10
                error('tfp:hardware:NI6323_DAQ:outputSingleAnalog:voltageOutOfRange', ...
                    'voltageV %.4g V is outside [-10, 10] V.', voltageV);
            end
            idx = find(obj.configuredAoChannels_ == chNum, 1);
            if isempty(idx)
                obj.session_.addAnalogOutputChannel( ...  %LEGACY_API
                    obj.deviceName_, chNum, 'Voltage');
                obj.configuredAoChannels_(end+1) = chNum;
                idx = numel(obj.configuredAoChannels_);
            end
            outVec      = zeros(1, numel(obj.configuredAoChannels_));
            outVec(idx) = voltageV;
            obj.session_.outputSingleScan(outVec);  %LEGACY_API
            obj.logEvent('outputSingleAnalog', struct('channel', chNum, 'voltageV', voltageV));
        end

        function cleanup(obj)
            %cleanup Stop and release the NI-DAQmx session.
            if obj.isInitialized_ && ~isempty(obj.session_)
                try
                    if obj.isRunning
                        obj.session_.stop();  %LEGACY_API
                    end
                    if ~isempty(obj.aiListener_)
                        delete(obj.aiListener_);
                        obj.aiListener_ = [];
                    end
                    obj.session_.release();  %LEGACY_API
                catch
                end
            end
            obj.isRunning          = false;
            obj.isInitialized_     = false;
            obj.session_           = [];
            obj.sampleRate         = [];
            obj.analogInChannels   = [];
            obj.analogOutChannels  = [];
            obj.digitalInChannels  = {};
            obj.digitalOutChannels = {};
            obj.configuredAiChannels_ = [];
            obj.configuredAoChannels_ = [];
            obj.configuredDoLines_    = {};
            obj.aiRangeV_          = [];
            obj.aoData_            = [];
            obj.aiBuf_             = [];
            obj.digitalPulses_     = struct('lineNames', {}, 'times', {}, 'durations', {});
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
            if ~obj.isInitialized_
                error('tfp:hardware:NI6323_DAQ:notInitialized', ...
                    '%s requires initialize() to have been called first.', callerName);
            end
        end

        function onDataAvailable(obj, evt, nChans)
            %onDataAvailable DataAvailable listener callback; appends to aiBuf_.
            chunk = evt.Data(:, 1:min(nChans, size(evt.Data, 2)));
            obj.aiBuf_ = [obj.aiBuf_; chunk];  %#ok<AGROW>
        end

        function chNum = parseChannelName_(obj, channelName)  %#ok<MANU>
            if ischar(channelName) || isstring(channelName)
                tok = regexp(char(channelName), '^ao(\d+)$', 'tokens', 'ignorecase');
                if isempty(tok)
                    error('tfp:hardware:NI6323_DAQ:outputSingleAnalog:badChannel', ...
                        'channelName must be ''aoN'' (e.g. ''ao1''); got ''%s''.', channelName);
                end
                chNum = str2double(tok{1}{1});
            elseif isnumeric(channelName) && isscalar(channelName) && channelName >= 0
                chNum = double(channelName);
            else
                error('tfp:hardware:NI6323_DAQ:outputSingleAnalog:badChannel', ...
                    'channelName must be a string like ''ao1'' or a non-negative integer.');
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
