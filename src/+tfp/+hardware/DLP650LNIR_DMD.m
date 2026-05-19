classdef DLP650LNIR_DMD < tfp.hardware.DMD
%DLP650LNIR_DMD Real DMD hardware driver via ViALUX ALP high-speed API.
%   Supports two boards via config.alpVersion and config.dmdType:
%     '4.3' / 'DLP650LNIR'  — NIR 1280x800, alp4395.dll (final target)
%     '4.1' / 'DLP7000'     — visible 1024x768, alp41.dll (DLi4130 kit)
%   Switch boards via config only — no code changes required.
%
%   All ALP function names are taken verbatim from vendor/alp/official/alp.h
%   (Version 28) and vendor/alp/official-4.1/alp.h (Version 25).
%   See docs/alp-api-audit.md for the cross-reference audit.
%
%   Usage:
%     cfg.alpVersion = '4.1';
%     cfg.dmdType    = 'DLP7000';
%     cfg.dllPath    = 'C:\Program Files\ALP-4.1\alp41.dll';
%     cfg.protoFile  = 'vendor\alp\reference\<alp41-proto>.m';
%     dmd = tfp.hardware.DLP650LNIR_DMD(cfg);

    % ------------------------------------------------------------------ %
    properties (SetAccess = protected)
        nRows          = 0
        nCols          = 0
        maxPatternRate = 0
        isInitialized  = false
    end

    properties (Access = private)
        deviceId_   = uint32(0)   % ALP_ID returned by AlpDevAlloc
        sequenceId_ = uint32(0)   % ALP_ID returned by AlpSeqAlloc
        seqLoaded_  = false       % true when a sequence is allocated
        dllName_    = ''          % library alias for calllib (no extension)
        dllPath_    = ''          % full path to .dll file
        protoFile_  = ''          % full path to the proto .m file
        projMode_   = int32(2301) % ALP_MASTER by default (from alp.h line ~321)
        state_      = 'idle'      % 'idle' | 'armed' | 'running'
        log_        = struct('timestamp', {}, 'eventType', {}, 'payload', {})
    end

    % ------------------------------------------------------------------ %
    methods
        function obj = DLP650LNIR_DMD(config)
            %DLP650LNIR_DMD Construct and initialize the DMD.
            %   config fields: alpVersion, dmdType, dllPath, protoFile.
            obj.initialize(config);
        end

        % -------------------------------------------------------------- %
        function initialize(obj, config)
            %initialize Load the ALP DLL and allocate the device.

            alpVer  = configField(config, 'alpVersion', '4.3');
            dmdType = configField(config, 'dmdType',    'DLP650LNIR');

            % Board-specific parameters (from task spec + alp.h constants)
            switch alpVer
                case '4.3'
                    obj.dllName_       = 'alp4395';
                    obj.nRows          = 800;
                    obj.nCols          = 1280;
                    obj.maxPatternRate = 12500;
                    expectedDmdType    = int32(12); % ALP_DMDTYPE_WXGA_S450 (alp.h:153)
                case '4.1'
                    obj.dllName_       = 'alpD41';
                    obj.nRows          = 768;
                    obj.nCols          = 1024;
                    obj.maxPatternRate = 22727;
                    expectedDmdType    = int32(4);  % ALP_DMDTYPE_XGA_07A  (alp.h:145)
                otherwise
                    error('tfp:hardware:DLP650LNIR_DMD:badAlpVersion', ...
                        'config.alpVersion must be ''4.1'' or ''4.3''; got ''%s''.', alpVer);
            end

            obj.dllPath_   = configField(config, 'dllPath',   '');
            obj.protoFile_ = configField(config, 'protoFile', '');
            if isempty(obj.dllPath_)
                error('tfp:hardware:DLP650LNIR_DMD:missingDllPath', ...
                    'config.dllPath is required (full path to %s.dll).', obj.dllName_);
            end
            if isempty(obj.protoFile_)
                error('tfp:hardware:DLP650LNIR_DMD:missingProtoFile', ...
                    'config.protoFile is required (path to proto .m file).');
            end

            % Load the DLL via its MATLAB prototype function.
            % The proto function must be on the path; add its directory temporarily.
            if ~libisloaded(obj.dllName_)
                [protoDir, protoFcn] = fileparts(obj.protoFile_);
                if ~isempty(protoDir)
                    addpath(protoDir);
                end
                loadlibrary(obj.dllPath_, str2func(protoFcn));
            end

            % AlpDevAlloc — allocate the first available ALP device.
            % Signature: long AlpDevAlloc(long DeviceNum, long InitFlag, ALP_ID *DeviceIdPtr)
            devIdPtr = libpointer('ulongPtr', uint32(0));
            ret = calllib(obj.dllName_, 'AlpDevAlloc', int32(0), int32(0), devIdPtr);
            obj.checkAlpReturn(ret, 'AlpDevAlloc');
            obj.deviceId_ = devIdPtr.Value;

            % AlpDevControl — set USB disconnect behaviour to ignore so a
            % transient USB glitch does not abort a running projection.
            % ALP_USB_DISCONNECT_BEHAVIOUR=2078, ALP_USB_IGNORE=1  (alp.h:136-138)
            ret = calllib(obj.dllName_, 'AlpDevControl', ...
                obj.deviceId_, int32(2078), int32(1));
            obj.checkAlpReturn(ret, 'AlpDevControl(ALP_USB_DISCONNECT_BEHAVIOUR)');

            % AlpDevInquire — confirm the DMD type matches the config.
            % ALP_DEV_DMDTYPE=2021  (alp.h:141)
            dmdTypePtr = libpointer('longPtr', int32(0));
            ret = calllib(obj.dllName_, 'AlpDevInquire', ...
                obj.deviceId_, int32(2021), dmdTypePtr);
            obj.checkAlpReturn(ret, 'AlpDevInquire(ALP_DEV_DMDTYPE)');
            actualDmdType = int32(dmdTypePtr.Value);
            if actualDmdType ~= expectedDmdType
                error('tfp:hardware:DLP650LNIR_DMD:dmdTypeMismatch', ...
                    ['Expected DMD type %d (%s) but device reports type %d. ' ...
                     'Check config.dmdType and config.alpVersion.'], ...
                    expectedDmdType, dmdType, actualDmdType);
            end

            obj.state_        = 'idle';
            obj.seqLoaded_    = false;
            obj.isInitialized = true;
            obj.logEvent('initialize', struct('alpVersion', alpVer, 'dmdType', dmdType));
        end

        % -------------------------------------------------------------- %
        function loadPatternSequence(obj, patterns, options)
            %loadPatternSequence Upload binary patterns to the ALP device.
            %   patterns: logical(nRows, nCols, nPatterns)
            %   options:  struct with .exposureUs, .darkTimeUs, and
            %             optionally .triggerMode ('internal'|'external')

            if ~obj.isInitialized
                error('tfp:hardware:DLP650LNIR_DMD:notInitialized', ...
                    'initialize() must be called before loadPatternSequence().');
            end
            if ~islogical(patterns)
                error('tfp:hardware:DLP650LNIR_DMD:badPatterns', ...
                    'patterns must be a logical array.');
            end
            if ndims(patterns) > 3 || size(patterns,1) ~= obj.nRows ...
                    || size(patterns,2) ~= obj.nCols
                error('tfp:hardware:DLP650LNIR_DMD:badPatternShape', ...
                    'patterns must be [%d x %d x N]; got [%s].', ...
                    obj.nRows, obj.nCols, num2str(size(patterns)));
            end
            if ~isstruct(options) || ~isfield(options,'exposureUs') ...
                    || ~isfield(options,'darkTimeUs')
                error('tfp:hardware:DLP650LNIR_DMD:badOptions', ...
                    'options must be a struct with .exposureUs and .darkTimeUs.');
            end

            nPatterns = size(patterns, 3);

            % Free any previously allocated sequence before allocating a new one.
            % Halt first to avoid ALP_SEQ_IN_USE if projection is still running.
            if obj.seqLoaded_
                calllib(obj.dllName_, 'AlpProjHalt', obj.deviceId_);
                ret = calllib(obj.dllName_, 'AlpSeqFree', obj.deviceId_, obj.sequenceId_);
                obj.checkAlpReturn(ret, 'AlpSeqFree (previous sequence)');
                obj.seqLoaded_ = false;
                obj.state_     = 'idle';
            end

            % AlpSeqAlloc — allocate sequence memory on the device.
            % Signature: long AlpSeqAlloc(ALP_ID DeviceId, long BitPlanes, long PicNum, ALP_ID *SequenceIdPtr)
            seqIdPtr = libpointer('ulongPtr', uint32(0));
            ret = calllib(obj.dllName_, 'AlpSeqAlloc', ...
                obj.deviceId_, int32(1), int32(nPatterns), seqIdPtr);
            obj.checkAlpReturn(ret, 'AlpSeqAlloc');
            obj.sequenceId_ = seqIdPtr.Value;
            obj.seqLoaded_  = true;

            % Build the image byte array in ALP row-major layout.
            % ALP_DATA_MSB_ALIGN (default): one byte per pixel, bit 7 active.
            % 0xFF = mirror ON, 0x00 = mirror OFF.
            % MATLAB is column-major, so transpose each slice before linearising
            % to produce the row-by-row layout the ALP expects.
            imgData = zeros(1, obj.nRows * obj.nCols * nPatterns, 'uint8');
            pxPerPat = obj.nRows * obj.nCols;
            for k = 1:nPatterns
                % Transpose: nRows×nCols → nCols×nRows, then (:) gives row-major
                slice = uint8(patterns(:,:,k).') * uint8(255);
                imgData((k-1)*pxPerPat + 1 : k*pxPerPat) = slice(:)';
            end

            % AlpSeqPut — upload all patterns at once.
            % Signature: long AlpSeqPut(ALP_ID DeviceId, ALP_ID SequenceId,
            %                           long PicOffset, long PicLoad, void *UserArrayPtr)
            ret = calllib(obj.dllName_, 'AlpSeqPut', ...
                obj.deviceId_, obj.sequenceId_, int32(0), int32(nPatterns), imgData);
            obj.checkAlpReturn(ret, 'AlpSeqPut');

            % AlpSeqTiming — set exposure and frame period.
            % IlluminateTime = exposureUs; PictureTime = exposureUs + darkTimeUs.
            % SynchDelay, SynchPulseWidth, TriggerInDelay = 0 (ALP_DEFAULT).
            expUs     = int32(options.exposureUs);
            picTimeUs = int32(options.exposureUs + options.darkTimeUs);
            ret = calllib(obj.dllName_, 'AlpSeqTiming', ...
                obj.deviceId_, obj.sequenceId_, expUs, picTimeUs, ...
                int32(0), int32(0), int32(0));
            obj.checkAlpReturn(ret, 'AlpSeqTiming');

            % Store projection mode for armSequence.
            % ALP_MASTER=2301 (internal timing), ALP_SLAVE=2302 (external trigger)
            trigMode = configField(options, 'triggerMode', 'internal');
            if strcmpi(trigMode, 'external')
                obj.projMode_ = int32(2302); % ALP_SLAVE  (alp.h:326)
            else
                obj.projMode_ = int32(2301); % ALP_MASTER (alp.h:322)
            end

            obj.state_ = 'idle';
            obj.logEvent('loadPatternSequence', struct('nPatterns', nPatterns, ...
                'exposureUs', options.exposureUs, 'darkTimeUs', options.darkTimeUs));
        end

        % -------------------------------------------------------------- %
        function armSequence(obj)
            %armSequence Set projection mode and ready the device for triggering.

            if ~obj.seqLoaded_
                error('tfp:hardware:DLP650LNIR_DMD:noSequence', ...
                    'loadPatternSequence() must be called before armSequence().');
            end

            % AlpProjControl — set master/slave trigger mode.
            % ALP_PROJ_MODE=2300  (alp.h:321)
            ret = calllib(obj.dllName_, 'AlpProjControl', ...
                obj.deviceId_, int32(2300), obj.projMode_);
            obj.checkAlpReturn(ret, 'AlpProjControl(ALP_PROJ_MODE)');

            obj.state_ = 'armed';
            obj.logEvent('armSequence', []);
        end

        % -------------------------------------------------------------- %
        function softTrigger(obj)
            %softTrigger Start projecting the loaded sequence (software trigger).

            if ~strcmp(obj.state_, 'armed')
                error('tfp:hardware:DLP650LNIR_DMD:notArmed', ...
                    'armSequence() must be called before softTrigger(); state is ''%s''.', ...
                    obj.state_);
            end

            % AlpProjStart — project the sequence once.
            % Signature: long AlpProjStart(ALP_ID DeviceId, ALP_ID SequenceId)
            ret = calllib(obj.dllName_, 'AlpProjStart', obj.deviceId_, obj.sequenceId_);
            obj.checkAlpReturn(ret, 'AlpProjStart');

            obj.state_ = 'running';
            obj.logEvent('softTrigger', []);
        end

        % -------------------------------------------------------------- %
        function advanceToPattern(obj, idx)
            %advanceToPattern Jump to a specific pattern in the loaded sequence.
            %   idx: 1-based pattern index.

            if ~ismember(obj.state_, {'armed', 'running'})
                error('tfp:hardware:DLP650LNIR_DMD:notArmed', ...
                    'armSequence() must be called before advanceToPattern(); state is ''%s''.', ...
                    obj.state_);
            end

            % ALP uses 0-based frame indices (ALP_FIRSTFRAME, ALP_LASTFRAME).
            % Set both to the same index to display only that pattern.
            % ALP_FIRSTFRAME=2101, ALP_LASTFRAME=2102  (alp.h:184-185)
            alpIdx = int32(idx - 1);
            ret = calllib(obj.dllName_, 'AlpSeqControl', ...
                obj.deviceId_, obj.sequenceId_, int32(2101), alpIdx);
            obj.checkAlpReturn(ret, 'AlpSeqControl(ALP_FIRSTFRAME)');
            ret = calllib(obj.dllName_, 'AlpSeqControl', ...
                obj.deviceId_, obj.sequenceId_, int32(2102), alpIdx);
            obj.checkAlpReturn(ret, 'AlpSeqControl(ALP_LASTFRAME)');

            obj.logEvent('advanceToPattern', struct('idx', idx));
        end

        % -------------------------------------------------------------- %
        function status = getStatus(obj)
            %getStatus Return a status struct matching MockDMD.getStatus() shape.

            status.state             = obj.state_;
            status.currentPatternIdx = 0;
            status.nPatternsLoaded   = 0;
            status.lastTriggerTime   = NaT;

            if ~obj.isInitialized
                return;
            end

            % AlpProjInquire — query the live projection state.
            % ALP_PROJ_STATE=2400, ALP_PROJ_ACTIVE=1200, ALP_PROJ_IDLE=1201  (alp.h:84-87, 311)
            projStatePtr = libpointer('longPtr', int32(0));
            ret = calllib(obj.dllName_, 'AlpProjInquire', ...
                obj.deviceId_, int32(2400), projStatePtr);
            if ret == int32(0)
                if projStatePtr.Value == int32(1200) % ALP_PROJ_ACTIVE
                    status.state = 'running';
                end
            end
        end

        % -------------------------------------------------------------- %
        function cleanup(obj)
            %cleanup Halt projection, free sequence and device, unload DLL.

            if obj.isInitialized
                % Ignore return codes — cleanup must not throw.
                calllib(obj.dllName_, 'AlpProjHalt', obj.deviceId_);
                if obj.seqLoaded_
                    calllib(obj.dllName_, 'AlpSeqFree', obj.deviceId_, obj.sequenceId_);
                    obj.seqLoaded_ = false;
                end
                calllib(obj.dllName_, 'AlpDevHalt', obj.deviceId_);
                calllib(obj.dllName_, 'AlpDevFree', obj.deviceId_);
                if libisloaded(obj.dllName_)
                    unloadlibrary(obj.dllName_);
                end
            end

            obj.isInitialized = false;
            obj.state_        = 'idle';
            obj.logEvent('cleanup', []);
        end

        % -------------------------------------------------------------- %
        function abort(obj)
            %abort Immediately halt projection (mid-trial emergency stop).

            if obj.isInitialized
                % AlpProjControl with ALP_PROJ_ABORT_ASYNC aborts the current
                % display immediately, asynchronous to any frame.
                % ALP_PROJ_ABORT_ASYNC=2345, ALP_DEFAULT=0  (alp.h:313)
                calllib(obj.dllName_, 'AlpProjControl', ...
                    obj.deviceId_, int32(2345), int32(0));
            end
            obj.cleanup();
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

        function checkAlpReturn(~, ret, funcName)
            %checkAlpReturn Throw a typed error on non-zero ALP return codes.
            %   Error codes from vendor/alp/official/alp.h.
            if ret == int32(0) % ALP_OK
                return;
            end
            switch int32(ret)
                case int32(1001) % ALP_NOT_ONLINE
                    error('tfp:hardware:DLP650LNIR_DMD:notOnline', ...
                        '%s: ALP_NOT_ONLINE (1001) — device not found or not ready.', funcName);
                case int32(1021) % ALP_CONFIG_MISMATCH
                    error('tfp:hardware:DLP650LNIR_DMD:configMismatch', ...
                        '%s: ALP_CONFIG_MISMATCH (1021) — device not properly configured.', funcName);
                case int32(1999) % ALP_ERROR_UNKNOWN
                    error('tfp:hardware:DLP650LNIR_DMD:unknownError', ...
                        '%s: ALP_ERROR_UNKNOWN (1999).', funcName);
                otherwise
                    error('tfp:hardware:DLP650LNIR_DMD:alpError', ...
                        '%s returned error code %d.', funcName, ret);
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
% Local helper — matches the configField pattern used in MockDMD / MockDAQ.

function value = configField(config, name, default)
if isfield(config, name)
    value = config.(name);
else
    value = default;
end
end
