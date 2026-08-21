classdef ScanImageCalibBridge < handle
    %ScanImageCalibBridge Drive ScanImage for calibration, from the DAQ PC.
    %
    %   The client half of scripts/imaging_pc_setup/si_calib_helper.m
    %   (port 3048). ScanImage lives in its own MATLAB on the imaging PC and
    %   nothing outside that process can reach hSI, so the DAQ PC asks over
    %   msocket — the same arrangement, and the same wire discipline, as
    %   tfp.hardware.RelayZStage and si_motor_helper on 3047.
    %
    %   WHY THIS EXISTS. Without it, three steps of the bringup are "walk to
    %   the other PC, set a pixel count, walk back": section 4b needs a
    %   non-square raster, 4c needs a commanded region, 6b needs per-plane
    %   brightness after every z step. A guided procedure that sends the
    %   operator across the room mid-measurement is not a guided procedure.
    %
    %   WHAT IT IS NOT. It does not modify ScanImage internals and it is not
    %   an experiment data path: volumes come back as bare numeric arrays
    %   over a socket sized for calibration, not for acquisition.
    %
    %   Wire format (bare numeric vectors only):
    %     [1 nFast nSlow]  set pixel counts     reply [0]
    %     [2 0]            enter Focus          reply [0]
    %     [3 0]            abort                reply [0]
    %     [4 nPlanes]      plane brightness     reply [0 b1..bN]
    %     [5 nPlanes]      grab a volume        reply [0 nRows nCols nFrames pixels...]
    %     [6 x y w h]      command an mROI      reply [0]
    %     [7 0]            report config        reply [0 nFast nSlow nSlices zoom]
    %     [99 0]           shutdown the helper  reply [0]
    %   A reply whose first element is non-zero is an error code.
    %
    %   connect(struct('mockTransport', true)) keeps the protocol testable
    %   without sockets: an internal emulator answers with the right shapes.
    %
    %   See also tfp.hardware.RelayZStage, docs/PORTS.md,
    %   scripts/imaging_pc_setup/si_calib_helper.m.

    properties (SetAccess = protected)
        isInitialized = false
    end

    properties (Access = private)
        host_        = ''
        port_        = 3048
        msocketPath_ = ''
        timeoutS_    = 20
        sock_        = []      % msocket handle, or 'mock'
        mockState_   = struct('nFast', 512, 'nSlow', 256, 'nSlices', 3, ...
                              'zoom', 1, 'nRows', 64, 'nCols', 64)
        log_         = struct('timestamp', {}, 'eventType', {}, 'payload', {})
    end

    methods
        function obj = ScanImageCalibBridge(config)
            if nargin >= 1 && ~isempty(config)
                obj.initialize(config);
            end
        end

        function initialize(obj, config)
            if ~isstruct(config)
                error('tfp:hardware:ScanImageCalibBridge:badConfig', ...
                    'config must be a struct.');
            end
            obj.host_        = char(tfp.util.configField(config, 'host', ''));
            obj.port_        = double(tfp.util.configField(config, 'calib_port', 3048));
            obj.msocketPath_ = char(tfp.util.configField(config, 'msocketPath', ''));
            obj.timeoutS_    = double(tfp.util.configField(config, 'timeoutS', 20));
            obj.isInitialized = true;
            obj.logEvent('initialize', config);
        end

        function connect(obj, options)
            %connect Open the link, or do nothing if it is already open.
            if nargin < 2 || isempty(options), options = struct(); end
            if ~isempty(obj.sock_)
                return
            end
            if tfp.util.configField(options, 'mockTransport', false)
                obj.sock_ = 'mock';
                obj.logEvent('connect', struct('mockTransport', true));
                return
            end
            if isempty(obj.host_)
                error('tfp:hardware:ScanImageCalibBridge:missingHost', ...
                    ['scanimage.host (imaging PC address) is required. ' ...
                     'Without it the calibration helper cannot be reached and ' ...
                     'ScanImage must be driven by hand.']);
            end
            if ~isempty(obj.msocketPath_) && isfolder(obj.msocketPath_)
                addpath(obj.msocketPath_);
            end
            try
                obj.sock_ = msconnect(obj.host_, obj.port_);
            catch ME
                error('tfp:hardware:ScanImageCalibBridge:connectFailed', ...
                    ['msconnect(%s, %d) failed: %s. Start si_calib_helper in ' ...
                     'the ScanImage MATLAB on the imaging PC.'], ...
                    obj.host_, obj.port_, ME.message);
            end
            obj.logEvent('connect', struct('host', obj.host_, 'port', obj.port_));
        end

        function tf = isConnected(obj)
            tf = ~isempty(obj.sock_);
        end

        function disconnect(obj)
            %disconnect Close the link. Never throws — teardown must not
            %   take a session down with it (the lab convention).
            try
                if ~isempty(obj.sock_) && ~ischar(obj.sock_)
                    msclose(obj.sock_);
                end
            catch
            end
            obj.sock_ = [];
            obj.logEvent('disconnect', []);
        end

        % --- documented operations -------------------------------------

        function setPixelCounts(obj, nFast, nSlow)
            %setPixelCounts Pixels per line and lines per frame.
            %   Refuses a square count: section 4b's whole method is that the
            %   raster rectangle's LONG axis identifies the fast (resonant)
            %   axis, and a square frame destroys that information in a way
            %   nothing downstream can recover.
            if nFast == nSlow
                error('tfp:hardware:ScanImageCalibBridge:squarePixelCount', ...
                    ['a square pixel count (%d x %d) leaves the fast axis ' ...
                     'unidentifiable in the camera''s view of the raster. ' ...
                     'Use e.g. 512 x 256.'], nFast, nSlow);
            end
            obj.request([1 nFast nSlow], 0);
        end

        function startFocus(obj)
            obj.request([2 0], 0);
        end

        function abort(obj)
            obj.request([3 0], 0);
        end

        function b = planeBrightness(obj, nPlanes)
            %planeBrightness 1 x nPlanes mean brightness, one per imaging plane.
            %   This is the planeBrightnessFcn that tfp.calibration.calibrateEtlPlanes
            %   requires, in its live form.
            if nargin < 2 || isempty(nPlanes)
                cfg = obj.config();
                nPlanes = cfg.nSlices;
            end
            reply = obj.request([4 nPlanes], nPlanes);
            b = reply(2:end);
        end

        function stack = grabStack(obj, nPlanes)
            %grabStack One plane-interleaved volume as a numeric array.
            if nargin < 2 || isempty(nPlanes)
                cfg = obj.config();
                nPlanes = cfg.nSlices;
            end
            reply = obj.request([5 nPlanes], 3);
            nRows = reply(2); nCols = reply(3); nFrames = reply(4);
            expect = nRows * nCols * nFrames;
            if numel(reply) - 4 ~= expect
                error('tfp:hardware:ScanImageCalibBridge:truncatedStack', ...
                    ['expected %d pixels for a %dx%dx%d volume but got %d. ' ...
                     'The volume is probably too large for one message — ' ...
                     'reduce the pixel count for calibration.'], ...
                    expect, nRows, nCols, nFrames, numel(reply) - 4);
            end
            stack = reshape(reply(5:end), [nRows, nCols, nFrames]);
        end

        function commandRoi(obj, xUm, yUm, wUm, hUm)
            %commandRoi Centre a small scan region at a sample position.
            obj.request([6 xUm yUm wUm hUm], 0);
        end

        function cfg = config(obj)
            %config What ScanImage is currently set to.
            reply = obj.request([7 0], 4);
            cfg = struct('nFast', reply(2), 'nSlow', reply(3), ...
                'nSlices', reply(4), 'zoom', reply(5));
        end

        function shutdownHelper(obj)
            %shutdownHelper Ask the helper to exit its loop, then disconnect.
            try, obj.request([99 0], 0); catch, end
            obj.disconnect();
        end

        function entries = getLog(obj)
            entries = obj.log_;
        end
    end

    % =======================================================================
    methods (Access = private)

        function reply = request(obj, message, nExtra)
            %request One round trip, with the error code turned into an error.
            if isempty(obj.sock_)
                error('tfp:hardware:ScanImageCalibBridge:notConnected', ...
                    'connect() first — si_calib_helper must be running on the imaging PC.');
            end
            if ischar(obj.sock_)
                reply = obj.mockReply(message);
            else
                mssend(obj.sock_, double(message));
                reply = msrecv(obj.sock_, obj.timeoutS_);
                if isempty(reply)
                    error('tfp:hardware:ScanImageCalibBridge:replyTimeout', ...
                        ['no reply to opcode %d within %g s. The helper prints ' ...
                         'every command it receives — check its console.'], ...
                        message(1), obj.timeoutS_);
                end
            end
            if ~isnumeric(reply) || isempty(reply)
                error('tfp:hardware:ScanImageCalibBridge:badReply', ...
                    'malformed reply to opcode %d.', message(1));
            end
            if reply(1) ~= 0
                error('tfp:hardware:ScanImageCalibBridge:helperError', ...
                    ['the imaging-PC helper returned error code %d for opcode ' ...
                     '%d. The detail is printed on its console.'], ...
                    reply(1), message(1));
            end
            if numel(reply) - 1 < nExtra
                error('tfp:hardware:ScanImageCalibBridge:shortReply', ...
                    'opcode %d returned %d values, expected at least %d.', ...
                    message(1), numel(reply) - 1, nExtra);
            end
            obj.logEvent('request', struct('opcode', message(1), ...
                'nReply', numel(reply)));
        end

        function reply = mockReply(obj, message)
            %mockReply The socket-free emulator, for protocol tests.
            %   Answers with the right SHAPES and nothing meaningful: a test
            %   that needed real pixel values would be testing the emulator.
            s = obj.mockState_;
            switch message(1)
                case 1
                    obj.mockState_.nFast = message(2);
                    obj.mockState_.nSlow = message(3);
                    reply = 0;
                case {2, 3, 6}
                    reply = 0;
                case 4
                    reply = [0, zeros(1, message(2))];
                case 5
                    n = message(2);
                    reply = [0, s.nRows, s.nCols, n, zeros(1, s.nRows * s.nCols * n)];
                case 7
                    reply = [0, s.nFast, s.nSlow, s.nSlices, s.zoom];
                case 99
                    reply = 0;
                otherwise
                    reply = -3;
            end
        end

        function logEvent(obj, eventType, payload)
            obj.log_(end+1) = struct('timestamp', datetime('now'), ...
                'eventType', eventType, 'payload', {payload});
        end
    end
end
