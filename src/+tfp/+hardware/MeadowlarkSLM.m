classdef MeadowlarkSLM < tfp.hardware.PLM
    %MeadowlarkSLM DAQ-PC proxy for the Meadowlark 1K SLM on the SLM PC.
    %   The SLM lives on a separate Windows PC (PCIe + Blink SDK), running
    %   scripts/slm_pc_setup/slm_server.m (a repo clone + Blink install).
    %   This class implements the spec-not-pixels contract:
    %
    %     prepareDefocusSequence(dzListUm, sys)
    %       -> builds a flat mask SPEC (tfp.slm.buildMaskSpec) and sends it
    %          over msocket (default port 3046; note the direction reversal:
    %          the SLM PC is the SERVER, unlike every other lab link where
    %          the DAQ PC listens). The server recomputes the identical
    %          masks with the shared tfp.slm engine, uploads them via Blink
    %          in sequence order (= depth-group order), arms the requested
    %          trigger mode, and replies 'READY'.
    %
    %     advanceToIndex(idx)
    %       'ttl'      — pulses the injected ttlPulseFcn once per step
    %                    (port0/line8 "SLM trigger out" on the NI 6323),
    %                    then waits the LC settle time (3.4 ms + margin).
    %       'software' — sends 'ADV' per step and waits 'ADV_OK' (bring-up
    %                    fallback until the Blink audit confirms this HSP1K
    %                    unit's external-trigger sequencing).
    %
    %   Two-phase open (DLPC900_PLM pattern): the constructor only stores
    %   config; connect() opens the socket. connect(struct('mockTransport',
    %   true)) installs a canned-reply transport so the whole protocol layer
    %   is testable with zero hardware and zero sockets.
    %
    %   loadPattern (pixel masks) is intentionally NOT supported — pixels
    %   never cross the wire. Use prepareDefocusSequence.

    properties (SetAccess = protected)
        nRows         = 1024
        nCols         = 1024
        pitchX_um     = 17.0
        pitchY_um     = 17.0
        nPhaseStates  = 256
        lambda_nm     = 1038    % measured CARBIDE [CERT], not the 1030 setpoint
        isInitialized = false
    end

    properties (Access = private)
        % Link config
        host_         = ''
        port_         = 3046
        msocketPath_  = ''
        timeoutS_     = 10
        % Behaviour config
        triggerMode_  = 'software'   % 'ttl' | 'software' (config slm.trigger_mode)
        settleS_      = 0.0034       % Meadowlark LC response, handoff §6
        lutPath_      = ''
        wfcPath_      = ''
        % Runtime state
        sock_         = []           % msocket handle, or 'mock'
        state_        = 'idle'       % 'idle'|'connected'|'sequenced'|'armed'
        dzListUm_     = []
        seqIndex_     = 0
        armedMode_    = ''
        ttlPulseFcn_  = []
        mockReplies_  = {}           % mock transport: queued replies (FIFO)
        log_          = struct('timestamp', {}, 'eventType', {}, 'payload', {})
    end

    methods
        function obj = MeadowlarkSLM(config)
            %MeadowlarkSLM Construct + initialize (real-driver convention).
            if nargin < 1 || isempty(config)
                config = struct();
            end
            obj.initialize(config);
        end

        function initialize(obj, config)
            if ~isstruct(config)
                error('tfp:hardware:MeadowlarkSLM:badConfig', ...
                    'config must be a struct.');
            end
            obj.nRows        = tfp.util.configField(config, 'nRows',     1024);
            obj.nCols        = tfp.util.configField(config, 'nCols',     1024);
            obj.pitchX_um    = tfp.util.configField(config, 'pitch_um',  17.0);
            obj.pitchY_um    = obj.pitchX_um;
            obj.nPhaseStates = tfp.util.configField(config, 'nStates',   256);
            obj.lambda_nm    = tfp.util.configField(config, 'lambda_nm', 1038);

            obj.host_        = char(tfp.util.configField(config, 'host', ''));
            obj.port_        = double(tfp.util.configField(config, 'port', 3046));
            obj.msocketPath_ = char(tfp.util.configField(config, 'msocketPath', ''));
            obj.timeoutS_    = double(tfp.util.configField(config, 'timeoutS', 10));
            obj.triggerMode_ = lower(char(tfp.util.configField(config, ...
                                     'trigger_mode', 'software')));
            obj.settleS_     = double(tfp.util.configField(config, 'settle_s', 0.0034));
            obj.lutPath_     = char(tfp.util.configField(config, 'lut_file', ''));
            obj.wfcPath_     = char(tfp.util.configField(config, 'wfc_file', ''));
            if ~any(strcmp(obj.triggerMode_, {'ttl', 'software'}))
                error('tfp:hardware:MeadowlarkSLM:badTriggerMode', ...
                    'config.trigger_mode must be ''ttl'' or ''software''.');
            end

            obj.state_        = 'idle';
            obj.seqIndex_     = 0;
            obj.dzListUm_     = [];
            obj.armedMode_    = '';
            obj.isInitialized = true;
            obj.logEvent('initialize', config);
        end

        function connect(obj, options)
            %connect Open the msocket link to the SLM-PC server.
            %   connect(struct('mockTransport', true)) installs the canned
            %   transport for socket-free tests.
            if nargin < 2 || isempty(options)
                options = struct();
            end
            if tfp.util.configField(options, 'mockTransport', false)
                obj.sock_  = 'mock';
                obj.state_ = 'connected';
                obj.logEvent('connect', struct('mockTransport', true));
                return
            end
            if isempty(obj.host_)
                error('tfp:hardware:MeadowlarkSLM:missingHost', ...
                    'config.slm.host (SLM PC address) is required to connect.');
            end
            if ~isempty(obj.msocketPath_) && isfolder(obj.msocketPath_)
                addpath(obj.msocketPath_);
            end
            try
                % Lab msocket client call — the SLM PC runs mslisten(port).
                obj.sock_ = msconnect(obj.host_, obj.port_);
            catch ME
                error('tfp:hardware:MeadowlarkSLM:connectFailed', ...
                    'msconnect(%s, %d) failed: %s', obj.host_, obj.port_, ...
                    ME.message);
            end
            obj.state_ = 'connected';
            obj.logEvent('connect', struct('host', obj.host_, 'port', obj.port_));
        end

        function setTtlPulseFcn(obj, fcn)
            %setTtlPulseFcn Inject the TTL pulse callable (one pulse = one step).
            %   Experiments pass @() daq.sendDigitalPulse(line, pulse_s)
            %   with line = config.slm.trigger_line (port0/line8).
            if ~isempty(fcn) && ~isa(fcn, 'function_handle')
                error('tfp:hardware:MeadowlarkSLM:badPulseFcn', ...
                    'ttlPulseFcn must be a function handle or [].');
            end
            obj.ttlPulseFcn_ = fcn;
        end

        function loadPattern(obj, pattern) %#ok<INUSD>
            %loadPattern NOT SUPPORTED — pixels never cross the wire.
            error('tfp:hardware:MeadowlarkSLM:notSupported', ...
                ['MeadowlarkSLM ships mask SPECS, not pixels. Use ' ...
                 'prepareDefocusSequence(dzListUm, sys) instead.']);
        end

        function configureTrigger(obj)
            %configureTrigger Arm the config-selected trigger mode.
            obj.armSequenceTrigger(obj.triggerMode_);
        end

        function advancePattern(obj)
            %advancePattern Step one position forward (wrapping).
            obj.requireSequence('advancePattern');
            next = obj.seqIndex_ + 1;
            if next > numel(obj.dzListUm_)
                next = 1;
            end
            obj.advanceToIndex(next);
        end

        function status = getStatus(obj)
            status.state          = obj.state_;
            status.sequenceIndex  = obj.seqIndex_;
            status.nSequenceMasks = numel(obj.dzListUm_);
            status.triggerMode    = obj.armedMode_;
            status.connected      = ~isempty(obj.sock_);
        end

        function cleanup(obj)
            %cleanup Non-throwing teardown (lab convention).
            try
                if ~isempty(obj.sock_) && ~ischar(obj.sock_)
                    try, mssend(obj.sock_, 'BYE'); catch, end %#ok<TRYNC>
                    msclose(obj.sock_);
                end
            catch
            end
            obj.sock_      = [];
            obj.state_     = 'idle';
            obj.seqIndex_  = 0;
            obj.dzListUm_  = [];
            obj.armedMode_ = '';
            obj.isInitialized = false;
            obj.logEvent('cleanup', []);
        end

        % ============================================================
        % Defocus-sequence interface
        % ============================================================

        function tf = supportsDefocusSequence(obj) %#ok<MANU>
            tf = true;
        end

        function prepareDefocusSequence(obj, dzListUm, sys)
            obj.requireConnected('prepareDefocusSequence');
            if nargin < 3 || isempty(sys)
                error('tfp:hardware:MeadowlarkSLM:badSys', ...
                    'prepareDefocusSequence requires a sys struct (tfp.optics.buildDefocusSys).');
            end
            % Force device geometry from this object so both ends agree.
            sys.nRows    = obj.nRows;
            sys.nCols    = obj.nCols;
            sys.pitchXUm = obj.pitchX_um;
            sys.pitchYUm = obj.pitchY_um;
            sys.nStates  = obj.nPhaseStates;
            sys.lambdaNm = obj.lambda_nm;

            specOpts = struct('lutPath', obj.lutPath_, ...
                              'wfcPath', obj.wfcPath_, ...
                              'triggerMode', obj.triggerMode_);
            spec = tfp.slm.buildMaskSpec(dzListUm, sys, specOpts);

            reply = obj.sendAndWait(spec, 'READY');
            obj.dzListUm_ = double(dzListUm(:)');
            obj.seqIndex_ = 0;
            obj.state_    = 'sequenced';
            obj.logEvent('prepareDefocusSequence', struct( ...
                'nMasks', numel(obj.dzListUm_), 'reply', reply));
        end

        function armSequenceTrigger(obj, mode)
            obj.requireSequence('armSequenceTrigger');
            mode = lower(char(mode));
            if ~any(strcmp(mode, {'ttl', 'software'}))
                error('tfp:hardware:MeadowlarkSLM:badTriggerMode', ...
                    'mode must be ''ttl'' or ''software'' (got ''%s'').', mode);
            end
            if strcmp(mode, 'ttl') && isempty(obj.ttlPulseFcn_)
                error('tfp:hardware:MeadowlarkSLM:noPulseFcn', ...
                    'ttl mode requires an injected ttlPulseFcn (setTtlPulseFcn).');
            end
            obj.armedMode_ = mode;
            obj.state_     = 'armed';
            obj.logEvent('armSequenceTrigger', struct('mode', mode));
        end

        function advanceToIndex(obj, idx)
            obj.requireSequence('advanceToIndex');
            if isempty(obj.armedMode_)
                error('tfp:hardware:MeadowlarkSLM:notArmed', ...
                    'armSequenceTrigger must be called before advanceToIndex.');
            end
            N = numel(obj.dzListUm_);
            if ~isnumeric(idx) || ~isscalar(idx) || idx ~= round(idx) || ...
                    idx < 1 || idx > N
                error('tfp:hardware:MeadowlarkSLM:badIdx', ...
                    'idx must be an integer in 1..%d (got %g).', N, idx);
            end
            if idx == obj.seqIndex_
                return
            end
            current = obj.seqIndex_;
            if current == 0
                nSteps = idx;
            else
                nSteps = mod(idx - current, N);
            end
            for s = 1:nSteps
                if strcmp(obj.armedMode_, 'ttl')
                    obj.ttlPulseFcn_();
                else
                    obj.sendAndWait('ADV', 'ADV_OK');
                end
            end
            obj.seqIndex_ = idx;
            pause(obj.settleS_);   % LC settle budget (handoff §6: 3.4 ms)
            obj.logEvent('advanceToIndex', struct( ...
                'index', idx, 'nSteps', nSteps, 'mode', obj.armedMode_, ...
                'dzUm', obj.dzListUm_(idx), 'settleS', obj.settleS_));
        end

        function idx = getSequenceIndex(obj)
            idx = obj.seqIndex_;
        end

        function t = settleTimeS(obj)
            t = obj.settleS_;
        end

        function dz = getCurrentDefocusUm(obj)
            %getCurrentDefocusUm Commanded defocus of the active mask (um).
            if obj.seqIndex_ >= 1 && obj.seqIndex_ <= numel(obj.dzListUm_)
                dz = obj.dzListUm_(obj.seqIndex_);
            else
                dz = NaN;
            end
        end

        function blank(obj)
            %blank Command the server to write the flat (safe) mask.
            obj.requireConnected('blank');
            obj.sendAndWait('BLANK', 'BLANK_OK');
            obj.seqIndex_ = 0;
            obj.logEvent('blank', []);
        end

        function queueMockReply(obj, reply)
            %queueMockReply Test hook: push a canned reply for the mock transport.
            %   When the queue is empty the mock auto-acks with the expected
            %   reply; queue a wrong reply to exercise the error path.
            obj.mockReplies_{end+1} = reply;
        end

        function entries = getLog(obj)
            entries = obj.log_;
        end
    end

    methods (Access = private)
        function requireConnected(obj, caller)
            if isempty(obj.sock_)
                error('tfp:hardware:MeadowlarkSLM:notConnected', ...
                    'connect() must be called before %s().', caller);
            end
        end

        function requireSequence(obj, caller)
            if isempty(obj.dzListUm_)
                error('tfp:hardware:MeadowlarkSLM:noSequence', ...
                    'prepareDefocusSequence must be called before %s().', caller);
            end
        end

        function reply = sendAndWait(obj, message, expectedReply)
            %sendAndWait Send one message and block for the expected ack.
            obj.requireConnected('sendAndWait');
            obj.logEvent('send', struct('message', summarize(message)));

            if ischar(obj.sock_)   % mock transport
                if ~isempty(obj.mockReplies_)
                    reply = obj.mockReplies_{1};
                    obj.mockReplies_(1) = [];
                else
                    reply = expectedReply;   % auto-ack
                end
            else
                try
                    mssend(obj.sock_, message);
                catch ME
                    error('tfp:hardware:MeadowlarkSLM:sendFailed', ...
                        'mssend failed: %s', ME.message);
                end
                reply = [];
                tPoll = tic;
                while toc(tPoll) < obj.timeoutS_
                    reply = msrecv(obj.sock_, 0.2);   % [] on timeout slice
                    if ~isempty(reply), break; end
                end
                if isempty(reply)
                    error('tfp:hardware:MeadowlarkSLM:replyTimeout', ...
                        'No reply from SLM server within %.0f s (expected %s).', ...
                        obj.timeoutS_, expectedReply);
                end
            end

            if ~strcmp(char(reply), expectedReply)
                error('tfp:hardware:MeadowlarkSLM:badReply', ...
                    'SLM server replied ''%s'' (expected ''%s'').', ...
                    char(reply), expectedReply);
            end
        end

        function logEvent(obj, eventType, payload)
            entry.timestamp = datetime('now');
            entry.eventType = eventType;
            entry.payload   = payload;
            obj.log_(end+1) = entry;
        end
    end
end

% --- Local helper ---

function s = summarize(message)
%summarize Compact log form of an outbound message.
if ischar(message)
    s = message;
elseif isstruct(message)
    s = sprintf('spec(v%g, %d dz)', ...
        getFieldOr(message, 'version', NaN), ...
        numel(getFieldOr(message, 'dzListUm', [])));
else
    s = class(message);
end
end

function v = getFieldOr(s, name, default)
if isfield(s, name), v = s.(name); else, v = default; end
end
