classdef BlinkSLM < handle
    %BlinkSLM Real Meadowlark 1K driver via the Blink SDK — STUBBED.
    %   Runs ONLY on the SLM PC (Windows, PCIe controller + Blink install),
    %   beneath scripts/slm_pc_setup/slm_server.m. This skeleton copies the
    %   DLP650LNIR_DMD external-DLL wrapper pattern (loadlibrary + header,
    %   libpointer out-params, typed error mapping, non-throwing cleanup),
    %   but every hardware-touching method throws
    %   tfp:hardware:BlinkSLM:sdkNotVendored until the Blink SDK header is
    %   vendored and audited:
    %
    %     1. On the SLM PC, locate the Blink install; copy the C wrapper
    %        header (+ SDK manual) into vendor/meadowlark/official/.
    %     2. Write docs/blink-api-audit.md: every function this class needs,
    %        cross-referenced to header line numbers. Confirm whether this
    %        HSP1K unit supports ONBOARD SEQUENCE MEMORY with external-
    %        trigger advance, and record the LUT / WFC load calls.
    %     3. Replace the %VENDOR-AUDIT placeholders below with the real
    %        calllib names. NEVER invent Blink function names (CLAUDE.md
    %        rule, same discipline as the ALP API).
    %
    %   Config (from slm_pc_config.m):
    %     .dllPath      — Blink SDK DLL full path            (required)
    %     .headerPath   — Blink C wrapper header full path   (required)
    %     .lutPath      — wavelength LUT file ('' = skip device-LUT load)
    %     .nRows/.nCols — 1024 x 1024 (validated against the board)

    properties (SetAccess = protected)
        nRows         = 1024
        nCols         = 1024
        isInitialized = false
    end

    properties (Access = private)
        dllPath_    = ''
        headerPath_ = ''
        lutPath_    = ''
        dllName_    = 'blink'   % loadlibrary alias
        boardId_    = []
        nLoaded_    = 0
        state_      = 'idle'    % 'idle'|'connected'|'sequenced'|'armed'
        log_        = struct('timestamp', {}, 'eventType', {}, 'payload', {})
    end

    methods
        function obj = BlinkSLM(config)
            if nargin < 1 || isempty(config)
                config = struct();
            end
            obj.dllPath_    = char(tfp.util.configField(config, 'dllPath',    ''));
            obj.headerPath_ = char(tfp.util.configField(config, 'headerPath', ''));
            obj.lutPath_    = char(tfp.util.configField(config, 'lutPath',    ''));
            obj.nRows       = double(tfp.util.configField(config, 'nRows', 1024));
            obj.nCols       = double(tfp.util.configField(config, 'nCols', 1024));
            obj.logEvent('construct', config);
        end

        function initialize(obj) %#ok<MANU>
            %initialize Create the SDK, select the board, load the LUT.
            %
            % %VENDOR-AUDIT — intended shape once vendor/meadowlark/official/
            % exists (function names are PLACEHOLDERS, not real Blink names):
            %
            %   if ~libisloaded(obj.dllName_)
            %       loadlibrary(obj.dllPath_, obj.headerPath_, 'alias', obj.dllName_);
            %   end
            %   <create-SDK call, libpointer out-params for board count>
            %   <board-select / dimensions inquiry — validate 1024 x 1024>
            %   if ~isempty(obj.lutPath_), <load-LUT call>(obj.lutPath_); end
            %   obj.state_ = 'connected'; obj.isInitialized = true;
            error('tfp:hardware:BlinkSLM:sdkNotVendored', ...
                ['Blink SDK not vendored yet. Copy the SDK header from the ' ...
                 'SLM PC into vendor/meadowlark/official/, write ' ...
                 'docs/blink-api-audit.md, then fill in the %%VENDOR-AUDIT ' ...
                 'calllib blocks in BlinkSLM.m.']);
        end

        function writeImage(obj, mask8) %#ok<INUSD>
            %writeImage Write one uint8(nRows, nCols) mask to the SLM now.
            % %VENDOR-AUDIT: <write-image call> with libpointer('uint8Ptr',
            % mask8') — row-major repack per the SDK's expected layout, then
            % <image-write-complete / vsync wait call>.
            error('tfp:hardware:BlinkSLM:sdkNotVendored', ...
                'Blink SDK not vendored yet (see BlinkSLM.initialize).');
        end

        function preloadSequence(obj, stack) %#ok<INUSD>
            %preloadSequence Upload uint8(nRows, nCols, N) to onboard memory.
            %   Sequence order = depth-group order (the TTL contract).
            % %VENDOR-AUDIT: confirm this HSP1K supports onboard sequence
            % memory; if the audit finds it does NOT, slm_server falls back
            % to per-advance writeImage (software mode only) and
            % trigger_mode 'ttl' must be rejected at spec validation.
            error('tfp:hardware:BlinkSLM:sdkNotVendored', ...
                'Blink SDK not vendored yet (see BlinkSLM.initialize).');
        end

        function armExternalTrigger(obj) %#ok<MANU>
            %armExternalTrigger Arm hardware-trigger sequence advance.
            % %VENDOR-AUDIT: <external-trigger enable call>.
            error('tfp:hardware:BlinkSLM:sdkNotVendored', ...
                'Blink SDK not vendored yet (see BlinkSLM.initialize).');
        end

        function softwareAdvance(obj) %#ok<MANU>
            %softwareAdvance Step the sequence one frame from software.
            % %VENDOR-AUDIT: <sequence-step call> or writeImage of the next
            % preloaded frame if no native sequencing exists.
            error('tfp:hardware:BlinkSLM:sdkNotVendored', ...
                'Blink SDK not vendored yet (see BlinkSLM.initialize).');
        end

        function status = getStatus(obj)
            status.state         = obj.state_;
            status.isInitialized = obj.isInitialized;
            status.nLoaded       = obj.nLoaded_;
        end

        function cleanup(obj)
            %cleanup Non-throwing teardown (lab convention).
            % %VENDOR-AUDIT: <delete-SDK call>; unloadlibrary(obj.dllName_).
            obj.state_        = 'idle';
            obj.isInitialized = false;
            obj.boardId_      = [];
            obj.nLoaded_      = 0;
            obj.logEvent('cleanup', []);
        end

        function entries = getLog(obj)
            entries = obj.log_;
        end
    end

    methods (Access = private)
        function logEvent(obj, eventType, payload)
            entry.timestamp = datetime('now');
            entry.eventType = eventType;
            entry.payload   = payload;
            obj.log_(end+1) = entry;
        end
    end
end
