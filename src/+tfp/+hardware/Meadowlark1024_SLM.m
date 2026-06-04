classdef Meadowlark1024_SLM < tfp.hardware.SLM
%Meadowlark1024_SLM Real SLM driver for the Meadowlark 1024×1024 via Blink SDK.
%   Wraps the Meadowlark Blink SDK C shared library (Blink_SDK_C.dll /
%   libBlink_SDK_C.so) loaded via MATLAB loadlibrary/calllib. All Blink
%   function call sites carry a %VERIFY ASSUME/TEST/CHANGE comment block
%   because the SDK signatures have not been confirmed against the actual DLL
%   on this development machine (macOS, no DLL available). Verification must
%   happen on the Windows scope PC after first hardware bring-up.
%
%   On macOS (or any system without the Blink DLL), initialize() throws a
%   clean tfp:hardware:Meadowlark1024_SLM:libLoadFailed so callers and tests
%   get a typed, readable error rather than a raw loadlibrary crash.
%
%   config fields (all optional, defaults noted):
%     dims        [nCols nRows]   default [1024 1024]
%     pitch_um    pixel pitch µm  default 17
%     dllPath     path to Blink_SDK_C.dll   default ''
%     headerPath  path to Blink_SDK_C_matlab.h  default ''
%     lutFile     path to calibration LUT file   default ''
%
%   State machine: idle → loaded → presenting (see SLM.m).
%
%   SDK reference: Meadowlark Blink SDK C API (Blink_SDK_C.h).
%   All function signatures are assumed from published Meadowlark documentation
%   and community references — verify each one before first hardware use.

    % ------------------------------------------------------------------ %
    properties (SetAccess = protected)
        nRows         = 0
        nCols         = 0
        pitch_um      = 0
        isInitialized = false
    end

    properties (Access = private)
        mask_         = []        % uint8(nRows, nCols), most recently loaded mask
        state_        = 'idle'    % 'idle' | 'loaded' | 'presenting'
        powerOn_      = false     % true when SLM LC drive voltage is enabled
        dllName_      = 'Blink_SDK_C'   % library alias for calllib
        dllPath_      = ''        % full path to Blink_SDK_C.dll
        headerPath_   = ''        % full path to Blink_SDK_C_matlab.h
        lutFile_      = ''        % path to calibration LUT (may be empty)
        log_          = struct('timestamp', {}, 'eventType', {}, 'payload', {})
    end

    % ------------------------------------------------------------------ %
    methods
        function obj = Meadowlark1024_SLM(config)
            %Meadowlark1024_SLM Construct and initialize the Meadowlark SLM.
            %   config: struct with optional fields dims, pitch_um, dllPath,
            %           headerPath, lutFile.
            %   Throws tfp:hardware:Meadowlark1024_SLM:libLoadFailed if the
            %   Blink DLL cannot be loaded (expected on macOS dev machines).
            obj.initialize(config);
        end

        % -------------------------------------------------------------- %
        function initialize(obj, config)
            %initialize Load the Blink DLL and initialize the SLM hardware.
            %   Wraps loadlibrary in try/catch so a missing DLL produces a
            %   clean typed error rather than a raw MATLAB crash.

            if ~isstruct(config)
                error('tfp:hardware:Meadowlark1024_SLM:badConfig', ...
                    'config must be a struct.');
            end

            dims             = configField(config, 'dims',       [1024 1024]);
            obj.nCols        = dims(1);
            obj.nRows        = dims(2);
            obj.pitch_um     = configField(config, 'pitch_um',   17);
            obj.dllPath_     = configField(config, 'dllPath',    '');
            obj.headerPath_  = configField(config, 'headerPath', '');
            obj.lutFile_     = configField(config, 'lutFile',    '');

            % ---------------------------------------------------------- %
            % Load the Blink SDK shared library.
            % %VERIFY Blink_SDK_C DLL load.
            %   ASSUME: loadlibrary accepts 'Blink_SDK_C.dll' by alias 'Blink_SDK_C';
            %           header 'Blink_SDK_C_matlab.h' declares all required prototypes.
            %           If dllPath is empty the DLL must be on the system PATH.
            %   TEST: On scope PC, call `libfunctions('Blink_SDK_C')` after init;
            %         expect Create_SDK, Delete_SDK, Write_overdrive_image, etc.
            %   CHANGE: If the DLL ships under a different name or the header
            %           requires additional include paths, update dllPath_ /
            %           headerPath_ via config or adjust the loadlibrary call.
            try
                if ~libisloaded(obj.dllName_)
                    if ~isempty(obj.dllPath_) && ~isempty(obj.headerPath_)
                        loadlibrary(obj.dllPath_, obj.headerPath_, ...
                            'alias', obj.dllName_);
                    elseif ~isempty(obj.dllPath_)
                        loadlibrary(obj.dllPath_, 'alias', obj.dllName_);
                    else
                        loadlibrary('Blink_SDK_C', 'alias', obj.dllName_);
                    end
                end
            catch ME
                error('tfp:hardware:Meadowlark1024_SLM:libLoadFailed', ...
                    'Failed to load Blink SDK DLL: %s', ME.message);
            end

            % ---------------------------------------------------------- %
            % Create_SDK — allocate the SDK and open the SLM.
            % %VERIFY Create_SDK signature.
            %   ASSUME: int Create_SDK(int bits_per_pixel, int *n_boards_found,
            %           int *constructed_okay, int is_nematic_type,
            %           int RAM_write_enable, int use_GPU, int max_transients,
            %           double *lut_file) — per Meadowlark Blink_SDK_C.h.
            %           constructed_okay == 1 indicates success.
            %   TEST:   After init on scope PC, inspect n_boards_found ≥ 1
            %           and constructed_okay == 1.
            %   CHANGE: If SDK uses a different signature (e.g. returns a handle),
            %           update argument list and capture return value as handle.
            nBoardsPtr = libpointer('int32Ptr', int32(0));
            okPtr      = libpointer('int32Ptr', int32(0));
            ret = calllib(obj.dllName_, 'Create_SDK', ...
                int32(8), nBoardsPtr, okPtr, ...
                int32(1), int32(1), int32(0), int32(10), []);
            obj.checkBlink(ret, 'Create_SDK');

            % ---------------------------------------------------------- %
            % Set_true_frames — configure display frame count.
            % %VERIFY Set_true_frames signature.
            %   ASSUME: int Set_true_frames(int true_frames) — sets the number
            %           of true (non-overdrive) display frames; 3 is the
            %           Meadowlark-recommended default for LC settling.
            %   TEST:   Confirm via oscilloscope that SLM settling matches
            %           expected LC response time at 3 frames.
            %   CHANGE: If wavefront quality is poor, increase true_frames to
            %           5 or 10; field is config-settable in future revision.
            ret = calllib(obj.dllName_, 'Set_true_frames', int32(3));
            obj.checkBlink(ret, 'Set_true_frames');

            % ---------------------------------------------------------- %
            % Write_cal_buffer — load calibration file if provided.
            % %VERIFY Write_cal_buffer signature.
            %   ASSUME: int Write_cal_buffer(int board_number, char *filename) —
            %           loads a binary calibration file to correct wavefront error.
            %           board_number is 1-indexed. Skipped if lutFile_ is empty.
            %   TEST:   After loading cal buffer, measure flat-field uniformity
            %           with a Shack-Hartmann or interferometric reference.
            %   CHANGE: If the function signature differs (e.g. uses board index
            %           0-based), adjust board_number accordingly.
            if ~isempty(obj.lutFile_)
                ret = calllib(obj.dllName_, 'Write_cal_buffer', ...
                    int32(1), obj.lutFile_);
                obj.checkBlink(ret, 'Write_cal_buffer');
            end

            % ---------------------------------------------------------- %
            % Load_linear_LUT — load default linear look-up table.
            % %VERIFY Load_linear_LUT signature.
            %   ASSUME: int Load_linear_LUT(int board_number) — installs a
            %           linear phase-to-voltage mapping (0–255 → 0–2π).
            %           Used when no calibration file is supplied; when a .lut
            %           file is provided, Write_cal_buffer supersedes this.
            %   TEST:   Verify that a flat (128) mask produces half-wave
            %           retardation under cross-polariser measurement.
            %   CHANGE: If the Meadowlark SDK bundles its own default LUT call
            %           under a different name, update accordingly.
            if isempty(obj.lutFile_)
                ret = calllib(obj.dllName_, 'Load_linear_LUT', int32(1));
                obj.checkBlink(ret, 'Load_linear_LUT');
            end

            % ---------------------------------------------------------- %
            % SLM_power — enable LC drive voltage.
            % %VERIFY SLM_power signature.
            %   ASSUME: int SLM_power(int power_on) — 1 = on, 0 = off.
            %           Must be called before any Write_overdrive_image.
            %   TEST:   Confirm SLM display lights up and LC responds to
            %           a uniform phase mask after this call.
            %   CHANGE: If the function takes a boolean C type instead of int,
            %           adjust the MATLAB int32 cast.
            ret = calllib(obj.dllName_, 'SLM_power', int32(1));
            obj.checkBlink(ret, 'SLM_power');

            obj.powerOn_      = true;
            obj.mask_         = [];
            obj.state_        = 'idle';
            obj.isInitialized = true;

            obj.logEvent('initialize', struct('nRows', obj.nRows, 'nCols', obj.nCols, ...
                'pitch_um', obj.pitch_um, 'lutFile', obj.lutFile_));
        end

        % -------------------------------------------------------------- %
        function loadPhaseMask(obj, mask)
            %loadPhaseMask Validate and store a uint8 phase mask.
            %   mask: uint8([nRows nCols]).  The mask is buffered in MATLAB
            %   memory and written to the SLM hardware on the next present() call.
            if ~obj.isInitialized
                error('tfp:hardware:Meadowlark1024_SLM:notInitialized', ...
                    'initialize() must be called before loadPhaseMask().');
            end
            if ~isa(mask, 'uint8')
                error('tfp:hardware:Meadowlark1024_SLM:badMask', ...
                    'mask must be uint8; got %s.', class(mask));
            end
            if ~isequal(size(mask), [obj.nRows, obj.nCols])
                error('tfp:hardware:Meadowlark1024_SLM:badMaskShape', ...
                    'mask must be [%d x %d]; got [%s].', ...
                    obj.nRows, obj.nCols, num2str(size(mask)));
            end

            obj.mask_  = mask;
            obj.state_ = 'loaded';
            obj.logEvent('loadPhaseMask', struct('size', size(mask)));
        end

        % -------------------------------------------------------------- %
        function present(obj)
            %present Commit the loaded mask to the SLM display via Blink SDK.
            %   Calls Write_overdrive_image with the stored mask.
            if ~obj.isInitialized
                error('tfp:hardware:Meadowlark1024_SLM:notInitialized', ...
                    'initialize() must be called before present().');
            end
            if isempty(obj.mask_)
                error('tfp:hardware:Meadowlark1024_SLM:noMask', ...
                    'loadPhaseMask() must be called before present().');
            end

            % ---------------------------------------------------------- %
            % Write_overdrive_image — send mask to SLM frame buffer.
            % %VERIFY Write_overdrive_image signature.
            %   ASSUME: int Write_overdrive_image(int board_number,
            %           unsigned char *image, int wait_for_trigger,
            %           int timeout_ms) — board_number 1-indexed;
            %           image is row-major uint8(nRows*nCols);
            %           wait_for_trigger 0 = immediate display.
            %   TEST:   On scope PC, project a grating mask and verify fringes
            %           appear on a CCD at the expected spatial frequency.
            %   CHANGE: If the function takes nRows/nCols as additional arguments
            %           or if the image stride differs, add those parameters.
            imgFlat = obj.mask_(:);
            imgPtr  = libpointer('uint8Ptr', imgFlat);
            ret = calllib(obj.dllName_, 'Write_overdrive_image', ...
                int32(1), imgPtr, int32(0), int32(5000));
            obj.checkBlink(ret, 'Write_overdrive_image');

            obj.state_ = 'presenting';
            obj.logEvent('present', []);
        end

        % -------------------------------------------------------------- %
        function blank(obj)
            %blank Display a flat (all-zero) mask on the SLM immediately.
            %   Writes a zero-filled image to the SLM and transitions state
            %   to 'presenting'.  Safe to call at any time.
            if ~obj.isInitialized
                error('tfp:hardware:Meadowlark1024_SLM:notInitialized', ...
                    'initialize() must be called before blank().');
            end

            zeroMask = zeros(obj.nRows * obj.nCols, 1, 'uint8');

            % %VERIFY Write_overdrive_image for blank — same signature as present().
            %   ASSUME: Passing a zero array produces a flat wavefront on the SLM.
            %   TEST:   Verify under cross-polariser that blank gives maximum
            %           transmission (or minimum, depending on SLM orientation).
            %   CHANGE: If the SDK provides a dedicated 'blank' or 'reset' call,
            %           prefer that over writing zeros.
            imgPtr = libpointer('uint8Ptr', zeroMask);
            ret = calllib(obj.dllName_, 'Write_overdrive_image', ...
                int32(1), imgPtr, int32(0), int32(5000));
            obj.checkBlink(ret, 'Write_overdrive_image (blank)');

            obj.mask_  = zeros(obj.nRows, obj.nCols, 'uint8');
            obj.state_ = 'presenting';
            obj.logEvent('blank', []);
        end

        % -------------------------------------------------------------- %
        function slmPower(obj, onTF)
            %slmPower Enable or disable the SLM LC drive voltage.
            %   onTF: logical scalar. Power off to protect the LC crystal
            %   when the SLM is not in use (Meadowlark recommendation).
            if ~obj.isInitialized
                error('tfp:hardware:Meadowlark1024_SLM:notInitialized', ...
                    'initialize() must be called before slmPower().');
            end

            on = logical(onTF);

            % %VERIFY SLM_power(0) disables LC drive safely.
            %   ASSUME: int SLM_power(int power_on), 0 = off, 1 = on.
            %   TEST:   Confirm no damage to LC crystal when cycling on/off
            %           during normal session teardown on scope PC.
            %   CHANGE: If the SDK requires a separate 'shutdown' sequence
            %           before power-off, add those steps here.
            ret = calllib(obj.dllName_, 'SLM_power', int32(on));
            obj.checkBlink(ret, 'SLM_power');

            obj.powerOn_ = on;
            obj.logEvent('slmPower', struct('on', on));
        end

        % -------------------------------------------------------------- %
        function status = getStatus(obj)
            %getStatus Return a struct with current device state.
            %   Fields: state (char), isMaskLoaded (logical), powerOn (logical).
            status.state        = obj.state_;
            status.isMaskLoaded = ~isempty(obj.mask_);
            status.powerOn      = obj.powerOn_;
        end

        % -------------------------------------------------------------- %
        function cleanup(obj)
            %cleanup Power off the SLM, release SDK resources, unload DLL.
            %   Never throws — cleanup must succeed even after partial init.

            if obj.isInitialized
                % Best-effort SLM_power(false) then Delete_SDK.
                % Ignore return codes — cleanup must not throw.
                try
                    % %VERIFY SLM_power in cleanup.
                    %   ASSUME: SLM_power(0) is safe to call at any time.
                    %   TEST:   No error/hang on scope PC during session teardown.
                    %   CHANGE: Wrap in a try/catch if the call can throw on an
                    %           already-disconnected device.
                    calllib(obj.dllName_, 'SLM_power', int32(0));
                catch
                end

                try
                    % %VERIFY Delete_SDK signature.
                    %   ASSUME: int Delete_SDK(void) — frees all SDK resources and
                    %           closes the SLM connection.  No arguments required.
                    %   TEST:   After Delete_SDK, confirm libisloaded still returns
                    %           true (unloadlibrary below handles the DLL unload).
                    %   CHANGE: If Delete_SDK takes a handle argument (returned from
                    %           Create_SDK), update the call to pass that handle.
                    calllib(obj.dllName_, 'Delete_SDK');
                catch
                end

                try
                    if libisloaded(obj.dllName_)
                        unloadlibrary(obj.dllName_);
                    end
                catch
                end
            end

            obj.isInitialized = false;
            obj.state_        = 'idle';
            obj.powerOn_      = false;
            obj.mask_         = [];
            obj.logEvent('cleanup', []);
        end

        % -------------------------------------------------------------- %
        function entries = getLog(obj)
            %getLog Return the in-memory session log.
            %   entries is a struct array with fields
            %   {timestamp, eventType, payload}.
            entries = obj.log_;
        end
    end

    % ------------------------------------------------------------------ %
    methods (Access = private)

        function checkBlink(obj, ret, funcName)
            %checkBlink Throw a typed error on non-zero Blink SDK return codes.
            %   ret:      int32 return value from a calllib call.
            %   funcName: char, name of the Blink function (for error message).
            %
            %   %VERIFY Blink SDK return code convention.
            %     ASSUME: 0 = success; any non-zero value = error.  The SDK
            %             provides Get_last_error_message() for a human-readable
            %             description of the most recent error.
            %     TEST:   Deliberately pass an invalid board number and confirm
            %             checkBlink fires with the expected message on scope PC.
            %     CHANGE: If the SDK uses a different success sentinel (e.g. 1 =
            %             success), invert the condition below.
            if ret == int32(0)
                return;
            end

            % Try to get a human-readable error message from the SDK.
            % %VERIFY Get_last_error_message signature.
            %   ASSUME: char* Get_last_error_message(void) — returns a
            %           null-terminated C string describing the most recent error.
            %   TEST:   Inspect the returned string on scope PC after a deliberate
            %           bad-argument call to a Blink function.
            %   CHANGE: If the function name or signature differs, update here;
            %           fall back to 'unknown Blink error' if not present.
            errMsg = '';
            try
                errMsg = calllib(obj.dllName_, 'Get_last_error_message');
            catch
            end
            if isempty(errMsg)
                errMsg = sprintf('Blink SDK error code %d', ret);
            end

            error('tfp:hardware:Meadowlark1024_SLM:blinkError', ...
                '%s failed: %s', funcName, errMsg);
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
% Local helper — matches the configField pattern used in MockSLM / MockDAQ.

function value = configField(config, name, default)
if isfield(config, name)
    value = config.(name);
else
    value = default;
end
end
