classdef TIPLM_PLM < tfp.hardware.PLM
%TIPLM_PLM Real driver for the TI NIR PLM (904×800, 5-bit, 1030 nm).
%   Pixel pitch is rectangular: 16.2 µm (x/columns) × 10.8 µm (y/rows).
%   32 phase states (5-bit); max piston displacement = lambda/2 × (31/32),
%   giving max_phase = 2*pi*(31/32) ≈ 6.09 rad per full wrap.
%
%   computeDefocusPattern is inherited from PLM and computes a paraxial
%   defocus pattern for a given axial shift (dz_um) and optical system
%   parameters (M_relay, n, f_obj_um, NA).
%
%   Pattern display via Psychtoolbox full-screen window (TBD).
%   Trigger and pattern advance via I2C (TBD pending TI response).
%
%   Usage:
%     cfg = struct();
%     plm = tfp.hardware.TIPLM_PLM(cfg);
%     sys.M_relay  = 2.4;   sys.n       = 1.33;
%     sys.f_obj_um = 16800; sys.NA      = 0.6;
%     pat = plm.computeDefocusPattern(50, sys);  % 50 µm defocus
%     plm.loadPattern(pat);
%     plm.displayPattern(pat);  % encode_for_DLPC641 throws notImplemented until TI confirms protocol

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
            %   phase pattern for the DLPC641, and flips it to screen.
            %
            %   encode_for_DLPC641 throws notImplemented until TI confirms the
            %   DisplayPort binary-pattern protocol — see that method for the
            %   TODO. This scaffold is otherwise complete.

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

            % Encode and display — throws notImplemented until DLPC641 protocol known.
            gray = obj.encode_for_DLPC641(pattern);
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
            %configureTrigger Configure the I2C trigger interface on the TI PLM.
            %   TBD pending TI response on trigger register map.
            %   Expected: write trigger-mode and timing registers over I2C
            %   before the first advancePattern call.

            if ~obj.isInitialized
                error('tfp:hardware:TIPLM_PLM:notInitialized', ...
                    'initialize() must be called before configureTrigger().');
            end

            error('tfp:hardware:TIPLM_PLM:notImplemented', ...
                ['configureTrigger is not yet implemented ' ...
                 '(I2C register map TBD pending TI response).']);
        end

        % -------------------------------------------------------------- %
        function advancePattern(obj)
            %advancePattern Assert the trigger line to advance to the next pattern.
            %   TBD pending TI response on trigger topology.
            %   Expected: NI DAQ digital output pulse to the PLM trigger
            %   input, or an I2C register write, depending on TI's answer.

            if ~obj.isInitialized
                error('tfp:hardware:TIPLM_PLM:notInitialized', ...
                    'initialize() must be called before advancePattern().');
            end

            error('tfp:hardware:TIPLM_PLM:notImplemented', ...
                ['advancePattern is not yet implemented ' ...
                 '(trigger interface TBD pending TI response).']);
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
            %   Closes the PTB window if open. I2C handle release TBD.
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

        function gray = encode_for_DLPC641(~, pattern_uint8) %#ok<STOUT,INUSD>
            %encode_for_DLPC641 Convert uint8 phase states to DLPC641 display image.
            %
            % TODO: bitplane packing TBD pending TI DLPC641 docs.
            % Current implementation fails loudly; replace once TI confirms how
            % uint8 phase states (0–31) map to binary pattern slots over
            % DisplayPort. The intended encoding is linear grayscale
            % (state × 8, clamped to 255, replicated across RGB channels), but
            % this may not be what the DLPC641 interprets as pattern indices.
            error('tfp:hardware:TIPLM_PLM:notImplemented', ...
                ['encode_for_DLPC641 is not yet implemented: DLPC641 DisplayPort ' ...
                 'bitplane encoding protocol is TBD pending TI documentation. ' ...
                 'Replace this stub once TI confirms how uint8 phase states ' ...
                 '(0-31) map to binary pattern slots over DisplayPort.']);
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
