classdef DLPC900_PLM < tfp.hardware.PLM
%DLPC900_PLM Real driver for the TI NIR PLM (904×800, 5-bit, 1030 nm).
%   Controller: dual DLPC900 (same chip as DLP6500 LightCrafter; confirmed
%   by TI FAE 2026-05-21). Pixel pitch is rectangular: 16.2 µm (x/columns)
%   × 10.8 µm (y/rows). 32 phase states (5-bit); max piston displacement =
%   lambda/2 × (31/32), giving max_phase = 2*pi*(31/32) ≈ 6.09 rad per wrap.
%
%   computeDefocusPattern is inherited from PLM and computes a paraxial
%   defocus pattern for a given axial shift (dz_um) and optical system
%   parameters (M_relay, n, f_obj_um, NA).
%
%   Two control workflows are supported:
%
%   A. Pre-stored Pattern Mode (flash via TI LightCrafter GUI):
%     1. Compute stack: [pats, dz] = plm.generatePatternLibrary(N, dz_um, obj).
%     2. Export PNGs:   plm.exportPatternImages(pats, outputDir).
%     3. Flash to DLPC900 via TI LightCrafter GUI → Firmware tab (USB, ~30 s).
%     4. Arm trigger:   plm.configureTrigger('external').
%     TRIG_IN_2 then advances patterns autonomously; no MATLAB call per frame.
%
%   B. Pattern On-The-Fly Mode (USB HID upload, PLM-7):
%     1. plm.connect() — open USB HID handle (vendor 0x0451 / product 0x6401).
%     2. plm.uploadPatternSequence(pats, exposure_us, 'external'|'internal').
%     3. plm.configureTrigger('external') and plm.startSequence().
%     Command structure follows Pycrafter6500 (public GitHub project) per
%     DLPC900 Programmer's Guide (TI doc DLPU018).
%
%   Trigger: TRIG_IN_2 input, ≥ 20 µs pulse width (NI6323 counter must
%   stretch the ScanImage frame-clock pulse — see docs/SYNC.md §5).
%   Voltage level TBD: confirm from EVM schematic (likely 1.8 V; level
%   shifter required from DAQ 3.3 V output).
%
%   Usage:
%     cfg = struct();
%     plm = tfp.hardware.DLPC900_PLM(cfg);
%     [pats, dz] = plm.generatePatternLibrary(20, 400, 'Olympus20x');
%     plm.exportPatternImages(pats, 'C:\plm_patterns\session_01');

    % ------------------------------------------------------------------ %
    properties (SetAccess = protected)
        nRows         = 800
        nCols         = 904
        pitchX_um     = 16.2
        pitchY_um     = 10.8
        nPhaseStates  = 32
        lambda_nm     = 1030
        isInitialized = false
    end

    properties (Access = private)
        state_      = 'idle'    % 'idle' | 'connected' | 'loaded' | 'armed' | 'running'
        log_        = struct('timestamp', {}, 'eventType', {}, 'payload', {})
        usbDevice_  = []        % HID handle once connect() succeeds; 'mock' for tests
        seqByte_    = uint8(0)  % rolling USB-command sequence counter
    end

    % DLPC900 USB HID command codes — cross-reference Pycrafter6500 (public
    % GitHub) and DLPU018 before first hardware use. Command codes are 16-bit
    % big-endian on the wire (the buildCommandPacket helper splits them).
    properties (Constant, Access = private)
        CMD_DISPLAY_MODE      = uint16(hex2dec('1A1B'))   % Pattern Display Mode select
        CMD_PATTERN_START_STOP = uint16(hex2dec('1A24'))  % Start/Stop pattern sequence
        CMD_TRIGGER_IN2_CTRL  = uint16(hex2dec('1A35'))   % TRIG_IN_2 control (DLPU018 §2.4.4)
        CMD_LUT_CONFIG        = uint16(hex2dec('1A31'))   % Pattern LUT Configuration
        CMD_LUT_DEFINITION    = uint16(hex2dec('1A34'))   % Pattern LUT Definition
        CMD_BMP_LOAD_INIT     = uint16(hex2dec('1A2A'))   % Init pattern BMP load
        CMD_BMP_LOAD          = uint16(hex2dec('1A2B'))   % Pattern BMP load (chunked)

        DLPC900_VID = uint16(hex2dec('0451'))             % TI vendor ID
        DLPC900_PID = uint16(hex2dec('6401'))             % DLPC900 LightCrafter product ID
        TRIG_IN2_MIN_PULSE_US = 20                        % per TI FAE 2026-05-21
    end

    % ------------------------------------------------------------------ %
    methods
        function obj = DLPC900_PLM(config)
            %DLPC900_PLM Construct and initialise the PLM driver.
            %   config: struct; no required fields. Call connect() afterwards
            %   to open the USB HID handle before uploading patterns.
            obj.initialize(config);
        end

        % -------------------------------------------------------------- %
        function initialize(obj, config)
            %initialize Prepare the PLM driver.
            %   USB HID handle is opened separately in connect(); kept split
            %   so unit tests can construct the object without hardware.

            if ~isstruct(config)
                error('tfp:hardware:DLPC900_PLM:badConfig', ...
                    'config must be a struct.');
            end

            obj.state_        = 'idle';
            obj.usbDevice_    = [];
            obj.seqByte_      = uint8(0);
            obj.isInitialized = true;

            obj.logEvent('initialize', config);
        end

        % -------------------------------------------------------------- %
        function connect(obj, options)
            %connect Open the DLPC900 USB HID handle.
            %   options.mockTransport (default false): if true, skip real
            %     hidapi open and use an in-process echo transport. Required
            %     by unit tests and desk-side development on systems without
            %     the DLPC900 attached.
            %
            %   Real transport: hidapi open of vendor 0x0451, product 0x6401
            %   (DLPC900 LightCrafter, per Pycrafter6500). MATLAB has no
            %   first-party HID support — the production path will use either
            %   an hidapi mex or py.hid via the MATLAB Python interface
            %   (decision pending; see docs/SYNC.md §4).

            if nargin < 2 || isempty(options)
                options = struct();
            end
            useMock = configField(options, 'mockTransport', false);

            if useMock
                obj.usbDevice_ = 'mock';
                obj.state_     = 'connected';
                obj.logEvent('connect', struct('transport', 'mock'));
                return;
            end

            error('tfp:hardware:DLPC900_PLM:notImplemented', ...
                ['Real USB HID transport not yet implemented. ' ...
                 'Call connect(struct(''mockTransport'', true)) for the ' ...
                 'offline path exercised by unit tests until the hidapi ' ...
                 'mex or py.hid bridge lands.']);
        end

        % -------------------------------------------------------------- %
        function loadPattern(obj, pattern)
            %loadPattern Validate a single uint8 phase pattern and record it.
            %   For multi-pattern sequences use uploadPatternSequence().

            if ~obj.isInitialized
                error('tfp:hardware:DLPC900_PLM:notInitialized', ...
                    'initialize() must be called before loadPattern().');
            end
            obj.validatePattern(pattern);

            obj.state_ = 'loaded';
            obj.logEvent('loadPattern', struct('size', size(pattern)));
        end

        % -------------------------------------------------------------- %
        function uploadPatternSequence(obj, patterns, exposure_us, triggerMode)
            %uploadPatternSequence Encode and stream a 5-bit pattern stack to the DLPC900.
            %   patterns:    nRows × nCols × N uint8 (states 0..nPhaseStates-1)
            %   exposure_us: scalar double, per-bitplane exposure in microseconds.
            %                Minimum supported by DLPC900 ≈ 70 µs per bitplane
            %                (DLPU018 §3.5); enforce >= 70.
            %   triggerMode: 'external' | 'internal' — selects TRIG_IN_2 vs
            %                internal pacer between successive bitplanes.
            %
            %   Each 5-bit pattern becomes 5 binary bitplanes in the DLPC900
            %   LUT; the PLM EVM firmware reassembles the per-pixel grayscale
            %   value before driving the mirror piston state.
            %
            %   Steps (Pycrafter6500-style):
            %     1. Stop any running sequence (CMD_PATTERN_START_STOP, data=0).
            %     2. Switch to Pattern On-The-Fly Mode (CMD_DISPLAY_MODE, data=3).
            %     3. Define LUT entries 0..(5*N-1) (CMD_LUT_DEFINITION).
            %     4. Configure each LUT entry (CMD_LUT_CONFIG): exposure,
            %        bit depth = 1, trigger source.
            %     5. Init BMP transfer (CMD_BMP_LOAD_INIT) and stream
            %        bitplanes (CMD_BMP_LOAD) in ≤ 504-byte chunks.
            %   Every USB command's reply is validated by sendCommand_;
            %   non-zero status throws tfp:hardware:DLPC900_PLM:usbError.

            obj.requireConnected_();
            if ~isscalar(exposure_us) || ~isnumeric(exposure_us) || exposure_us < 70
                error('tfp:hardware:DLPC900_PLM:badExposure', ...
                    'exposure_us must be numeric scalar >= 70; got %s.', ...
                    mat2str(exposure_us));
            end
            triggerMode = char(triggerMode);
            if ~any(strcmp(triggerMode, {'external','internal'}))
                error('tfp:hardware:DLPC900_PLM:badTriggerMode', ...
                    'triggerMode must be ''external'' or ''internal''; got %s.', ...
                    triggerMode);
            end

            bitplanes = obj.encodeBitplanes_(patterns);
            nBp       = size(bitplanes, 3);

            obj.sendCommand_(obj.CMD_PATTERN_START_STOP, 0, uint8(0));      % stop
            obj.sendCommand_(obj.CMD_DISPLAY_MODE,       0, uint8(3));      % on-the-fly
            obj.sendCommand_(obj.CMD_LUT_DEFINITION,     0, ...
                             [uint8(0), typecast(uint16(nBp - 1), 'uint8')]);
            trigSrc = uint8(strcmp(triggerMode, 'external'));               % 1 = TRIG_IN_2
            for entry = 0:(nBp - 1)
                expBytes = typecast(uint32(round(exposure_us)), 'uint8');
                lutData  = [typecast(uint16(entry), 'uint8'), ...
                            expBytes, uint8(1), trigSrc];                   % bit depth = 1
                obj.sendCommand_(obj.CMD_LUT_CONFIG, 0, lutData);
            end
            obj.sendCommand_(obj.CMD_BMP_LOAD_INIT, 0, uint8(0));
            obj.streamBitplanes_(bitplanes);

            obj.state_ = 'loaded';
            obj.logEvent('uploadPatternSequence', struct( ...
                'nPatterns',   size(patterns, 3), ...
                'nBitplanes',  nBp, ...
                'exposure_us', exposure_us, ...
                'triggerMode', triggerMode));
        end

        % -------------------------------------------------------------- %
        function uploadTwoPatternFlipTest(obj, flat, grating, freq_Hz)
            %uploadTwoPatternFlipTest Bench test: ping-pong between two patterns.
            %   flat, grating: nRows × nCols uint8 phase patterns (states 0..N-1).
            %   freq_Hz:       desired full-cycle frequency in Hz (flat→grating→flat).
            %
            %   exposure_us is computed as 1e6 / (2 * freq_Hz) — each half-cycle
            %   shows one pattern. Uses internal trigger so the test can run
            %   without a function generator on TRIG_IN_2.

            if ~isscalar(freq_Hz) || ~isnumeric(freq_Hz) || freq_Hz <= 0
                error('tfp:hardware:DLPC900_PLM:badFrequency', ...
                    'freq_Hz must be positive scalar; got %s.', mat2str(freq_Hz));
            end
            exposure_us = 1e6 / (2 * freq_Hz);
            patterns    = cat(3, flat, grating);
            obj.uploadPatternSequence(patterns, exposure_us, 'internal');
            obj.logEvent('uploadTwoPatternFlipTest', struct( ...
                'freq_Hz',     freq_Hz, ...
                'exposure_us', exposure_us));
        end

        % -------------------------------------------------------------- %
        function configureTrigger(obj, mode)
            %configureTrigger Arm the DLPC900 trigger mode via USB HID.
            %   mode (optional, default 'external'): 'external' selects
            %     TRIG_IN_2 rising-edge advance; 'internal' selects the
            %     internal pacer (continuous display at the LUT exposure).
            %
            %   TRIG_IN_2 requires ≥ 20 µs pulse width (TI FAE 2026-05-21);
            %   the NI6323 counter must stretch the ScanImage frame-clock
            %   pulse before it reaches the DLPC900 (docs/SYNC.md §5).

            if nargin < 2 || isempty(mode)
                mode = 'external';
            end
            mode = char(mode);
            if ~any(strcmp(mode, {'external','internal'}))
                error('tfp:hardware:DLPC900_PLM:badTriggerMode', ...
                    'mode must be ''external'' or ''internal''; got %s.', mode);
            end
            obj.requireConnected_();

            % TRIG_IN_2 control payload (DLPU018 §2.4.4):
            %   byte 0: edge polarity (0 = rising)
            %   bytes 1..4: delay in µs (uint32 little-endian)
            if strcmp(mode, 'external')
                trigPayload = [uint8(0), typecast(uint32(0), 'uint8')];
                obj.sendCommand_(obj.CMD_TRIGGER_IN2_CTRL, 0, trigPayload);
            end
            % 'internal' mode: nothing to arm — internal pacer is implicit
            % once the sequence starts.

            obj.state_ = 'armed';
            obj.logEvent('configureTrigger', struct('mode', mode));
        end

        % -------------------------------------------------------------- %
        function startSequence(obj)
            %startSequence Begin pattern display.
            %   In external mode, the first TRIG_IN_2 pulse advances to LUT
            %   entry 0; in internal mode, display starts immediately.

            obj.requireConnected_();
            obj.sendCommand_(obj.CMD_PATTERN_START_STOP, 0, uint8(2));  % start
            obj.state_ = 'running';
            obj.logEvent('startSequence', []);
        end

        % -------------------------------------------------------------- %
        function stopSequence(obj)
            %stopSequence Halt pattern display.
            obj.requireConnected_();
            obj.sendCommand_(obj.CMD_PATTERN_START_STOP, 0, uint8(0));  % stop
            obj.state_ = 'armed';
            obj.logEvent('stopSequence', []);
        end

        % -------------------------------------------------------------- %
        function advancePattern(obj)
            %advancePattern Software-trigger one pattern advance (diagnostic only).
            %   In normal operation TRIG_IN_2 hardware pulses advance the
            %   sequence autonomously — this is for bench testing without a
            %   function generator. Pairs with start/stopSequence.

            obj.requireConnected_();
            % DLPC900 has no documented one-step USB command in Pattern
            % On-The-Fly Mode; software-step is implemented as start→stop
            % cycle of the running sequence.
            obj.sendCommand_(obj.CMD_PATTERN_START_STOP, 0, uint8(1));  % advance/pause
            obj.logEvent('advancePattern', []);
        end

        % -------------------------------------------------------------- %
        function status = getStatus(obj)
            %getStatus Return a status struct matching MockPLM.getStatus() shape.
            status.state           = obj.state_;
            status.isPatternLoaded = any(strcmp(obj.state_, {'loaded','armed','running'}));
            status.isConnected     = ~isempty(obj.usbDevice_);
        end

        % -------------------------------------------------------------- %
        function cleanup(obj)
            %cleanup Release the USB HID handle and reset state.
            if ~isempty(obj.usbDevice_) && ~strcmp(obj.usbDevice_, 'mock')
                % TODO: close real hidapi handle here once transport lands.
            end
            obj.usbDevice_    = [];
            obj.state_        = 'idle';
            obj.isInitialized = false;
            obj.logEvent('cleanup', []);
        end

        % -------------------------------------------------------------- %
        function entries = getLog(obj)
            %getLog Return the struct-array session log.
            %   Fields: {timestamp, eventType, payload}.
            entries = obj.log_;
        end
    end

    % ================================================================== %
    % Bitplane encoding and USB framing — exposed (public) so unit tests can
    % drive them directly. Not part of the abstract PLM contract; experiment
    % code should call uploadPatternSequence rather than these helpers.
    methods

        function bitplanes = encodeBitplanes_(obj, patterns)
            %encodeBitplanes_ Decompose 5-bit phase patterns into binary bitplanes.
            %   patterns:  nRows × nCols × N uint8 (values 0..nPhaseStates-1).
            %   bitplanes: nRows × nCols × (nBits*N) logical, LSB-first per
            %              pattern. For pattern k (1..N),
            %              bitplanes(:,:,(k-1)*nBits + b + 1) is bit b (0..nBits-1)
            %              of patterns(:,:,k). nBits = ceil(log2(nPhaseStates)) = 5.
            %
            %   Bit order matches the Pycrafter6500 convention. Verify against
            %   the DLPC900 firmware-mode bit-depth descriptor (DLPU018 §3.4)
            %   on first hardware bring-up.

            if ~isa(patterns, 'uint8')
                error('tfp:hardware:DLPC900_PLM:badPatterns', ...
                    'patterns must be uint8; got %s.', class(patterns));
            end
            if size(patterns, 1) ~= obj.nRows || size(patterns, 2) ~= obj.nCols
                error('tfp:hardware:DLPC900_PLM:badPatternShape', ...
                    'patterns must be [%d × %d × N]; got [%s].', ...
                    obj.nRows, obj.nCols, num2str(size(patterns)));
            end
            if any(patterns(:) >= obj.nPhaseStates)
                error('tfp:hardware:DLPC900_PLM:badPatternValues', ...
                    'pattern values must be in 0..%d; got max %d.', ...
                    obj.nPhaseStates - 1, max(patterns(:)));
            end

            N     = size(patterns, 3);
            nBits = ceil(log2(double(obj.nPhaseStates)));
            bitplanes = false(obj.nRows, obj.nCols, nBits * N);
            for k = 1:N
                for b = 0:(nBits - 1)
                    bitplanes(:,:,(k-1)*nBits + b + 1) = ...
                        bitget(patterns(:,:,k), b + 1) > 0;
                end
            end
        end

        function packet = buildCommandPacket_(obj, cmd, flag, data)
            %buildCommandPacket_ Assemble a DLPC900 USB HID command payload.
            %   cmd:    uint16 command code (e.g. 0x1A1B).
            %   flag:   uint8 flag byte (bit 7 = read/write per DLPU018 §2.1).
            %   data:   uint8 row vector; payload after the command code.
            %   packet: uint8 row vector; one HID report payload (≤ 64 bytes).
            %
            %   Format (DLPU018 §2.1):
            %     [flag | seq | lenLSB | lenMSB | cmdLSB | cmdMSB | data...]
            %   length counts the two cmd bytes plus the data bytes.

            data    = uint8(data(:))';
            cmdLSB  = uint8(bitand(double(cmd), 255));
            cmdMSB  = uint8(bitshift(double(cmd), -8));
            payloadLen = uint16(numel(data) + 2);
            lenLSB  = uint8(bitand(double(payloadLen), 255));
            lenMSB  = uint8(bitshift(double(payloadLen), -8));
            obj.seqByte_ = uint8(mod(double(obj.seqByte_) + 1, 256));
            packet  = [uint8(flag), obj.seqByte_, lenLSB, lenMSB, ...
                       cmdLSB, cmdMSB, data];
        end
    end

    % ================================================================== %
    % USB transport — mock-only until hidapi/py.hid bridge lands.
    methods (Access = private)

        function reply = sendCommand_(obj, cmd, flag, data)
            %sendCommand_ Frame, send, and validate one DLPC900 USB command.
            %   Returns the reply payload (uint8). Throws
            %   tfp:hardware:DLPC900_PLM:usbError on any non-zero status or
            %   transport failure. The mock transport always reports success.

            if isempty(obj.usbDevice_)
                error('tfp:hardware:DLPC900_PLM:notConnected', ...
                    'connect() must succeed before sending USB commands.');
            end
            packet = obj.buildCommandPacket_(cmd, flag, data);

            if strcmp(obj.usbDevice_, 'mock')
                reply  = uint8([]);                 % mock: always success
                status = 0;
            else
                % TODO: real hidapi write + read here. For now this branch
                % should never execute because connect() rejects the
                % non-mock path.
                error('tfp:hardware:DLPC900_PLM:notImplemented', ...
                    'Real USB HID transport not yet implemented.');
            end

            if status ~= 0
                error('tfp:hardware:DLPC900_PLM:usbError', ...
                    'DLPC900 USB command 0x%04X returned status 0x%02X.', ...
                    cmd, status);
            end
            % Note: sendCommand_ does not log per-call — high-level methods
            % (uploadPatternSequence, configureTrigger, etc.) log a single
            % summary event. Per-call logging would explode the log under
            % BMP streaming (thousands of chunks per pattern).
        end

        function streamBitplanes_(obj, bitplanes)
            %streamBitplanes_ Send a bitplane stack in BMP-load chunks.
            %   Currently packs bitplanes row-major, one chunk per bitplane.
            %   The DLPC900 BMP load supports RLE-compressed BMP per DLPU018
            %   §3.6; we send raw bit-packed bytes here and rely on the EVM
            %   firmware to reassemble. Compression and exact framing TBD
            %   against Pycrafter6500 reference on first hardware bring-up.

            chunkMaxBytes = 504;   % DLPU018 §2.1 — HID report payload limit
            nBp = size(bitplanes, 3);
            for k = 1:nBp
                packed = uint8(reshape(bitplanes(:,:,k), 1, []));   % 1 byte/pixel placeholder
                offset = 0;
                while offset < numel(packed)
                    n = min(chunkMaxBytes, numel(packed) - offset);
                    obj.sendCommand_(obj.CMD_BMP_LOAD, 0, ...
                        packed(offset + (1:n)));
                    offset = offset + n;
                end
            end
        end

        function requireConnected_(obj)
            if ~obj.isInitialized
                error('tfp:hardware:DLPC900_PLM:notInitialized', ...
                    'initialize() must be called first.');
            end
            if isempty(obj.usbDevice_)
                error('tfp:hardware:DLPC900_PLM:notImplemented', ...
                    ['USB HID handle is not open. Call connect() first. ' ...
                     'Real transport is pending; use ' ...
                     'connect(struct(''mockTransport'', true)) for the ' ...
                     'offline path until the hidapi bridge lands.']);
            end
        end

        function validatePattern(obj, pattern)
            if ~isa(pattern, 'uint8')
                error('tfp:hardware:DLPC900_PLM:badPattern', ...
                    'pattern must be uint8; got %s.', class(pattern));
            end
            if ~isequal(size(pattern), [obj.nRows, obj.nCols])
                error('tfp:hardware:DLPC900_PLM:badPatternShape', ...
                    'pattern must be [%d x %d]; got [%s].', ...
                    obj.nRows, obj.nCols, num2str(size(pattern)));
            end
            if any(pattern(:) >= obj.nPhaseStates)
                error('tfp:hardware:DLPC900_PLM:badPatternValues', ...
                    'pattern values must be in 0..%d; got max %d.', ...
                    obj.nPhaseStates - 1, max(pattern(:)));
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

% -------------------------------------------------------------------------- %
% Local helper — matches the configField pattern used in MockPLM / MockDAQ.

function value = configField(config, name, default)
if isfield(config, name)
    value = config.(name);
else
    value = default;
end
end
