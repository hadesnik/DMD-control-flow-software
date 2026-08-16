classdef RelayZStage < tfp.hardware.ZStage
    %RelayZStage Z axis relayed through the imaging PC (MP-285 stays put).
    %   The MP-285 is serial-connected to the imaging PC; rather than
    %   re-cable, this backend sends bare-vector commands over msocket to
    %   scripts/imaging_pc_setup/si_motor_helper.m (port 3047), which moves
    %   the motor via ScanImage's hSI.hMotors in the MATLAB process where
    %   hSI actually lives (the evalin('base') lesson — see
    %   docs/SYNC_EPISODIC.md and the bridge helpers).
    %
    %   Wire format (bare numeric vectors only — msocket-safe):
    %     request  [1 zUm]  moveToUm       reply [0]      (0 = ok)
    %     request  [2 0]    getPositionUm  reply [0 zUm]
    %     request  [3 dzUm] moveRelativeUm reply [0]
    %   Any reply with first element ~= 0 is an error code; the helper
    %   prints the detail on the imaging PC console.
    %
    %   connect(struct('mockTransport', true)) keeps the protocol testable
    %   without sockets (an internal position emulates the motor).

    properties (SetAccess = protected)
        isInitialized = false
    end

    properties (Access = private)
        host_        = ''
        port_        = 3047
        msocketPath_ = ''
        timeoutS_    = 15
        sock_        = []     % msocket handle, or 'mock'
        mockZUm_     = 0      % mock-transport position
        log_         = struct('timestamp', {}, 'eventType', {}, 'payload', {})
    end

    methods
        function obj = RelayZStage(config)
            if nargin >= 1 && ~isempty(config)
                obj.initialize(config);
            end
        end

        function initialize(obj, config)
            if ~isstruct(config)
                error('tfp:hardware:RelayZStage:badConfig', ...
                    'config must be a struct.');
            end
            obj.host_        = char(tfp.util.configField(config, 'host', ''));
            obj.port_        = double(tfp.util.configField(config, 'relay_port', 3047));
            obj.msocketPath_ = char(tfp.util.configField(config, 'msocketPath', ''));
            obj.timeoutS_    = double(tfp.util.configField(config, 'timeoutS', 15));
            obj.isInitialized = true;
            obj.logEvent('initialize', config);
        end

        function connect(obj, options)
            %connect Open the msocket link to si_motor_helper on the imaging PC.
            if nargin < 2 || isempty(options)
                options = struct();
            end
            if tfp.util.configField(options, 'mockTransport', false)
                obj.sock_ = 'mock';
                obj.logEvent('connect', struct('mockTransport', true));
                return
            end
            if isempty(obj.host_)
                error('tfp:hardware:RelayZStage:missingHost', ...
                    'config.zstage host (imaging PC address) is required.');
            end
            if ~isempty(obj.msocketPath_) && isfolder(obj.msocketPath_)
                addpath(obj.msocketPath_);
            end
            try
                obj.sock_ = msconnect(obj.host_, obj.port_);
            catch ME
                error('tfp:hardware:RelayZStage:connectFailed', ...
                    'msconnect(%s, %d) failed: %s — is si_motor_helper running?', ...
                    obj.host_, obj.port_, ME.message);
            end
            obj.logEvent('connect', struct('host', obj.host_, 'port', obj.port_));
        end

        function moveToUm(obj, zUm)
            obj.requireConnected('moveToUm');
            obj.roundTrip([1, double(zUm)]);
            obj.logEvent('moveToUm', struct('zUm', double(zUm)));
        end

        function zUm = getPositionUm(obj)
            obj.requireConnected('getPositionUm');
            reply = obj.roundTrip([2, 0]);
            if numel(reply) < 2
                error('tfp:hardware:RelayZStage:badReply', ...
                    'getPositionUm reply missing position value.');
            end
            zUm = double(reply(2));
        end

        function moveRelativeUm(obj, dzUm)
            obj.requireConnected('moveRelativeUm');
            obj.roundTrip([3, double(dzUm)]);
            obj.logEvent('moveRelativeUm', struct('dzUm', double(dzUm)));
        end

        function status = getStatus(obj)
            status.connected = ~isempty(obj.sock_);
            status.zUm       = NaN;
            try
                if status.connected
                    status.zUm = obj.getPositionUm();
                end
            catch
            end
        end

        function cleanup(obj)
            try
                if ~isempty(obj.sock_) && ~ischar(obj.sock_)
                    msclose(obj.sock_);
                end
            catch
            end
            obj.sock_ = [];
            obj.isInitialized = false;
            obj.logEvent('cleanup', []);
        end

        function entries = getLog(obj)
            entries = obj.log_;
        end
    end

    methods (Access = private)
        function requireConnected(obj, caller)
            if ~obj.isInitialized || isempty(obj.sock_)
                error('tfp:hardware:RelayZStage:notConnected', ...
                    'initialize() + connect() must be called before %s().', ...
                    caller);
            end
        end

        function reply = roundTrip(obj, request)
            if ischar(obj.sock_)   % mock transport
                switch request(1)
                    case 1, obj.mockZUm_ = request(2);          reply = 0;
                    case 2, reply = [0, obj.mockZUm_];
                    case 3, obj.mockZUm_ = obj.mockZUm_ + request(2); reply = 0;
                    otherwise, reply = -1;
                end
            else
                try
                    mssend(obj.sock_, request);
                catch ME
                    error('tfp:hardware:RelayZStage:sendFailed', ...
                        'mssend failed: %s', ME.message);
                end
                reply = [];
                t0 = tic;
                while toc(t0) < obj.timeoutS_
                    reply = msrecv(obj.sock_, 0.2);
                    if ~isempty(reply), break; end
                end
                if isempty(reply)
                    error('tfp:hardware:RelayZStage:replyTimeout', ...
                        'No reply from si_motor_helper within %.0f s.', ...
                        obj.timeoutS_);
                end
            end
            if isempty(reply) || reply(1) ~= 0
                error('tfp:hardware:RelayZStage:helperError', ...
                    'si_motor_helper returned error code %g (see imaging PC console).', ...
                    reply(1));
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
