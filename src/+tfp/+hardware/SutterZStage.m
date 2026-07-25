classdef SutterZStage < tfp.hardware.ZStage
    %SutterZStage Sutter MP-285 / MP-285A objective focus stage over serial.
    %   Real driver, written ahead of hardware — HARDWARE-UNTESTED. It runs on
    %   the DAQ PC once the Sutter serial is plugged into it (see CLAUDE.md
    %   runbook: release the port from ScanImage first).
    %
    %   MP-285 binary RS-232 protocol (positions are int32 microsteps,
    %   little-endian, commands terminated with CR = 0x0D):
    %     move (absolute) : 'm' + X,Y,Z (3× int32) + CR.  The controller sends a
    %                       single CR back when the move COMPLETES, so moveTo is
    %                       naturally blocking (read until CR, moveTimeoutS guard).
    %     get position    : 'c' + CR  ->  X,Y,Z (3× int32) + CR.
    %   Only the focus axis (default Z) is driven; the other two axes are held at
    %   their current microstep values on each move.
    %
    %   %VERIFY on the rig before trusting (all config-driven): serialPort, baud,
    %   umPerMicrostep, focusAxis, the little-endian byte order, and the
    %   CR-on-completion handshake — confirm against the Sutter MP-285 manual.
    %
    %   config fields (passed to initialize):
    %     .serialPort     char, e.g. 'COM5' or '/dev/tty.usbserial-*' — REQUIRED
    %     .baud           default 9600 (MP-285), 8-N-1
    %     .umPerMicrostep default 0.04 µm (%VERIFY — firmware-dependent; some 0.2)
    %     .focusAxis      1|2|3 or 'x'|'y'|'z' — objective-Z axis (default 3/'z')
    %     .moveTimeoutS   default 30 s (a full-travel move can take seconds)
    %     .rangeUm        soft travel limits [lo hi] µm (default [-1000 1000])

    properties (SetAccess = protected)
        isInitialized = false
    end

    properties (Access = private)
        sp_             = []      % serialport object
        serialPort_     = ''
        baud_           = 9600
        umPerMicrostep_ = 0.04
        focusAxisIdx_   = 3
        moveTimeoutS_   = 30
        log_ = struct('timestamp', {}, 'eventType', {}, 'payload', {})
    end

    properties (Constant, Access = private)
        CR = uint8(13)           % MP-285 command/response terminator
    end

    methods
        function initialize(obj, config)
            if ~isstruct(config) || ~isfield(config, 'serialPort') || isempty(config.serialPort)
                error('tfp:hardware:SutterZStage:badConfig', ...
                    'config.serialPort is required (e.g. ''COM5'').');
            end
            obj.serialPort_     = char(config.serialPort);
            obj.baud_           = configField(config, 'baud', 9600);
            obj.umPerMicrostep_ = configField(config, 'umPerMicrostep', 0.04);
            obj.moveTimeoutS_   = configField(config, 'moveTimeoutS', 30);
            obj.rangeUm         = configField(config, 'rangeUm', [-1000, 1000]);
            obj.focusAxisIdx_   = parseAxis(configField(config, 'focusAxis', 3));

            % --- open the serial port; fail cleanly if unavailable (e.g. off-rig) ---
            try
                obj.sp_ = serialport(obj.serialPort_, obj.baud_, 'Timeout', obj.moveTimeoutS_);
            catch ME
                error('tfp:hardware:SutterZStage:portOpenFailed', ...
                    'Could not open Sutter serial port %s @ %d baud: %s', ...
                    obj.serialPort_, obj.baud_, ME.message);
            end
            configureTerminator(obj.sp_, 'CR');   % informational; we frame manually
            flush(obj.sp_);

            % --- confirm comms with a position query ---
            steps = obj.readPosition_();
            obj.positionUm = steps(obj.focusAxisIdx_) * obj.umPerMicrostep_;
            obj.isInitialized = true;
            obj.logEvent('initialize', struct('serialPort', obj.serialPort_, ...
                'baud', obj.baud_, 'umPerMicrostep', obj.umPerMicrostep_, ...
                'focusAxis', obj.focusAxisIdx_));
        end

        function moveTo(obj, zUm)
            if ~obj.isInitialized
                error('tfp:hardware:SutterZStage:notInitialized', ...
                    'initialize() must be called before moveTo().');
            end
            obj.assertInRange_(zUm);
            steps = obj.readPosition_();                          % keep current X,Y
            steps(obj.focusAxisIdx_) = round(zUm / obj.umPerMicrostep_);
            obj.sendMove_(steps);                                 % blocks until CR
            obj.positionUm = steps(obj.focusAxisIdx_) * obj.umPerMicrostep_;
            obj.logEvent('moveTo', struct('zUm', obj.positionUm));
        end

        function z = getPosition(obj)
            if ~obj.isInitialized
                error('tfp:hardware:SutterZStage:notInitialized', ...
                    'initialize() must be called before getPosition().');
            end
            steps = obj.readPosition_();
            z = steps(obj.focusAxisIdx_) * obj.umPerMicrostep_;
            obj.positionUm = z;
        end

        function cleanup(obj)
            if ~isempty(obj.sp_)
                try, flush(obj.sp_); catch, end %#ok<CTCH>
                obj.sp_ = [];       % release the serialport handle
            end
            obj.isInitialized = false;
            obj.logEvent('cleanup', []);
        end

        function entries = getLog(obj)
            entries = obj.log_;
        end
    end

    methods (Access = private)
        function steps = readPosition_(obj)
            %readPosition_ MP-285 'c' -> [X Y Z] microsteps (int32, little-endian).
            flush(obj.sp_);
            write(obj.sp_, [uint8('c'), obj.CR], 'uint8');
            resp = read(obj.sp_, 13, 'uint8');       % 3× int32 (12) + CR
            if numel(resp) < 12
                error('tfp:hardware:SutterZStage:noResponse', ...
                    'Sutter position query returned %d/13 bytes (timeout?).', numel(resp));
            end
            steps = double(typecast(uint8(resp(1:12)), 'int32'));   % LE host (x86)
        end

        function sendMove_(obj, steps)
            %sendMove_ MP-285 'm' + int32 X,Y,Z (LE) + CR; wait for CR completion.
            payload = typecast(int32(steps(:)'), 'uint8');          % 12 bytes, LE
            write(obj.sp_, [uint8('m'), payload, obj.CR], 'uint8');
            done = read(obj.sp_, 1, 'uint8');        % controller CR when move done
            if isempty(done) || done(1) ~= obj.CR
                error('tfp:hardware:SutterZStage:moveTimeout', ...
                    'Sutter move did not confirm within %g s.', obj.moveTimeoutS_);
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

% --- Local helpers ---

function idx = parseAxis(a)
if isnumeric(a) && isscalar(a) && any(a == [1 2 3])
    idx = a;
    return;
end
if ischar(a) || isstring(a)
    switch lower(char(a))
        case 'x', idx = 1; return;
        case 'y', idx = 2; return;
        case 'z', idx = 3; return;
    end
end
error('tfp:hardware:SutterZStage:badAxis', ...
    'focusAxis must be 1/2/3 or ''x''/''y''/''z''.');
end

function value = configField(config, name, default)
if isfield(config, name)
    value = config.(name);
else
    value = default;
end
end
