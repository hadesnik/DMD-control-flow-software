classdef MP285ZStage < tfp.hardware.ZStage
    %MP285ZStage Sutter MP-285 z axis over direct serial from the DAQ PC.
    %   Used when the operator flips the manual serial switch box so the
    %   MP-285 talks to the DAQ PC (its home position is the imaging PC —
    %   use RelayZStage there instead).
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
    %     MUST be checked against the unit (audit item #1).
    %
    %   Only Z is commanded; X/Y are read and echoed back unchanged on
    %   every move so the stage never translates laterally.
    %
    %   Config: serial_port ('COM5'), baud (9600), usteps_per_um (25),
    %           timeoutS (10).

    properties (SetAccess = protected)
        isInitialized = false
    end

    properties (Access = private)
        port_        = ''
        baud_        = 9600
        ustepsPerUm_ = 25
        timeoutS_    = 10
        sp_          = []    % serialport (R2019b+: serial fallback)
        useLegacy_   = false % true when using the pre-R2019b serial API
        log_         = struct('timestamp', {}, 'eventType', {}, 'payload', {})
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
                'baud', obj.baud_, 'ustepsPerUm', obj.ustepsPerUm_));
        end

        function moveToUm(obj, zUm)
            obj.requireInitialized('moveToUm');
            if ~isnumeric(zUm) || ~isscalar(zUm) || ~isfinite(zUm)
                error('tfp:hardware:MP285ZStage:badZ', ...
                    'zUm must be a finite numeric scalar.');
            end
            % Read current x/y/z so only z changes (audit item #3: the 'm'
            % command is absolute 3-axis — x/y MUST be echoed back).
            xyz = obj.readPositionUsteps();
            xyz(3) = round(double(zUm) * obj.ustepsPerUm_);
            obj.writeBytes([uint8('m'), typecast(int32(xyz), 'uint8'), uint8(13)]);
            obj.waitForCr('moveToUm');   % CR on completion = blocking move
            obj.logEvent('moveToUm', struct('zUm', double(zUm)));
        end

        function zUm = getPositionUm(obj)
            obj.requireInitialized('getPositionUm');
            xyz = obj.readPositionUsteps();
            zUm = double(xyz(3)) / obj.ustepsPerUm_;
        end

        function moveRelativeUm(obj, dzUm)
            obj.moveToUm(obj.getPositionUm() + double(dzUm));
        end

        function status = getStatus(obj)
            status.port   = obj.port_;
            status.zUm    = NaN;
            try
                status.zUm = obj.getPositionUm();
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
            if obj.useLegacy_
                fwrite(obj.sp_, bytes, 'uint8');
            else
                write(obj.sp_, bytes, 'uint8');
            end
        end

        function raw = readBytes(obj, n)
            if obj.useLegacy_
                raw = fread(obj.sp_, n, 'uint8')';
            else
                raw = read(obj.sp_, n, 'uint8');
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
