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
        configuredDiLines_    = {}   % DI line names added via configureDigitalInput
        % Output-channel order in the session, as appended. Each entry is a
        % struct('kind','ao'|'do','name',scalar|string). outputSingleScan
        % expects an N-element vector in this exact order (AO + DO share one
        % output scan on the NI legacy session), so this is the source of
        % truth for building outVec in outputSingleAnalog / sendDigitalPulse.
        outputOrder_          = struct('kind', {}, 'name', {})
        aiRangeV_             = []
        aoData_               = []   % nSamples × nAoCh, stored until start()
        digitalPulses_              % struct array: lineNames, times, durations
        aiBuf_                = []   % AI data filled by DataAvailable listener
        diBuf_                = []   % DI data filled by DataAvailable listener (or startForeground)
        aiListener_           = []   % event.listener handle
        log_                        % struct array {timestamp, eventType, payload}

        % --- Continuous-session state (see docs/SYNC_FRAME.md §4) ---
        % The continuous-session API uses its OWN daq.createSession instance so
        % its long-running clock does not interact with the per-trial session
        % above. Only one of the two is active at a time in practice; mixing
        % is not supported and is intentionally not policed here.
        contSession_          = []          % daq.createSession('ni') %LEGACY_API
        contCfg_              = struct([])  % original cfg
        contIsRunning_        = false
        contSessionStart_     = NaT         % wall-clock anchor (datetime)
        contStartTic_         = []          % tic baseline (fallback timing)
        contNAi_              = 0
        contNDi_              = 0
        contNAo_              = 0
        contAiBuf_            = []          % nSamples × nAi
        contDiBuf_            = []          % nSamples × nDi
        contAoWritten_        = uint64(0)   % running count of clocked-AO samples queued
        contListener_         = []          % event.listener handle on DataAvailable
        contLineNames_        = struct([])  % snapshot of cfg line/channel names for stop() result
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
            obj.digitalOutChannels = configField(config, 'digitalOutChannels', {});
            % digitalInChannels reflects only lines that have been actively
            % configured via configureDigitalInput(). Do not pre-populate
            % from config here — the Sequencer uses this to decide whether
            % to attempt a frame-clock read, so it must reflect real state.

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
            obj.outputOrder_       = struct('kind', {}, 'name', {});
            obj.aiRangeV_          = [];
            obj.aoData_            = [];
            obj.digitalPulses_     = struct('lineNames', {}, 'times', {}, 'durations', {});
            obj.aiBuf_             = [];
            obj.diBuf_             = [];
            obj.configuredDiLines_ = {};
            obj.aiListener_        = [];

            obj.logEvent('initialize', struct( ...
                'deviceName', obj.deviceName_, 'sampleRate', obj.sampleRate));
        end

        function configureAnalogInput(obj, channels, rangeV, singleEndedChannels)
            %configureAnalogInput Add AI voltage channels to the session.
            %   singleEndedChannels (optional): list of channel numbers that
            %   should use SingleEnded input type instead of the default
            %   Differential. Use for 0-5V trigger monitor lines (e.g. ai3).
            %   In NI-DAQmx legacy API this sets ch.InputType = 'SingleEnded'.
            obj.requireInitialized('configureAnalogInput');
            if nargin < 4, singleEndedChannels = []; end
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
                if ~isempty(singleEndedChannels) && any(channels(k) == singleEndedChannels)
                    try
                        ch.InputType = 'SingleEnded';  %LEGACY_API
                    catch
                        % InputType not settable on all NI-DAQmx versions.
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
                obj.outputOrder_(end+1) = struct( ...
                    'kind', 'ao', 'name', channels(k));
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
                obj.outputOrder_(end+1) = struct( ...
                    'kind', 'do', 'name', linesC{k});
            end
            obj.configuredDoLines_ = linesC;
            obj.logEvent('configureDigitalOutput', struct('lines', {linesC}));
        end

        function configureDigitalInput(obj, lines)
            %configureDigitalInput Add DI lines to the session for frame clock capture.
            %   Call AFTER configureAnalogInput so AI columns precede DI columns
            %   in the DataAvailable evt.Data matrix.
            %
            %   %LEGACY_API addDigitalChannel — same call as DO but direction 'InputOnly'.
            %   %VERIFY AI+DI in a single daq.createSession on NI PCIe-6323.
            %     ASSUME: PCIe-6323 supports synchronized AI+DI in one session with a
            %             shared sample clock.  DataAvailable evt.Data columns are ordered:
            %             [AI channels | DI channels], in the order they were added.
            %     TEST:   After first real trial, inspect size(evt.Data,2) inside the
            %             DataAvailable listener — should equal numel(aiChans)+numel(diLines).
            %     CHANGE: If the device does not support mixed AI+DI sessions, use a
            %             separate daq.createSession for DI synchronized via external trigger.
            obj.requireInitialized('configureDigitalInput');
            linesC = cellstr(lines);
            for k = 1:numel(linesC)
                obj.session_.addDigitalChannel( ...  %LEGACY_API
                    obj.deviceName_, linesC{k}, 'InputOnly');
            end
            obj.configuredDiLines_ = linesC;
            obj.digitalInChannels  = linesC;
            obj.logEvent('configureDigitalInput', struct('lines', {linesC}));
        end

        function data = readDigitalInput(obj, lineName, nSamples)
            %readDigitalInput Return DI samples buffered during the most recent readAnalogInput.
            %   lineName: DI line string (must be in configuredDiLines_)
            %   nSamples: samples to return (must be <= buffered count)
            %   Returns:  nSamples × 1 double (0 or 1)
            %
            %   Call after readAnalogInput and before stop() — stop() clears diBuf_.
            obj.requireInitialized('readDigitalInput');
            lineNameC = char(lineName);
            idx = find(strcmp(lineNameC, obj.configuredDiLines_), 1);
            if isempty(idx)
                error('tfp:hardware:NI6323_DAQ:badLines', ...
                    'lineName ''%s'' not in configuredDiLines.', lineNameC);
            end
            if isempty(obj.diBuf_) || size(obj.diBuf_, 1) < nSamples
                error('tfp:hardware:NI6323_DAQ:noDigitalData', ...
                    ['Fewer than %d DI samples buffered (%d available). ' ...
                     'Ensure configureDigitalInput and readAnalogInput were ' ...
                     'called before readDigitalInput.'], ...
                    nSamples, size(obj.diBuf_, 1));
            end
            data = double(obj.diBuf_(1:nSamples, idx));
            obj.logEvent('readDigitalInput', struct( ...
                'lineName', lineNameC, 'nSamples', nSamples));
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
            %start Build combined AO+DO output matrix and start background session.
            %   Synthesizes DO pulse waveforms from stored digitalPulses_ specs
            %   and assembles all output columns in outputOrder_ order, as
            %   required by daq.createSession (legacy) mixed AO+DO sessions.
            obj.requireInitialized('start');
            nOut = numel(obj.outputOrder_);
            if nOut > 0
                if isempty(obj.aoData_)
                    error('tfp:hardware:NI6323_DAQ:noOutputData', ...
                        'queueAnalogOutput() must be called before start().');
                end
                nSamp   = size(obj.aoData_, 1);
                outData = zeros(nSamp, nOut);

                % Fill AO columns in outputOrder_ order.
                aoCol = 0;
                for i = 1:nOut
                    if strcmp(obj.outputOrder_(i).kind, 'ao')
                        aoCol = aoCol + 1;
                        if aoCol <= size(obj.aoData_, 2)
                            outData(:, i) = obj.aoData_(:, aoCol);
                        end
                    end
                end

                % Synthesize DO pulse waveforms from queued specs.
                for p = 1:numel(obj.digitalPulses_)
                    spec = obj.digitalPulses_(p);
                    for j = 1:numel(spec.lineNames)
                        slot    = obj.outputSlotForDOLine_(spec.lineNames{j});
                        onSamp  = max(1, round(spec.times(j) * obj.sampleRate) + 1);
                        offSamp = min(nSamp, ...
                            onSamp + round(spec.durations(j) * obj.sampleRate) - 1);
                        if onSamp <= offSamp
                            outData(onSamp:offSamp, slot) = 1;
                        end
                    end
                end

                obj.session_.queueOutputData(outData);  %LEGACY_API
            end
            % NI legacy session requires a DataAvailable listener before
            % startBackground() when the session has input channels.
            if ~isempty(obj.configuredAiChannels_)
                nAiChans = numel(obj.configuredAiChannels_);
                obj.aiBuf_ = zeros(0, nAiChans);
                obj.diBuf_ = zeros(0, numel(obj.configuredDiLines_));
                obj.aiListener_ = obj.session_.addlistener( ...  %LEGACY_API
                    'DataAvailable', @(src, evt) obj.onDataAvailable(evt, nAiChans));
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
            obj.diBuf_         = [];
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
                % Listener was registered in start() and may have already
                % filled aiBuf_ — do NOT reset it here or that data is lost.
                % start() resets the buffer; stop() clears it between trials.
                timeout = max(1.0, nSamples / obj.sampleRate * 3);  % ≥1 s
                t0      = tic;
                while size(obj.aiBuf_, 1) < nSamples && toc(t0) < timeout
                    pause(0.001);
                end
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
                if size(raw, 2) > nChans && ~isempty(obj.configuredDiLines_)
                    obj.diBuf_ = raw(:, nChans+1:end);
                end
            end

            obj.logEvent('readAnalogInput', struct( ...
                'nSamples', nSamples, 'nChans', nChans));
        end

        function sendDigitalPulse(obj, lineName, durationS)
            %sendDigitalPulse Immediately output a high-then-low digital pulse.
            %   lineName must be in configuredDoLines.  durationS > 0.
            %   The full session output vector (covering both AO and DO
            %   channels in addition order) is built from outputOrder_ so a
            %   mixed AO+DO session passes the correct shape to
            %   outputSingleScan.
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
            slot = obj.outputSlotForDOLine_(lineNameC);
            n    = numel(obj.outputOrder_);
            highVec       = zeros(1, n);
            highVec(slot) = 1;
            lowVec        = zeros(1, n);
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
                obj.outputOrder_(end+1) = struct('kind', 'ao', 'name', chNum);
            end
            slot   = obj.outputSlotForAOChannel_(chNum);
            n      = numel(obj.outputOrder_);
            outVec       = zeros(1, n);
            outVec(slot) = voltageV;
            obj.session_.outputSingleScan(outVec);  %LEGACY_API
            obj.logEvent('outputSingleAnalog', struct('channel', chNum, 'voltageV', voltageV));
        end

        function startContinuousSession(obj, cfg)
            %startContinuousSession Arm the single master-clock session for the experiment.
            %   Implements docs/SYNC_FRAME.md §4.1. Allocates an independent
            %   daq.createSession('ni') so its long-running clock does not
            %   collide with the per-trial session used by start()/stop().
            %
            %   cfg fields: sampleRate (req), aiChannels, aiRangeV,
            %     aoChannels, diLines, doLines, frameClockLine.
            obj.requireInitialized('startContinuousSession');
            if obj.contIsRunning_
                error('tfp:hardware:DAQ:alreadyRunning', ...
                    'startContinuousSession called while a session is already running.');
            end
            if ~isstruct(cfg)
                error('tfp:hardware:DAQ:badConfig', 'cfg must be a struct.');
            end
            sr = configField(cfg, 'sampleRate', []);
            if ~isnumeric(sr) || ~isscalar(sr) || ~isfinite(sr) || sr <= 0
                error('tfp:hardware:DAQ:badConfig', ...
                    'cfg.sampleRate must be a positive finite scalar (Hz).');
            end
            aiCh     = configField(cfg, 'aiChannels', []);
            aiRangeV = configField(cfg, 'aiRangeV',   []);
            aoCh     = configField(cfg, 'aoChannels', []);
            diLines  = configField(cfg, 'diLines',    {});
            doLines  = configField(cfg, 'doLines',    {});
            frameCl  = configField(cfg, 'frameClockLine', '');
            if ~isempty(diLines); diLines = cellstr(diLines); end
            if ~isempty(doLines); doLines = cellstr(doLines); end
            if ~isempty(frameCl) && ~any(strcmp(char(frameCl), diLines))
                error('tfp:hardware:DAQ:badConfig', ...
                    'cfg.frameClockLine ''%s'' must be present in cfg.diLines.', ...
                    char(frameCl));
            end

            try
                s = daq.createSession('ni');  %LEGACY_API
            catch ME
                error('tfp:hardware:NI6323_DAQ:driverNotFound', ...
                    ['Could not create NI session for continuous-session API. ' ...
                     'Original: %s'], ME.message);
            end
            s.Rate = sr;  %LEGACY_API
            % Run forever; we stop explicitly in stopContinuousSession.
            % %VERIFY IsContinuous semantics on PCIe-6323 + NI-DAQmx 19.5: with
            %   IsContinuous=true the session keeps clocking until session.stop().
            try
                s.IsContinuous = true;  %LEGACY_API
            catch
                % Older NI session subclasses expose this only after channels
                % are added; set again after channel addition (below).
            end

            for k = 1:numel(aiCh)
                ch = s.addAnalogInputChannel(obj.deviceName_, aiCh(k), 'Voltage');  %LEGACY_API
                if numel(aiRangeV) == 2
                    try, ch.Range = aiRangeV; catch, end  %LEGACY_API
                end
            end
            for k = 1:numel(aoCh)
                s.addAnalogOutputChannel(obj.deviceName_, aoCh(k), 'Voltage');  %LEGACY_API
            end
            for k = 1:numel(diLines)
                s.addDigitalChannel(obj.deviceName_, diLines{k}, 'InputOnly');  %LEGACY_API
            end
            for k = 1:numel(doLines)
                s.addDigitalChannel(obj.deviceName_, doLines{k}, 'OutputOnly');  %LEGACY_API
            end
            try, s.IsContinuous = true; catch, end  %LEGACY_API

            obj.contSession_   = s;
            obj.contCfg_       = cfg;
            obj.contNAi_       = numel(aiCh);
            obj.contNDi_       = numel(diLines);
            obj.contNAo_       = numel(aoCh);
            obj.contAiBuf_     = zeros(0, obj.contNAi_);
            obj.contDiBuf_     = zeros(0, obj.contNDi_);
            obj.contAoWritten_ = uint64(0);
            obj.contLineNames_ = struct( ...
                'aiChannels',     aiCh, ...
                'aoChannels',     aoCh, ...
                'diLines',        {diLines}, ...
                'doLines',        {doLines}, ...
                'frameClockLine', char(frameCl));

            if (obj.contNAi_ + obj.contNDi_) > 0
                obj.contListener_ = s.addlistener('DataAvailable', ...  %LEGACY_API
                    @(src, evt) obj.onContDataAvailable(evt));
            else
                obj.contListener_ = [];
            end

            obj.contSessionStart_ = datetime('now');
            obj.contStartTic_     = tic;
            % Arm. If AO is configured but no waveform queued yet, the session
            % still clocks AI/DI; AO output begins when queueClockedAO appends
            % samples. %VERIFY this on NI-DAQmx 19.5 — older drivers required at
            % least one queued AO sample before startBackground.
            s.startBackground();  %LEGACY_API
            obj.contIsRunning_ = true;
            obj.isRunning      = true;

            obj.logEvent('startContinuousSession', struct( ...
                'sampleRate', sr, 'nAi', obj.contNAi_, 'nAo', obj.contNAo_, ...
                'nDi', obj.contNDi_, 'nDo', numel(doLines), ...
                'frameClockLine', char(frameCl)));
        end

        function result = stopContinuousSession(obj)
            %stopContinuousSession Stop the master clock and return captured data.
            %   See docs/SYNC_FRAME.md §4.2 for the returned struct schema.
            if ~obj.contIsRunning_
                error('tfp:hardware:DAQ:notRunning', ...
                    'stopContinuousSession called before startContinuousSession.');
            end
            try
                obj.contSession_.stop();   %LEGACY_API
            catch
            end
            if ~isempty(obj.contListener_)
                try, delete(obj.contListener_); catch, end
                obj.contListener_ = [];
            end

            ai = obj.contAiBuf_;
            di = obj.contDiBuf_;
            % nSamplesTotal is the longest captured stream. When neither AI
            % nor DI is configured we fall back to the elapsed-tic estimate.
            if obj.contNAi_ > 0 || obj.contNDi_ > 0
                nTotal = uint64(max(size(ai, 1), size(di, 1)));
            else
                nTotal = uint64(round(toc(obj.contStartTic_) * obj.contCfg_.sampleRate));
            end

            result = struct( ...
                'aiData',               ai, ...
                'diData',               di, ...
                'aoSamplesWritten',     obj.contAoWritten_, ...
                'nSamplesTotal',        nTotal, ...
                'sampleRate',           obj.contCfg_.sampleRate, ...
                'sessionStartDatetime', obj.contSessionStart_, ...
                'lineNames',            obj.contLineNames_);

            try, obj.contSession_.release(); catch, end  %LEGACY_API
            obj.contSession_   = [];
            obj.contIsRunning_ = false;
            obj.isRunning      = false;
            obj.contAiBuf_     = [];
            obj.contDiBuf_     = [];

            obj.logEvent('stopContinuousSession', struct( ...
                'nSamplesTotal', nTotal, 'aoSamplesWritten', result.aoSamplesWritten));
        end

        function idx = currentSampleIndex(obj)
            %currentSampleIndex 1-based DAQ sample index (uint64).
            %   See docs/SYNC_FRAME.md §4.3. Returns the next sample to be
            %   acquired (= ScansAcquired + 1). When neither AI nor DI is
            %   configured, falls back to a tic-based estimate.
            if ~obj.contIsRunning_
                error('tfp:hardware:DAQ:notRunning', ...
                    'currentSampleIndex called with no active continuous session.');
            end
            scans = NaN;
            try
                scans = double(obj.contSession_.ScansAcquired);  %LEGACY_API
            catch
            end
            if ~isfinite(scans) || scans < 0
                scans = toc(obj.contStartTic_) * obj.contCfg_.sampleRate;
            end
            idx = uint64(floor(scans) + 1);
        end

        function startSampleIdx = queueClockedAO(obj, samples, rate, startTrigger)
            %queueClockedAO Queue a hardware-clocked AO waveform.
            %   See docs/SYNC_FRAME.md §4.4. Returns the DAQ sample index at
            %   which the first queued sample will be output — caller stores
            %   this as t_onset_daq_samples.
            if ~obj.contIsRunning_
                error('tfp:hardware:DAQ:notRunning', ...
                    'queueClockedAO called with no active continuous session.');
            end
            if nargin < 4 || isempty(startTrigger)
                startTrigger = 'immediate';
            end
            startTrigger = char(startTrigger);
            if strcmp(startTrigger, 'sync')
                error('tfp:hardware:DAQ:notImplemented', ...
                    'queueClockedAO startTrigger=''sync'' is reserved for a future round.');
            end
            if ~strcmp(startTrigger, 'immediate')
                error('tfp:hardware:DAQ:badConfig', ...
                    'startTrigger must be ''immediate'' or ''sync''; got ''%s''.', ...
                    startTrigger);
            end
            if ~isnumeric(rate) || ~isscalar(rate) || rate ~= obj.contCfg_.sampleRate
                error('tfp:hardware:DAQ:badRate', ...
                    'rate (%g) must equal the active session sampleRate (%g).', ...
                    rate, obj.contCfg_.sampleRate);
            end
            if ~isnumeric(samples) || ndims(samples) > 2 ...
                    || size(samples, 2) ~= obj.contNAo_
                error('tfp:hardware:DAQ:badShape', ...
                    'samples must be nSamples × %d numeric; got size [%s].', ...
                    obj.contNAo_, num2str(size(samples)));
            end

            % Anchor at the next clocked sample. With AO sharing the master
            % clock and no gaps between queued chunks, this equals the AO
            % output position. Acceptable rounding (one sample period) is
            % bounded by the spec.
            startSampleIdx = obj.currentSampleIndex();
            obj.contSession_.queueOutputData(samples);  %LEGACY_API
            obj.contAoWritten_ = obj.contAoWritten_ + uint64(size(samples, 1));

            obj.logEvent('queueClockedAO', struct( ...
                'nSamples',       size(samples, 1), ...
                'rate',           rate, ...
                'startTrigger',   startTrigger, ...
                'startSampleIdx', startSampleIdx));
        end

        function cleanup(obj)
            %cleanup Stop and release the NI-DAQmx session.
            if obj.contIsRunning_
                try
                    obj.contSession_.stop();  %LEGACY_API
                catch
                end
                if ~isempty(obj.contListener_)
                    try, delete(obj.contListener_); catch, end
                    obj.contListener_ = [];
                end
                try, obj.contSession_.release(); catch, end  %LEGACY_API
                obj.contSession_   = [];
                obj.contIsRunning_ = false;
            end
            if obj.isInitialized_ && ~isempty(obj.session_)
                try
                    if obj.isRunning
                        obj.session_.stop();  %LEGACY_API
                    end
                    if ~isempty(obj.aiListener_)
                        delete(obj.aiListener_);
                        obj.aiListener_ = [];
                    end
                    if ~isempty(obj.outputOrder_)
                        try
                            obj.session_.outputSingleScan( ...
                                zeros(1, numel(obj.outputOrder_)));  %LEGACY_API
                        catch
                        end
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
            obj.configuredDiLines_    = {};
            obj.outputOrder_       = struct('kind', {}, 'name', {});
            obj.aiRangeV_          = [];
            obj.aoData_            = [];
            obj.aiBuf_             = [];
            obj.diBuf_             = [];
            obj.digitalPulses_     = struct('lineNames', {}, 'times', {}, 'durations', {});
            obj.contCfg_           = struct([]);
            obj.contAiBuf_         = [];
            obj.contDiBuf_         = [];
            obj.contAoWritten_     = uint64(0);
            obj.contNAi_           = 0;
            obj.contNDi_           = 0;
            obj.contNAo_           = 0;
            obj.contSessionStart_  = NaT;
            obj.contStartTic_      = [];
            obj.contLineNames_     = struct([]);
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

        function onContDataAvailable(obj, evt)
            %onContDataAvailable Continuous-session listener.
            %   evt.Data columns are [AI(1..nAi) | DI(1..nDi)] in addition
            %   order (AO/DO are output-only and produce no columns).
            nAi = obj.contNAi_;
            nDi = obj.contNDi_;
            if nAi > 0
                obj.contAiBuf_ = [obj.contAiBuf_; evt.Data(:, 1:nAi)];  %#ok<AGROW>
            end
            if nDi > 0
                obj.contDiBuf_ = [obj.contDiBuf_; evt.Data(:, nAi+1:nAi+nDi)];  %#ok<AGROW>
            end
        end

        function onDataAvailable(obj, evt, nAiChans)
            %onDataAvailable DataAvailable listener; appends AI to aiBuf_, DI to diBuf_.
            nCols = size(evt.Data, 2);
            obj.aiBuf_ = [obj.aiBuf_; evt.Data(:, 1:min(nAiChans, nCols))];  %#ok<AGROW>
            if nCols > nAiChans && ~isempty(obj.configuredDiLines_)
                obj.diBuf_ = [obj.diBuf_; evt.Data(:, nAiChans+1:end)];  %#ok<AGROW>
            end
        end

        function slot = outputSlotForAOChannel_(obj, chNum)
            %outputSlotForAOChannel_ Find session-output-vector index for AO channel.
            for k = 1:numel(obj.outputOrder_)
                entry = obj.outputOrder_(k);
                if strcmp(entry.kind, 'ao') && isequal(entry.name, chNum)
                    slot = k;
                    return
                end
            end
            error('tfp:hardware:NI6323_DAQ:outputSlotMissing', ...
                'AO channel %g not found in session outputOrder_.', chNum);
        end

        function slot = outputSlotForDOLine_(obj, lineName)
            %outputSlotForDOLine_ Find session-output-vector index for DO line.
            for k = 1:numel(obj.outputOrder_)
                entry = obj.outputOrder_(k);
                if strcmp(entry.kind, 'do') && strcmp(entry.name, lineName)
                    slot = k;
                    return
                end
            end
            error('tfp:hardware:NI6323_DAQ:outputSlotMissing', ...
                'DO line ''%s'' not found in session outputOrder_.', lineName);
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
