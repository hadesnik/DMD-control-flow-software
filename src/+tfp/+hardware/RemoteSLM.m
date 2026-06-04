classdef RemoteSLM < handle
%RemoteSLM Controller that routes SLM commands to a local mock or a remote
%SLM PC.
%
%   RemoteSLM abstracts the difference between a loopback (in-process MockSLM)
%   and a remote SLM PC reached via the msocket library.  Experiment scripts
%   call the same methods regardless of the connection mode; the backend is
%   selected at construction time by config.connectionMode.
%
%   Connection modes
%   ----------------
%   'loopback' (or 'mock')
%       Builds a tfp.hardware.MockSLM inside this object and dispatches every
%       call directly via tfp.io.slmDispatch.  Suitable for offline
%       development and unit testing.
%
%   'msocket'
%       Connects to a remote SLM PC via the msocket library.  Expects a
%       'hello' handshake from the server after connect.  Sends JSON-like
%       struct packets via mssend; receives replies via msrecv.  The server
%       must be running slm_pc_server.m on the SLM PC.
%
%   Constructor/initialize
%   ----------------------
%   config fields (all optional):
%     connectionMode      'loopback'|'mock'|'msocket'   default 'loopback'
%     dims                [nCols nRows]                  default [1024 1024]
%     pitch_um            SLM pixel pitch (µm)           default 17
%     lambda_nm           design wavelength (nm)         default 1030
%     f_ft_um             focal length SLM→sample (µm)  default 16800
%     mag                 SLM→BFP magnification          default 1
%     n                   immersion index                default 1.33
%     diskRadius_um       TF disk radius (µm)            default 5
%     gsIters             GS iteration count             default 20
%     gsWeighted          logical                        default true
%     gsSeed              RNG seed                       default 0
%     maxCells            target cap                     default 20
%     addressableRadiusUm FOV radius (µm)                default Inf
%     minSpacingUm        minimum inter-target spacing   default 0
%     slmScanCalib_file   path to .mat calibration       default '' (identity)
%     efficiencyMap_file  path to .mat efficiency map    default '' (uniform)
%     slmPcIp             remote SLM PC IP               default '127.0.0.1'
%     slmPort             remote SLM PC port             default 3046
%     msocketPath         path to msocket\ directory     default ''
%     connectTimeoutS     socket accept timeout (s)      default 30
%
%   Public properties
%   -----------------
%     nRows, nCols, pitch_um  — SLM geometry (set from config)
%     isInitialized           — logical
%
%   See also: tfp.io.slmDispatch, tfp.hardware.MockSLM.

    properties (SetAccess = private)
        nRows         = 1024
        nCols         = 1024
        pitch_um      = 17
        isInitialized = false
    end

    properties (Access = private)
        mode_           % 'loopback' | 'msocket'
        localSlm_       % MockSLM instance (loopback mode)
        ctx_            % struct(params, calib, effMap) (loopback mode)
        sock_           % msocket handle (msocket mode)
        slmPcIp_
        slmPort_
        msocketPath_
        connectTimeoutS_
        log_            % struct array {timestamp, eventType, payload}
    end

    methods

        % ----------------------------------------------------------------- %
        function obj = RemoteSLM(config)
            %RemoteSLM Construct and (optionally) initialize from config.
            %   Defers network connections to initialize(); records config
            %   fields immediately so the object is inspectable before init.
            if nargin < 1 || isempty(config)
                config = struct();
            end
            obj.log_ = struct('timestamp', {}, 'eventType', {}, 'payload', {});

            % Cache fields that initialize() also reads so the object has
            % sensible public properties before initialize() is called.
            dims         = configField(config, 'dims', [1024 1024]);
            obj.nCols    = double(dims(1));
            obj.nRows    = double(dims(2));
            obj.pitch_um = double(configField(config, 'pitch_um', 17));
        end

        % ----------------------------------------------------------------- %
        function initialize(obj, config)
            %initialize Build the loopback mock or open the remote socket.
            %
            %   For 'loopback'/'mock': constructs and initializes a MockSLM
            %   with the same dims as this RemoteSLM, then builds a ctx
            %   struct (params + calib + effMap) for use by slmDispatch.
            %   maxCells / addressableRadiusUm / minSpacingUm are copied from
            %   config into mergedParams so validateSLMTargets can read them.
            %
            %   For 'msocket': adds msocketPath to path if non-empty, calls
            %   msconnect(ip, port) and waits for a hello handshake struct
            %   (field .op == 'hello') from the server.  Stores the socket
            %   handle in sock_ for later use.
            if nargin < 2 || isempty(config)
                config = struct();
            end

            rawMode = configField(config, 'connectionMode', 'loopback');
            if strcmpi(rawMode, 'mock')
                rawMode = 'loopback';
            end
            obj.mode_ = lower(rawMode);

            dims         = configField(config, 'dims', [1024 1024]);
            obj.nCols    = double(dims(1));
            obj.nRows    = double(dims(2));
            obj.pitch_um = double(configField(config, 'pitch_um', 17));

            obj.slmPcIp_         = configField(config, 'slmPcIp',          '127.0.0.1');
            obj.slmPort_         = configField(config, 'slmPort',           3046);
            obj.msocketPath_     = configField(config, 'msocketPath',       '');
            obj.connectTimeoutS_ = configField(config, 'connectTimeoutS',   30);

            switch obj.mode_

                % --------------------------------------------------------- %
                case 'loopback'
                    % 1. Build merged CGH params.
                    mergedParams = tfp.patterns.threeDShot.defaultParams(config);
                    mergedParams.maxCells            = double(configField(config, 'maxCells',            20));
                    mergedParams.addressableRadiusUm = double(configField(config, 'addressableRadiusUm', Inf));
                    mergedParams.minSpacingUm        = double(configField(config, 'minSpacingUm',        0));

                    % 2. Build calibration and efficiency map.
                    calibFile  = configField(config, 'slmScanCalib_file',  '');
                    effMapFile = configField(config, 'efficiencyMap_file', '');
                    calib  = tfp.patterns.threeDShot.loadSLMScanCalibration(calibFile);
                    effMap = tfp.patterns.threeDShot.loadEfficiencyMap(effMapFile);

                    obj.ctx_ = struct( ...
                        'params',  mergedParams, ...
                        'calib',   calib, ...
                        'effMap',  effMap);

                    % 3. Build and initialize MockSLM with the same dims.
                    obj.localSlm_ = tfp.hardware.MockSLM();
                    obj.localSlm_.initialize(config);

                % --------------------------------------------------------- %
                case 'msocket'
                    if ~isempty(obj.msocketPath_)
                        addpath(obj.msocketPath_);
                    end

                    % Connect to the remote SLM PC.
                    try
                        obj.sock_ = msconnect(obj.slmPcIp_, obj.slmPort_);
                    catch ME
                        error('tfp:hardware:RemoteSLM:connectFailed', ...
                            'msconnect to %s:%d failed: %s', ...
                            obj.slmPcIp_, obj.slmPort_, ME.message);
                    end

                    % Expect hello handshake from server.
                    try
                        hello = msrecv(obj.sock_, obj.connectTimeoutS_);
                    catch ME
                        try, msclose(obj.sock_); catch, end
                        obj.sock_ = [];
                        error('tfp:hardware:RemoteSLM:helloTimeout', ...
                            'No hello from SLM server within %.1f s: %s', ...
                            obj.connectTimeoutS_, ME.message);
                    end
                    if ~(isstruct(hello) && isfield(hello, 'op') && ...
                            strcmp(hello.op, 'hello'))
                        try, msclose(obj.sock_); catch, end
                        obj.sock_ = [];
                        error('tfp:hardware:RemoteSLM:badHello', ...
                            'Expected hello struct from SLM server; received: %s', ...
                            class(hello));
                    end
                    obj.logEvent('initialize', ...
                        struct('mode', 'msocket', 'ip', obj.slmPcIp_, ...
                               'port', obj.slmPort_));

                otherwise
                    error('tfp:hardware:RemoteSLM:unknownMode', ...
                        'connectionMode must be ''loopback'', ''mock'', or ''msocket''; got ''%s''.', ...
                        obj.mode_);
            end

            obj.isInitialized = true;
            obj.logEvent('initialize', struct('mode', obj.mode_));
        end

        % ----------------------------------------------------------------- %
        function res = projectTargets(obj, siCentroids)
            %projectTargets Send a set of ScanImage centroids to the SLM.
            %
            %   siCentroids: N×2 matrix of ScanImage scan-field coordinates
            %                in µm.
            %
            %   Returns:
            %     res.nAccepted               — targets accepted after validation
            %     res.perCellDeliveredFraction — CGH efficiency metric
            %     res.etaEffective             — overall diffraction efficiency
            %
            %   Errors:
            %     tfp:hardware:RemoteSLM:projectFailed — reply.ok is false.
            obj.checkInit();
            reply = obj.dispatch_('projectTargets', siCentroids);
            if ~reply.ok
                error('tfp:hardware:RemoteSLM:projectFailed', ...
                    'projectTargets failed: %s', ...
                    obj.safeErrorMsg_(reply));
            end
            res = struct( ...
                'nAccepted',                reply.nAccepted, ...
                'perCellDeliveredFraction', reply.perCellDeliveredFraction, ...
                'etaEffective',             reply.etaEffective);
            obj.logEvent('projectTargets', res);
        end

        % ----------------------------------------------------------------- %
        function blank(obj)
            %blank Blank the SLM (all-zero phase mask, presented immediately).
            obj.checkInit();
            reply = obj.dispatch_('blank', []);
            obj.logEvent('blank', struct('ok', reply.ok));
        end

        % ----------------------------------------------------------------- %
        function slmPower(obj, onTF)
            %slmPower Enable or disable the SLM drive voltage.
            %   onTF: logical scalar.
            obj.checkInit();
            reply = obj.dispatch_('slmPower', logical(onTF));
            obj.logEvent('slmPower', struct('on', logical(onTF), 'ok', reply.ok));
        end

        % ----------------------------------------------------------------- %
        function status = getStatus(obj)
            %getStatus Query and return the SLM device status struct.
            obj.checkInit();
            reply = obj.dispatch_('ping', []);
            if reply.ok && isfield(reply, 'status')
                status = reply.status;
            else
                status = struct();
            end
            obj.logEvent('getStatus', status);
        end

        % ----------------------------------------------------------------- %
        function cleanup(obj)
            %cleanup Tear down the SLM and close any open socket.
            %   Best-effort; never throws so it is safe in onCleanup.
            switch obj.mode_
                case 'loopback'
                    if ~isempty(obj.localSlm_)
                        try, obj.localSlm_.cleanup(); catch, end
                    end
                case 'msocket'
                    if ~isempty(obj.sock_)
                        try, msclose(obj.sock_); catch, end
                        obj.sock_ = [];
                    end
            end
            obj.isInitialized = false;
            obj.logEvent('cleanup', []);
        end

        % ----------------------------------------------------------------- %
        function shutdownServer(obj)
            %shutdownServer Send a 'shutdown' command to the remote SLM server.
            %   No-op in loopback mode.  In msocket mode sends the op and
            %   then closes the socket.
            if strcmp(obj.mode_, 'msocket') && ~isempty(obj.sock_)
                try
                    mssend(obj.sock_, struct('op', 'shutdown', 'payload', []));
                catch
                end
                try, msclose(obj.sock_); catch, end
                obj.sock_ = [];
                obj.isInitialized = false;
            end
            obj.logEvent('shutdownServer', struct('mode', obj.mode_));
        end

        % ----------------------------------------------------------------- %
        function slm = getLocalSlm(obj)
            %getLocalSlm Return the inner MockSLM (loopback mode only).
            %   Test hook: allows tests to inspect getActivePattern().
            %   Returns [] in msocket mode.
            if strcmp(obj.mode_, 'loopback')
                slm = obj.localSlm_;
            else
                slm = [];
            end
        end

        % ----------------------------------------------------------------- %
        function entries = getLog(obj)
            %getLog Return the in-memory event log.
            %   entries is a struct array with fields
            %   {timestamp, eventType, payload}.
            entries = obj.log_;
        end

    end % methods (public)

    % --------------------------------------------------------------------- %
    methods (Access = private)

        function checkInit(obj)
            if ~obj.isInitialized
                error('tfp:hardware:RemoteSLM:notInitialized', ...
                    'Call initialize() before using RemoteSLM.');
            end
        end

        % ----------------------------------------------------------------- %
        function reply = dispatch_(obj, op, payload)
            %dispatch_ Route op+payload to loopback or msocket backend.
            switch obj.mode_
                case 'loopback'
                    reply = tfp.io.slmDispatch(obj.localSlm_, obj.ctx_, op, payload);

                case 'msocket'
                    mssend(obj.sock_, struct('op', op, 'payload', payload));
                    reply = msrecv(obj.sock_, obj.connectTimeoutS_);
            end
        end

        % ----------------------------------------------------------------- %
        function msg = safeErrorMsg_(~, reply)
            if isfield(reply, 'error') && ~isempty(reply.error)
                msg = reply.error;
            else
                msg = '(no error message in reply)';
            end
        end

        % ----------------------------------------------------------------- %
        function logEvent(obj, eventType, payload)
            entry.timestamp = datetime('now');
            entry.eventType = eventType;
            entry.payload   = payload;
            obj.log_(end+1) = entry;
        end

    end % methods (private)
end

% --- Local helper ---
function value = configField(config, name, default)
if isstruct(config) && isfield(config, name) && ~isempty(config.(name))
    value = config.(name);
else
    value = default;
end
end
