classdef TIPLM_PLM < tfp.hardware.PLM
%TIPLM_PLM Real driver for the TI NIR PLM (904×800, 5-bit, 1030 nm).
%   Controller: dual DLPC900 (same chip as DLP6500 LightCrafter; confirmed
%   by TI FAE 2026-05-21). Pixel pitch is rectangular: 16.2 µm (x/columns)
%   × 10.8 µm (y/rows). 32 phase states (5-bit); max piston displacement =
%   lambda/2 × (31/32), giving max_phase = 2*pi*(31/32) ≈ 6.09 rad per wrap.
%
%   computeDefocusPattern is inherited from PLM and computes a paraxial
%   defocus pattern for a given axial shift (dz_um) and optical system
%   parameters (M_relay, n, f_obj_um, NA).
%
%   Pattern preload workflow:
%     1. Export patterns as PNG via exportPatternImages().
%     2. Flash to device onboard flash via TI GUI Firmware tab (USB, ~30 s).
%     3. Call configureTrigger() to arm TRIG_IN_2 hardware sequencing.
%   Pattern display via Psychtoolbox is used only during the export/verify
%   step, not during live acquisition.
%
%   Trigger: TRIG_IN_2 input, ≥ 20 µs pulse width, advancing one pattern
%   per rising edge (Pre-stored Pattern Mode). Voltage level TBD — confirm
%   from EVM schematic (likely 1.8 V; level shifter required from DAQ 3.3 V).
%   I2C API: DLPC900 Programmer's Guide (TI doc DLPU018).
%
%   Usage:
%     cfg = struct();
%     plm = tfp.hardware.TIPLM_PLM(cfg);
%     sys.M_relay  = 2.4;   sys.n       = 1.33;
%     sys.f_obj_um = 16800; sys.NA      = 0.6;
%     pat = plm.computeDefocusPattern(50, sys);  % 50 µm defocus
%     plm.loadPattern(pat);
%     plm.displayPattern(pat);  % uses encode_for_DLPC900 (linear grayscale placeholder)

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
        state_  = 'idle'    % 'idle' | 'displaying'
        log_    = struct('timestamp', {}, 'eventType', {}, 'payload', {})
        ptbWin_ = []        % Psychtoolbox window handle; [] = not yet opened
    end

    % ------------------------------------------------------------------ %
    methods
        function obj = TIPLM_PLM(config)
            %TIPLM_PLM Construct and initialise the PLM.
            %   config: struct; no required fields in Phase 3/4 stubs.
            %   When Psychtoolbox and I2C integration are implemented, add
            %   fields such as .screenId and .i2cPort here.
            obj.initialize(config);
        end

        % -------------------------------------------------------------- %
        function initialize(obj, config)
            %initialize Prepare the PLM for use.
            %   Stores initialisation state. Hardware connections
            %   (Psychtoolbox window, I2C) are opened in displayPattern and
            %   configureTrigger once those stubs are filled.

            if ~isstruct(config)
                error('tfp:hardware:TIPLM_PLM:badConfig', ...
                    'config must be a struct.');
            end

            obj.state_        = 'idle';
            obj.isInitialized = true;

            obj.logEvent('initialize', config);
        end

        % -------------------------------------------------------------- %
        function loadPattern(obj, pattern)
            %loadPattern Validate a uint8 phase pattern.
            %   Validates shape and value range. Transferring pattern bytes
            %   to the PLM frame buffer is deferred until displayPattern is
            %   implemented via Psychtoolbox.

            if ~obj.isInitialized
                error('tfp:hardware:TIPLM_PLM:notInitialized', ...
                    'initialize() must be called before loadPattern().');
            end
            obj.validatePattern(pattern);

            % TODO(Phase 4): transfer pattern bytes to PLM frame buffer via
            % Psychtoolbox Screen('MakeTexture', ...) or equivalent.
            obj.logEvent('loadPattern', struct('size', size(pattern)));
        end

        % -------------------------------------------------------------- %
        function displayPattern(obj, pattern)
            %displayPattern Display a phase pattern on the PLM via Psychtoolbox.
            %   Opens a full-screen PTB window on the secondary monitor (the
            %   PLM DisplayPort output) if not already open, encodes the uint8
            %   phase pattern for the DLPC900, and flips it to screen.
            %   Used during the pattern export/verify step only; live acquisition
            %   uses pre-stored patterns triggered by TRIG_IN_2 hardware input.

            if ~obj.isInitialized
                error('tfp:hardware:TIPLM_PLM:notInitialized', ...
                    'initialize() must be called before displayPattern().');
            end
            obj.validatePattern(pattern);

            % Detect secondary screen; PLM must appear as a separate monitor.
            screens = Screen('Screens');
            if numel(screens) < 2
                warning('tfp:hardware:TIPLM_PLM:noSecondScreen', ...
                    ['Fewer than 2 screens detected (%d found). ' ...
                     'Verify the PLM is connected via DisplayPort.'], ...
                    numel(screens));
            end
            screenIdx = screens(end);   % rightmost index = secondary monitor

            % Open PTB window once; reuse on subsequent calls.
            if isempty(obj.ptbWin_)
                obj.ptbWin_ = Screen('OpenWindow', screenIdx, 0);
            end

            % Encode and display — linear grayscale placeholder (see encode_for_DLPC900).
            gray = obj.encode_for_DLPC900(pattern);
            tex  = Screen('MakeTexture', obj.ptbWin_, gray);
            Screen('DrawTexture', obj.ptbWin_, tex);
            Screen('Flip', obj.ptbWin_);
            Screen('Close', tex);

            obj.state_ = 'displaying';
            obj.logEvent('displayPattern', struct('size', size(pattern)));
        end

        % -------------------------------------------------------------- %
        function closePTBWindow(obj)
            %closePTBWindow Close the Psychtoolbox window and release the handle.
            %   Call explicitly when done, or let cleanup() call it.
            if ~isempty(obj.ptbWin_)
                Screen('Close', obj.ptbWin_);
                obj.ptbWin_ = [];
            end
            obj.logEvent('closePTBWindow', []);
        end

        % -------------------------------------------------------------- %
        function configureTrigger(obj)
            %configureTrigger Arm the DLPC900 TRIG_IN_2 hardware trigger mode.
            %   Sends I2C commands to switch the DLPC900 to Pre-stored Pattern
            %   Mode and enable TRIG_IN_2 positive-edge sequencing. Must be
            %   called after the pattern firmware has been flashed via the TI
            %   GUI and before the first frame-clock edge arrives.
            %
            %   Register map: DLPC900 Programmer's Guide (TI doc DLPU018), §2.4.
            %   I2C address: 0x36 (primary DLPC900 — verify from EVM schematic).
            %   Requires MATLAB Instrument Control Toolbox i2cdev object.

            if ~obj.isInitialized
                error('tfp:hardware:TIPLM_PLM:notInitialized', ...
                    'initialize() must be called before configureTrigger().');
            end

            % TODO(Phase 4): implement using DLPC900 I2C API (DLPU018 §2.4).
            % Pseudocode:
            %   dev = i2cdev(adapter, '0x36');
            %   write(dev, [0x1A, 0x00]);   % Pre-stored Pattern Mode
            %   write(dev, [0x75, 0x01]);   % TRIG_IN_2 enable, positive edge
            %   write(dev, [0x1A, 0x02]);   % Start / arm sequence
            % Verify register addresses against DLPU018 before use.
            error('tfp:hardware:TIPLM_PLM:notImplemented', ...
                ['configureTrigger is not yet implemented. ' ...
                 'Implement from DLPC900 Programmer''s Guide (DLPU018 §2.4). ' ...
                 'No further TI input needed — register map is documented.']);
        end

        % -------------------------------------------------------------- %
        function advancePattern(obj)
            %advancePattern Software-trigger one pattern advance (diagnostic use only).
            %   In normal operation, TRIG_IN_2 hardware pulses advance the pattern
            %   autonomously — MATLAB does not call this per frame. This method
            %   is for bench testing when a function generator is not available.
            %   Sends an I2C command to step the pattern index manually.
            %
            %   Hardware trigger: TRIG_IN_2 rising edge, ≥ 20 µs pulse width
            %   (confirmed by TI FAE). The NI6323 counter output must stretch
            %   the ScanImage frame-clock pulse to ≥ 20 µs before it reaches
            %   the DLPC900 (see docs/SYNC.md §5 step 1).

            if ~obj.isInitialized
                error('tfp:hardware:TIPLM_PLM:notInitialized', ...
                    'initialize() must be called before advancePattern().');
            end

            % TODO(Phase 4): implement I2C software step command from DLPU018.
            error('tfp:hardware:TIPLM_PLM:notImplemented', ...
                ['advancePattern software trigger not yet implemented. ' ...
                 'In normal operation this is not called — TRIG_IN_2 hardware ' ...
                 'advances patterns autonomously (≥ 20 µs pulse required).']);
        end

        % -------------------------------------------------------------- %
        function status = getStatus(obj)
            %getStatus Return a status struct matching MockPLM.getStatus() shape.
            status.state           = obj.state_;
            status.isPatternLoaded = false;     % no in-memory cache in real impl
        end

        % -------------------------------------------------------------- %
        function cleanup(obj)
            %cleanup Release hardware resources.
            %   Closes the PTB window if open. I2C handle release: TODO(Phase 4).
            obj.closePTBWindow();
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

    % ------------------------------------------------------------------ %
    methods (Access = private)

        function gray = encode_for_DLPC900(~, pattern_uint8)
            %encode_for_DLPC900 Convert uint8 phase states to DLPC900 display image.
            %   Scales 0–31 linearly to 0–255 grayscale (multiply by 8, clamp to
            %   255), then replicates across RGB channels for Psychtoolbox display.
            %   Returns uint8 [nRows × nCols × 3] RGB image.
            %
            % TODO: bitplane packing — verify against DLPC900 Programmer's Guide
            % (DLPU018) §3 "Pre-stored Pattern Mode". The DLPC900 in 8-bit
            % grayscale DisplayPort mode may interpret pixel intensity directly
            % as a phase-state index (linear mapping is likely correct), but
            % confirm before first hardware use. Binary pattern modes pack
            % multiple 1-bit patterns per frame — not needed here since we use
            % 5-bit (32-state) grayscale patterns.
            scaled = min(uint8(255), uint8(pattern_uint8) .* uint8(8));
            gray   = repmat(scaled, [1, 1, 3]);
        end

        function validatePattern(obj, pattern)
            %validatePattern Throw typed errors for bad pattern arguments.
            if ~isa(pattern, 'uint8')
                error('tfp:hardware:TIPLM_PLM:badPattern', ...
                    'pattern must be uint8; got %s.', class(pattern));
            end
            if ~isequal(size(pattern), [obj.nRows, obj.nCols])
                error('tfp:hardware:TIPLM_PLM:badPatternShape', ...
                    'pattern must be [%d x %d]; got [%s].', ...
                    obj.nRows, obj.nCols, num2str(size(pattern)));
            end
            if any(pattern(:) >= obj.nPhaseStates)
                error('tfp:hardware:TIPLM_PLM:badPatternValues', ...
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
