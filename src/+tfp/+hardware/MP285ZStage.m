classdef MP285ZStage < tfp.hardware.ZStage
    %MP285ZStage Sutter MP-285 axis over direct serial from the DAQ PC.
    %   Serves two mounting geometries, selected by config `mount`:
    %     'objective' (DEFAULT) — the rig MP-285 moves the Sutter MOM
    %         objective; reached from the DAQ PC when the operator flips
    %         the manual serial switch box (its home position is the
    %         imaging PC — use RelayZStage there instead).
    %     'sample' (second option, see BRINGUP_GUIDE §5 Option B) — a
    %         spare MP-285 carrying the substage Basler camera + the
    %         fluorescent slide as ONE RIGID UNIT; the objective stays
    %         fixed. Fully DAQ-PC-local (no si_motor_helper), and the
    %         camera stays focused on the film through every
    %         through-focus sweep.
    %
    %   Sign: the ZStage contract is "+z = deeper focus into sample".
    %   Which RAW MP-285 direction that is depends on the mount (the two
    %   mounts are opposite for the same raw axis), so it is a config key:
    %   `direction_sign` (+1|-1, default +1), applied to the Z element
    %   only at the um<->usteps boundary. Bench-check per mount — see the
    %   sign section of docs/mp285-protocol-audit.md.
    %
    %   XY: commanded lateral moves (moveToXYUm) are GATED to the sample
    %   mount — on the objective mount they would translate the MOM
    %   objective. On every Z move X/Y are read and echoed back unchanged
    %   so the stage never translates laterally by accident. XY values are
    %   RAW stage frame (no sign key); getPositionXYZUm mixes frames
    %   deliberately: [x_raw, y_raw, z_contract].
    %
    %   Protocol framing implements the MP-285 manual's binary command set
    %   — %VERIFY every item in docs/mp285-protocol-audit.md against the
    %   unit's manual + a bench check BEFORE first hardware use:
    %     move:  'm' + int32 x,y,z (usteps, little-endian) + CR; unit
    %            replies CR when the move completes (this is what makes
    %            moveToUm blocking).
    %     read:  'c' + CR; unit replies 3x int32 usteps + CR.
    %     usteps-per-um depends on the installed lead screw / resolution
    %     mode — config usteps_per_um (default 25, i.e. 0.04 um/ustep)
    %     MUST be checked against the unit (audit item #1), and is assumed
    %     identical on all three axes (audit item #7).
    %
    %   Config: serial_port ('COM5'), baud (9600), usteps_per_um (25),
    %           timeoutS (10), mount ('objective'|'sample'),
    %           direction_sign (+1|-1).
    %   Test-only config: mockTransport (true -> in-memory emulated
    %           controller, no serial port opened; the seam that makes the
    %           byte framing / sign / XY logic unit-testable),
    %           mockStartUsteps ([x y z] raw usteps, default [0 0 0]).

    properties (SetAccess = protected)
        isInitialized = false
    end

    properties (Access = private)
        port_          = ''
        baud_          = 9600
        ustepsPerUm_   = 25
        timeoutS_      = 10
        mount_         = 'objective'
        directionSign_ = 1
        sp_            = []    % serialport | legacy serial | 'mock'
        useLegacy_     = false % true when using the pre-R2019b serial API
        mockPosUsteps_ = [0 0 0]     % emulated controller state (raw usteps)
        mockRxQueue_   = uint8([])   % bytes the mock "device" has sent us
        mockTxBuf_     = uint8([])   % bytes we have sent the mock "device"
        log_           = struct('timestamp', {}, 'eventType', {}, 'payload', {})
    end

    methods
        function obj = MP285ZStage(config)
            if nargin >= 1 && ~isempty(config)
                obj.initialize(config);
            end
        end

        function initialize(obj, config)
            if ~isstruct(config)
                error('tfp:hardware:MP285ZStage:badConfig', ...
                    'config must be a struct.');
            end
            obj.port_        = char(tfp.util.configField(config, 'serial_port', 'COM5'));
            obj.baud_        = double(tfp.util.configField(config, 'baud', 9600));
            obj.ustepsPerUm_ = double(tfp.util.configField(config, 'usteps_per_um', 25));
            obj.timeoutS_    = double(tfp.util.configField(config, 'timeoutS', 10));

            mount = lower(char(tfp.util.configField(config, 'mount', 'objective')));
            if ~ismember(mount, {'objective', 'sample'})
                error('tfp:hardware:MP285ZStage:badMount', ...
                    'mount must be ''objective'' or ''sample'', got ''%s''.', mount);
            end
            obj.mount_ = mount;

            dirSign = tfp.util.configField(config, 'direction_sign', 1);
            if ~isnumeric(dirSign) || ~isscalar(dirSign) || ~ismember(dirSign, [1 -1])
                error('tfp:hardware:MP285ZStage:badDirectionSign', ...
                    'direction_sign must be +1 or -1.');
            end
            obj.directionSign_ = double(dirSign);

            % Mock transport: emulate the controller in-memory (same idiom
            % as RelayZStage's mockTransport). Must short-circuit BEFORE
            % the serial open — no port exists in tests.
            if tfp.util.configField(config, 'mockTransport', false)
                start = double(tfp.util.configField(config, 'mockStartUsteps', [0 0 0]));
                if numel(start) ~= 3 || ~all(isfinite(start))
                    error('tfp:hardware:MP285ZStage:badConfig', ...
                        'mockStartUsteps must be 3 finite values.');
                end
                obj.mockPosUsteps_ = start(:)';
                obj.mockRxQueue_   = uint8([]);
                obj.mockTxBuf_     = uint8([]);
                obj.sp_            = 'mock';
                obj.useLegacy_     = false;
                obj.isInitialized  = true;
                obj.logEvent('initialize', struct('port', obj.port_, ...
                    'mount', obj.mount_, 'directionSign', obj.directionSign_, ...
                    'mockTransport', true));
                return
            end

            % serialport is R2019b+; fall back to the legacy serial API on
            % older releases (same dual-path style as fitAffineCalib's
            % fitgeotrans handling).
            try
                obj.sp_ = serialport(obj.port_, obj.baud_, ...
                    'Timeout', obj.timeoutS_);
                obj.useLegacy_ = false;
            catch MEnew
                try
                    obj.sp_ = serial(obj.port_, 'BaudRate', obj.baud_, ...
                        'Timeout', obj.timeoutS_); %#ok<SERIAL>
                    fopen(obj.sp_);
                    obj.useLegacy_ = true;
                catch MEold
                    error('tfp:hardware:MP285ZStage:openFailed', ...
                        'Could not open %s (serialport: %s; serial: %s).', ...
                        obj.port_, MEnew.message, MEold.message);
                end
            end
            obj.isInitialized = true;
            obj.logEvent('initialize', struct('port', obj.port_, ...
                'baud', obj.baud_, 'ustepsPerUm', obj.ustepsPerUm_, ...
                'mount', obj.mount_, 'directionSign', obj.directionSign_));
        end

        function moveToUm(obj, zUm)
            obj.requireInitialized('moveToUm');
            if ~isnumeric(zUm) || ~isscalar(zUm) || ~isfinite(zUm)
                error('tfp:hardware:MP285ZStage:badZ', ...
                    'zUm must be a finite numeric scalar.');
            end
            % Read current x/y/z so only z changes (audit item #3: the 'm'
            % command is absolute 3-axis — x/y MUST be echoed back).
            % direction_sign applies to the Z ELEMENT only; negating the
            % whole vector would command mirrored X/Y positions.
            xyz = obj.readPositionUsteps();
            xyz(3) = round(obj.directionSign_ * double(zUm) * obj.ustepsPerUm_);
            obj.writeBytes([uint8('m'), typecast(int32(xyz), 'uint8'), uint8(13)]);
            obj.waitForCr('moveToUm');   % CR on completion = blocking move
            obj.logEvent('moveToUm', struct('zUm', double(zUm)));
        end

        function zUm = getPositionUm(obj)
            obj.requireInitialized('getPositionUm');
            xyz = obj.readPositionUsteps();
            zUm = obj.directionSign_ * double(xyz(3)) / obj.ustepsPerUm_;
        end

        function moveRelativeUm(obj, dzUm)
            obj.moveToUm(obj.getPositionUm() + double(dzUm));
        end

        function posUm = getPositionXYZUm(obj)
            %getPositionXYZUm [x y z] um. X/Y are RAW stage frame; Z is the
            %   signed ZStage-contract frame (element 3 == getPositionUm()).
            %   Ungated — reads are harmless on either mount. Pass this as
            %   options.stagePositionUm to the lateral calibrations so
            %   composeCalibration can trip its stage-mismatch warning.
            obj.requireInitialized('getPositionXYZUm');
            xyz = obj.readPositionUsteps();
            posUm = [xyz(1) / obj.ustepsPerUm_, ...
                     xyz(2) / obj.ustepsPerUm_, ...
                     obj.directionSign_ * xyz(3) / obj.ustepsPerUm_];
        end

        function moveToXYUm(obj, xUm, yUm)
            %moveToXYUm Absolute lateral move (raw stage frame), blocking;
            %   Z is read and echoed back unchanged. SAMPLE MOUNT ONLY —
            %   on the objective mount this would translate the MOM
            %   objective, so it is refused.
            obj.requireInitialized('moveToXYUm');
            if ~strcmp(obj.mount_, 'sample')
                error('tfp:hardware:MP285ZStage:xyRequiresSampleMount', ...
                    ['XY moves are only allowed with zstage.mount=''sample'' ' ...
                     '— on the objective mount this would translate the ' ...
                     'MOM objective.']);
            end
            if ~isnumeric(xUm) || ~isscalar(xUm) || ~isfinite(xUm) || ...
               ~isnumeric(yUm) || ~isscalar(yUm) || ~isfinite(yUm)
                error('tfp:hardware:MP285ZStage:badXY', ...
                    'xUm and yUm must be finite numeric scalars.');
            end
            xyz = obj.readPositionUsteps();
            xyz(1) = round(double(xUm) * obj.ustepsPerUm_);
            xyz(2) = round(double(yUm) * obj.ustepsPerUm_);
            obj.writeBytes([uint8('m'), typecast(int32(xyz), 'uint8'), uint8(13)]);
            obj.waitForCr('moveToXYUm');
            obj.logEvent('moveToXYUm', struct('xUm', double(xUm), 'yUm', double(yUm)));
        end

        function id = rulerId(obj)
            %rulerId Provenance incl. mount/sign/port so composeZCalibration
            %   distinguishes two MP-285 units (or one unit re-mounted).
            id = sprintf('%s(mount=%s,sign=%+d,port=%s)', ...
                class(obj), obj.mount_, obj.directionSign_, obj.port_);
        end

        function status = getStatus(obj)
            status.port          = obj.port_;
            status.mount         = obj.mount_;
            status.directionSign = obj.directionSign_;
            status.zUm           = NaN;
            status.xyzUsteps     = NaN(1, 3);   % raw device frame (debugging)
            try
                status.xyzUsteps = obj.readPositionUsteps();
                status.zUm = obj.directionSign_ * status.xyzUsteps(3) / obj.ustepsPerUm_;
            catch
            end
        end

        function cleanup(obj)
            try
                if ~isempty(obj.sp_)
                    if obj.useLegacy_
                        fclose(obj.sp_);
                        delete(obj.sp_);
                    end
                    obj.sp_ = [];
                end
            catch
            end
            obj.isInitialized = false;
            obj.logEvent('cleanup', []);
        end

        function entries = getLog(obj)
            entries = obj.log_;
        end
    end

    methods (Access = private)
        function requireInitialized(obj, caller)
            if ~obj.isInitialized
                error('tfp:hardware:MP285ZStage:notInitialized', ...
                    'initialize() must be called before %s().', caller);
            end
        end

        function xyz = readPositionUsteps(obj)
            %readPositionUsteps 'c' query -> 3x int32 usteps.
            obj.writeBytes([uint8('c'), uint8(13)]);
            raw = obj.readBytes(13);   % 12 payload bytes + CR (audit item #2)
            if numel(raw) < 12
                error('tfp:hardware:MP285ZStage:shortRead', ...
                    'Position query returned %d bytes (expected >= 12).', ...
                    numel(raw));
            end
            xyz = double(typecast(uint8(raw(1:12)), 'int32'));
        end

        function writeBytes(obj, bytes)
            if ischar(obj.sp_)
                obj.mockConsume(uint8(bytes(:)'));
            elseif obj.useLegacy_
                fwrite(obj.sp_, bytes, 'uint8');
            else
                write(obj.sp_, bytes, 'uint8');
            end
        end

        function raw = readBytes(obj, n)
            if ischar(obj.sp_)
                take = min(n, numel(obj.mockRxQueue_));
                raw = obj.mockRxQueue_(1:take);
                obj.mockRxQueue_(1:take) = [];
            elseif obj.useLegacy_
                raw = fread(obj.sp_, n, 'uint8')';
            else
                raw = read(obj.sp_, n, 'uint8');
            end
        end

        function mockConsume(obj, bytes)
            %mockConsume Emulated MP-285: parse complete command frames and
            %   enqueue the device's replies. Fails loud on unknown bytes —
            %   this is a test seam, not a tolerant parser.
            obj.mockTxBuf_ = [obj.mockTxBuf_, bytes];
            while ~isempty(obj.mockTxBuf_)
                switch char(obj.mockTxBuf_(1))
                    case 'c'
                        if numel(obj.mockTxBuf_) < 2, return, end
                        if obj.mockTxBuf_(2) ~= 13
                            error('tfp:hardware:MP285ZStage:mockBadCommand', ...
                                'mock: ''c'' not followed by CR.');
                        end
                        obj.mockTxBuf_(1:2) = [];
                        obj.mockRxQueue_ = [obj.mockRxQueue_, ...
                            typecast(int32(obj.mockPosUsteps_), 'uint8'), uint8(13)];
                    case 'm'
                        if numel(obj.mockTxBuf_) < 14, return, end
                        if obj.mockTxBuf_(14) ~= 13
                            error('tfp:hardware:MP285ZStage:mockBadCommand', ...
                                'mock: ''m'' frame not terminated by CR.');
                        end
                        payload = obj.mockTxBuf_(2:13);
                        obj.mockTxBuf_(1:14) = [];
                        obj.mockPosUsteps_ = reshape( ...
                            double(typecast(uint8(payload), 'int32')), 1, 3);
                        obj.mockRxQueue_ = [obj.mockRxQueue_, uint8(13)]; % completion CR
                    otherwise
                        error('tfp:hardware:MP285ZStage:mockBadCommand', ...
                            'mock: unknown command byte %d.', obj.mockTxBuf_(1));
                end
            end
        end

        function waitForCr(obj, caller)
            %waitForCr Block until the unit sends its completion CR.
            t0 = tic;
            while toc(t0) < obj.timeoutS_
                b = obj.readBytes(1);
                if ~isempty(b) && b(1) == 13
                    return
                end
            end
            error('tfp:hardware:MP285ZStage:moveTimeout', ...
                '%s: no completion CR within %.0f s.', caller, obj.timeoutS_);
        end

        function logEvent(obj, eventType, payload)
            entry.timestamp = datetime('now');
            entry.eventType = eventType;
            entry.payload   = payload;
            obj.log_(end+1) = entry;
        end
    end
end
