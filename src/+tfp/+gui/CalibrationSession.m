classdef CalibrationSession < handle
    %CalibrationSession Headless brain of the calibration GUI.
    %
    %   Owns all state and every decision; contains no graphics call whatsoever.
    %   tfp.gui.CalibrationApp is a thin view over this object, and everything
    %   here is driveable from the command line and testable under
    %   matlab -nodisplay — which is the whole reason for the split, since a
    %   uifigure cannot be constructed headless and therefore no test could
    %   ever cover logic that lived in the app.
    %
    %   Practically this means the entire calibration can be run WITHOUT the
    %   GUI, with the same interlocks and the same provenance:
    %
    %       config = tfp.io.loadConfig('configs/real.yaml');
    %       s = tfp.gui.CalibrationSession(config);
    %       s.setLaserState(struct('repRateKhz', 100, 'frontPanelPowerW', 8.5));
    %       disp(struct2table(s.preflight()));
    %       curve = s.runPowerSweep();
    %       calA  = s.runDmdToCamera();
    %       s.shutdown();
    %
    %   Construction:
    %     s = tfp.gui.CalibrationSession(config)
    %     s = tfp.gui.CalibrationSession(config, options)
    %
    %   options:
    %     .confirmFcn   @(spec) logical for power steps. Default
    %                   @tfp.util.consoleConfirmPower; the app substitutes a
    %                   uiconfirm closure; tests pass @(s) true / @(s) false.
    %     .promptFcn    @(msg) for blocking operator prompts
    %     .hardware     struct of pre-built handles (.dmd .camera .daq .zstage
    %                   .siBridge) — the repo's convention everywhere else, and
    %                   how mock tests inject a truth affine that cannot come
    %                   from YAML
    %     .allowConfigWrite  default false. Never true for a mock session.
    %     .sessionName  suffix for the session directory
    %     .configPath   the YAML this config came from, for write-back and for
    %                   the provenance snapshot
    %     .autoBuild    construct missing hardware from the config (default true)
    %
    %   SIMULATED DEVICES ARE NEVER SILENT. When a real backend fails to
    %   construct, the mock is substituted, simulated.<device> is set, and the
    %   app paints a persistent banner. With the DMD simulated,
    %   tfp.hardware.LaserPowerController additionally refuses to emit real
    %   light, because the pattern actually on the chip is then unknown and the
    %   interlock's blob fraction would be a guess.
    %
    %   See also tfp.gui.CalibrationApp, tfp.hardware.LaserPowerController,
    %   tfp.util.assertPulseEnergySafe.

    properties (SetAccess = protected)
        config
        configPath   = ''
        sessionId    = ''      % path to the session directory
        sessionName  = ''
        simulated    = struct('dmd', false, 'camera', false, ...
                              'daq', false, 'zstage', false)
        results      = struct()
        allowConfigWrite = false
    end

    properties (Access = private)
        dmd_        = []
        camera_     = []
        daq_        = []
        zstage_     = []
        siBridge_   = []
        laser_      = []
        confirmFcn_
        promptFcn_
        cameraBusy_ = false
        liveOn_     = false
        darkFrame_  = []
        gitHash_    = ''
        configText_ = ''
        isMock_     = false
        mockTruth_  = []
    end

    methods
        function obj = CalibrationSession(config, options)
            if nargin < 2 || isempty(options), options = struct(); end
            if nargin < 1 || isempty(config),  config  = struct(); end
            obj.config      = config;
            obj.configPath  = char(tfp.util.configField(options, 'configPath', ''));
            obj.sessionName = char(tfp.util.configField(options, 'sessionName', 'calib'));
            obj.confirmFcn_ = tfp.util.configField(options, 'confirmFcn', ...
                                @tfp.util.consoleConfirmPower);
            obj.promptFcn_  = tfp.util.configField(options, 'promptFcn', ...
                                @(msg) fprintf('%s\n', msg));

            % A mock session must not be able to rewrite a rig config, whatever
            % the caller asked for.
            wantWrite = logical(tfp.util.configField(options, 'allowConfigWrite', false));
            obj.isMock_ = strcmpi(char(tfp.util.configField(config, 'hardwareKind', 'mock')), 'mock');
            obj.allowConfigWrite = wantWrite && ~obj.isMock_;

            obj.gitHash_ = tfp.util.gitHash();
            if ~isempty(obj.configPath) && isfile(obj.configPath)
                obj.configText_ = fileread(obj.configPath);
            end

            obj.openSessionDir();
            obj.buildHardware(options);

            % A MockSubstageCamera built from YAML alone has no DMD reference
            % and no truth affine, so snap() returns pure noise — and
            % alignDMDtoCamera will happily fit an affine to that noise and
            % report a plausible residual. Wire the mocks into a self-consistent
            % optical model instead, so a demo session simulates a rig rather
            % than pretending to measure one.
            if logical(tfp.util.configField(options, 'wireMockRig', true))
                obj.mockTruth_ = tfp.sim.wireMockRig(obj.dmd_, obj.camera_, ...
                    obj.zstage_, tfp.util.configField(options, 'mockRig', struct()));
            end

            obj.laser_ = tfp.hardware.LaserPowerController(obj.daq_, config, struct( ...
                'confirmFcn', obj.confirmFcn_, ...
                'simulated',  obj.simulated, ...
                'logFcn',     @(e, p) obj.log(e, p)));

            obj.log('session_start', struct( ...
                'sessionName',  obj.sessionName, ...
                'configPath',   obj.configPath, ...
                'hardwareKind', char(tfp.util.configField(config, 'hardwareKind', '')), ...
                'gitHash',      obj.gitHash_, ...
                'simulated',    obj.simulated));
        end

        % ==================================================================
        % Laser state
        % ==================================================================
        function state = setLaserState(obj, state)
            %setLaserState Adopt the operator-entered laser state.
            %   Nothing that emits light works until this is set: the
            %   pulse-energy interlock is fail-closed on rep rate, and
            %   believing 100 kHz while the picker sits at /100 understates
            %   pulse energy a hundredfold.
            obj.laser_.setLaserState(state);
            state = obj.laser_.getLaserState();
        end

        function s = laserState(obj)
            s = obj.laser_.getLaserState();
        end

        function t = mockTruth(obj)
            %mockTruth Ground truth of the simulated rig, or [] on real hardware.
            %   Lets a demo compare a recovered affine or tilt gradient against
            %   the value that was injected.
            t = obj.mockTruth_;
        end

        function lp = laser(obj)
            %laser The LaserPowerController. Exposed so a command-line user can
            %   drive power directly with the same interlock the GUI uses.
            lp = obj.laser_;
        end

        function varargout = hardware(obj)
            %hardware Handles, for command-line use and for the view.
            h = struct('dmd', obj.dmd_, 'camera', obj.camera_, 'daq', obj.daq_, ...
                'zstage', obj.zstage_, 'siBridge', obj.siBridge_, 'laser', obj.laser_);
            if nargout == 0
                disp(h);
            else
                varargout{1} = h;
            end
        end

        % ==================================================================
        % Preflight
        % ==================================================================
        function status = preflight(obj)
            %preflight One row per device: what it is, whether it answered, and
            %   what to do about it. Exercises only helpers that already exist —
            %   no new socket code was written for this.
            status = struct('device', {}, 'status', {}, 'detail', {}, 'remedy', {});

            status(end+1) = obj.checkDevice('DMD', @() obj.dmd_.getStatus(), ...
                'Check the ALP DLL path and that the DLP650LNIR flex cable is seated (scripts/alpPollDMD.m).');
            status(end+1) = obj.checkDevice('DAQ', @() struct('class', class(obj.daq_), ...
                'initialized', obj.daq_.isInitialized), ...
                'Check the NI-DAQmx driver and the Dev1 device name in configs/real.yaml.');
            status(end+1) = obj.checkDevice('Camera', @() struct( ...
                'class', class(obj.camera_), 'nRows', obj.camera_.nRows, ...
                'nCols', obj.camera_.nCols), ...
                'Install Basler pylon 6+ with the pylon GenTL Producer; check camera.deviceId.');
            status(end+1) = obj.checkDevice('Z ruler', @() obj.zRulerProbe(), ...
                ['On the imaging PC, inside the ScanImage MATLAB: ' ...
                 'addpath(''<repo>/scripts/imaging_pc_setup''); si_motor_helper']);
            status(end+1) = obj.laserRow();
            status(end+1) = obj.powerMeterRow();
            status(end+1) = obj.scanImageRow();

            obj.log('preflight', status);
        end

        % ==================================================================
        % Live camera
        % ==================================================================
        function startLive(obj)
            if obj.liveOn_, return; end
            obj.camera_.startLive();
            obj.liveOn_ = true;
        end

        function stopLive(obj)
            if ~obj.liveOn_, return; end
            obj.camera_.stopLive();
            obj.liveOn_ = false;
        end

        function tf = isLive(obj),      tf = obj.liveOn_;     end
        function tf = isCameraBusy(obj), tf = obj.cameraBusy_; end

        function [frame, info] = grabDisplayFrame(obj, options)
            %grabDisplayFrame One processed frame plus everything a view draws.
            %   Returns [] while a calibration owns the camera, so the live
            %   timer can never fight a calibration snap().
            if nargin < 2 || isempty(options), options = struct(); end
            frame = []; info = struct();
            if obj.cameraBusy_
                return
            end
            nAvg = tfp.util.configField(options, 'nAverages', 1);
            if obj.liveOn_ && nAvg <= 1
                frame = obj.camera_.getFrame();
            else
                frame = obj.camera_.snapAveraged(nAvg);
            end
            if logical(tfp.util.configField(options, 'subtractDark', false))
                frame = tfp.gui.FrameProcessor.subtractDark(frame, obj.darkFrame_);
            end
            fp = tfp.gui.FrameProcessor;
            [satMask, satFrac] = fp.saturationMask(frame);
            info = struct( ...
                'limits',      fp.autoscaleLimits(frame, ...
                                  tfp.util.configField(options, 'percentiles', [0.5 99.9])), ...
                'saturation',  satMask, ...
                'saturatedFraction', satFrac, ...
                'focusMetric', fp.focusMetric(frame), ...
                'hasDark',     ~isempty(obj.darkFrame_));
        end

        function dark = captureDark(obj, nAverages)
            %captureDark Record a background frame with the beam off.
            %   findSpotCentroid already accepts options.backgroundFrame, so
            %   this feeds the existing path rather than inventing a second one.
            if nargin < 2 || isempty(nAverages), nAverages = 8; end
            obj.laser_.zeroQuiet();
            obj.withCamera(@() assignDark());
            dark = obj.darkFrame_;
            obj.log('dark_captured', struct('nAverages', nAverages, ...
                'meanLevel', mean(dark(:))));
            function assignDark()
                obj.darkFrame_ = obj.camera_.snapAveraged(nAverages);
            end
        end

        function clearDark(obj)
            obj.darkFrame_ = [];
        end

        function d = darkFrame(obj), d = obj.darkFrame_; end

        % ==================================================================
        % Calibration steps
        % ==================================================================
        function curve = runPowerSweep(obj, options)
            %runPowerSweep CARBIDE volts->mW, interlocked and stamped.
            if nargin < 2 || isempty(options), options = struct(); end
            obj.assertLaserState('runPowerSweep');
            % No PM100D on a mock rig (and none on a dev machine at all — the
            % Thorlabs TLPM driver is Windows-only). Substitute the simulated
            % meter, which watches the mock DAQ's log and reports the power the
            % commanded voltage would produce. The REAL sweep, controller and
            % interlock all run; only the instrument is simulated.
            if obj.isMock_ && ~isfield(options, 'meter')
                options.meter = tfp.sim.SyntheticPowerMeter(obj.daq_, ...
                    obj.laser_.aoChannel, struct('maxMw', 50));
            end
            curve = obj.withCamera(@() tfp.calibration.powerMeterSweepSingle( ...
                obj.laser_, options));
            obj.laser_.loadPowerCurve(curve);
            curve = obj.finish('powerSweep', curve, 'power_curve');
        end

        function calib = runDmdToCamera(obj, options)
            %runDmdToCamera Step A of the two-step spatial calibration.
            if nargin < 2 || isempty(options), options = struct(); end
            obj.assertLaserState('runDmdToCamera');
            options = obj.withDefaults(options, 'showFigure', false);
            options = obj.withDefaults(options, 'backgroundFrame', obj.darkFrame_);
            options = obj.withDefaults(options, 'stagePositionUm', obj.stagePosition());
            obj.laser_.beginStep('dmd_to_camera');
            calib = obj.withCamera(@() tfp.calibration.alignDMDtoCamera( ...
                obj.dmd_, obj.camera_, options));
            calib = obj.finish('dmdToCamera', calib, '');
        end

        function calib = runScanCrossRegister(obj, options)
            %runScanCrossRegister Step B. Needs ScanImage in Focus with a
            %   NON-SQUARE pixel count so the rectangle's long axis identifies
            %   the fast (resonant) axis.
            if nargin < 2 || isempty(options), options = struct(); end
            options = obj.withDefaults(options, 'showFigure', false);
            options = obj.withDefaults(options, 'stagePositionUm', obj.stagePosition());
            dmdCalib = [];
            if isfield(obj.results, 'dmdToCamera')
                dmdCalib = obj.results.dmdToCamera;
            end
            calib = obj.withCamera(@() tfp.calibration.crossRegisterScanImage( ...
                obj.camera_, dmdCalib, options));
            calib = obj.finish('scanCrossRegister', calib, '');
        end

        function calib = runVerifySigns(obj, options)
            %runVerifySigns Step C, the mandatory axis-sign resolution.
            if nargin < 2 || isempty(options), options = struct(); end
            if ~isfield(obj.results, 'scanCrossRegister')
                error('tfp:gui:CalibrationSession:missingStep', ...
                    'run the scan cross-registration before verifying axis signs.');
            end
            options = obj.withDefaults(options, 'configPath', obj.configPath);
            options = obj.withDefaults(options, 'allowConfigWrite', obj.allowConfigWrite);
            obj.laser_.beginStep('verify_signs');
            calib = tfp.calibration.verifyScanFieldComposition( ...
                obj.dmd_, obj.results.scanCrossRegister, options);
            obj.results.scanCrossRegister = calib;
            calib = obj.finish('verifySigns', calib, '');
        end

        function calib = runFieldTilt(obj, options)
            %runFieldTilt Depth-plane measurement across the field.
            if nargin < 2 || isempty(options), options = struct(); end
            obj.assertLaserState('runFieldTilt');
            options = obj.withDefaults(options, 'laser', obj.laser_);
            options = obj.withDefaults(options, 'stagePositionUm', obj.stagePosition());
            calib = obj.withCamera(@() tfp.calibration.measureFieldTilt( ...
                obj.dmd_, obj.camera_, obj.zstage_, obj.config, options));
            calib = obj.finish('fieldTilt', calib, 'field_tilt');
        end

        function calib = composeLateral(obj)
            %composeLateral Compose steps A and B into dmdToScan, then stamp.
            if ~isfield(obj.results, 'dmdToCamera') || ~isfield(obj.results, 'scanCrossRegister')
                error('tfp:gui:CalibrationSession:missingStep', ...
                    'both the DMD->camera and scan->camera fits are required.');
            end
            calib = tfp.calibration.composeCalibration( ...
                obj.results.dmdToCamera, obj.results.scanCrossRegister);
            calib = obj.finish('lateral', calib, 'dmd_affine');
        end

        % ==================================================================
        % Persistence
        % ==================================================================
        function calib = stamp(obj, calib)
            %stamp Attach provenance. Every saved calibration goes through here.
            calib.laserState     = obj.laser_.getLaserState();
            calib.sessionId      = obj.sessionId;
            calib.gitHash        = obj.gitHash_;
            calib.configPath     = obj.configPath;
            calib.configSnapshot = obj.configText_;   % survives a later rig edit
            calib.cameraSettings = obj.cameraSettings();
            calib.simulated      = obj.simulated;
            calib.stampedAt      = datetime('now');
        end

        function path = saveCalibration(obj, calib, kind)
            %saveCalibration Stamp, then delegate to tfp.io.saveCalibration.
            %   The app never calls tfp.io.saveCalibration directly, so an
            %   unstamped calibration cannot be saved from it.
            calib = obj.stamp(calib);
            cfg   = obj.config;
            cfg.paths.dataDir = obj.dataRoot();   % see dataRoot: TODO C6
            path = tfp.io.saveCalibration(calib, kind, cfg);
            obj.log('calibration_saved', struct('kind', kind, 'path', path));
        end

        function writeConfigKey(obj, section, key, value)
            %writeConfigKey Persist a result into the rig YAML. Opt-in only.
            if ~obj.allowConfigWrite
                error('tfp:gui:CalibrationSession:configWriteNotAllowed', ...
                    ['config write-back is disabled for this session. ' ...
                     'configs/real.yaml belongs to the rig and is rewritten ' ...
                     'in place there; enable it deliberately, and never from ' ...
                     'a dev machine or a mock session.']);
            end
            if isempty(obj.configPath)
                error('tfp:gui:CalibrationSession:noConfigPath', ...
                    'no configPath was supplied, so there is nothing to write.');
            end
            if ischar(value) || isstring(value)
                tfp.io.updateConfigCalibrationPath(obj.configPath, section, key, value);
            else
                tfp.io.updateConfigScalar(obj.configPath, section, key, value);
            end
            obj.log('config_written', struct('section', section, 'key', key, ...
                'value', value));
        end

        % ==================================================================
        % Lifecycle
        % ==================================================================
        function abort(obj)
            %abort Beam off and raise the in-process abort flag.
            tfp.util.safetyChecks('abort');
            obj.laser_.zeroQuiet();
            obj.log('abort', []);
        end

        function shutdown(obj)
            %shutdown Laser first, DAQ last.
            %   outputSingleAnalog needs a live NI session, so zeroing after
            %   daq.cleanup() would silently fail and leave the beam on.
            obj.log('session_end', []);
            % Laser first: outputSingleAnalog needs a live NI session, so
            % zeroing after daq.cleanup() would silently fail. release() then
            % marks the controller done, so its destructor does not warn about
            % a DAQ that was shut down on purpose.
            try, obj.laser_.zeroQuiet(); catch, end
            try, obj.laser_.release();   catch, end
            try, obj.stopLive();         catch, end
            for h = {obj.camera_, obj.dmd_, obj.zstage_, obj.daq_}
                try
                    if ~isempty(h{1}) && isvalid(h{1}), h{1}.cleanup(); end
                catch ME
                    warning('tfp:gui:CalibrationSession:cleanupFailed', ...
                        '%s.cleanup() failed: %s', class(h{1}), ME.message);
                end
            end
        end

        function s = state(obj)
            %state Everything the view renders, in one struct.
            s = struct( ...
                'sessionId',   obj.sessionId, ...
                'configPath',  obj.configPath, ...
                'simulated',   obj.simulated, ...
                'laser',       obj.laser_.getState(), ...
                'live',        obj.liveOn_, ...
                'cameraBusy',  obj.cameraBusy_, ...
                'hasDark',     ~isempty(obj.darkFrame_), ...
                'steps',       {fieldnames(obj.results)'}, ...
                'allowConfigWrite', obj.allowConfigWrite, ...
                'camera',      obj.cameraSettings());
        end

        function log(obj, eventType, payload)
            %log Append to the session log. Never throws: a log failure must
            %   not take a calibration down with it.
            try
                tfp.io.sessionLog(obj.sessionId, eventType, jsonSafe(payload));
            catch ME
                warning('tfp:gui:CalibrationSession:logFailed', ...
                    'session log failed on ''%s'': %s', eventType, ME.message);
            end
        end
    end

    % =======================================================================
    methods (Access = private)

        function openSessionDir(obj)
            stamp = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
            obj.sessionId = fullfile(obj.dataRoot(), 'calibration_sessions', ...
                sprintf('%s_%s', stamp, obj.sessionName));
            if ~isfolder(obj.sessionId)
                mkdir(obj.sessionId);
            end
        end

        function root = dataRoot(obj)
            %dataRoot Resolve the data directory across the two spellings.
            %   TODO C6: experiments read config.paths.dataDir but real.yaml
            %   only defines session.dataDir, so an app save would land in
            %   ./data relative to the rig's cwd rather than C:\data. Resolve
            %   both here; the real fix stays a rig-side config edit.
            pathsCfg   = tfp.util.configField(obj.config, 'paths',   struct());
            sessionCfg = tfp.util.configField(obj.config, 'session', struct());
            root = char(tfp.util.configField(pathsCfg, 'dataDir', ''));
            if isempty(root)
                root = char(tfp.util.configField(sessionCfg, 'dataDir', ''));
            end
            if isempty(root)
                root = 'data';
            end
        end

        function buildHardware(obj, options)
            given = tfp.util.configField(options, 'hardware', struct());
            auto  = logical(tfp.util.configField(options, 'autoBuild', true));

            obj.daq_    = obj.adopt(given, 'daq',    auto, @() obj.makeDaq());
            obj.dmd_    = obj.adopt(given, 'dmd',    auto, @() obj.makeDmd());
            obj.camera_ = obj.adopt(given, 'camera', auto, @() tfp.hardware.makeCamera(obj.config));
            obj.zstage_ = obj.adopt(given, 'zstage', auto, @() tfp.hardware.makeZStage(obj.config));
            obj.siBridge_ = tfp.util.configField(given, 'siBridge', []);
        end

        function h = adopt(obj, given, name, auto, factory)
            %adopt Take a supplied handle, else build one, else fall back to a
            %   mock and SAY SO. A silently simulated device is how a session
            %   produces confident numbers about hardware that was never there.
            h = tfp.util.configField(given, name, []);
            if ~isempty(h) || ~auto
                return
            end
            try
                h = factory();
            catch ME
                h = obj.mockFor(name);
                obj.simulated.(name) = true;
                warning('tfp:gui:CalibrationSession:deviceSimulated', ...
                    ['%s could not be constructed (%s) — SIMULATED for this ' ...
                     'session. Nothing measured against it is a calibration.'], ...
                    name, ME.message);
            end
        end

        function d = makeDaq(obj)
            daqCfg = tfp.util.configField(obj.config, 'daq', struct());
            if strcmpi(char(tfp.util.configField(obj.config, 'hardwareKind', 'mock')), 'mock')
                d = tfp.hardware.MockDAQ();
            else
                d = tfp.hardware.NI6323_DAQ(daqCfg);
            end
            d.initialize(daqCfg);
        end

        function d = makeDmd(obj)
            dmdCfg = tfp.util.configField(obj.config, 'dmd', struct());
            if strcmpi(char(tfp.util.configField(obj.config, 'hardwareKind', 'mock')), 'mock')
                d = tfp.hardware.MockDMD();
                d.initialize(dmdCfg);
                return
            end
            alpVersion = char(tfp.util.configField(dmdCfg, 'alpVersion', '4.3'));
            if strcmp(alpVersion, '4.1')
                d = tfp.hardware.DLi4130_DMD(dmdCfg);
            else
                d = tfp.hardware.DLP650LNIR_DMD(dmdCfg);
            end
            d.initialize(dmdCfg);
        end

        function h = mockFor(obj, name)
            switch name
                case 'daq'
                    h = tfp.hardware.MockDAQ();
                    h.initialize(tfp.util.configField(obj.config, 'daq', struct()));
                case 'dmd'
                    h = tfp.hardware.MockDMD();
                    h.initialize(tfp.util.configField(obj.config, 'dmd', struct()));
                case 'camera'
                    h = tfp.hardware.MockSubstageCamera();
                    h.initialize(tfp.util.configField(obj.config, 'camera', struct()));
                case 'zstage'
                    h = tfp.hardware.MockZStage();
                    h.initialize(struct('startZUm', 0));
                otherwise
                    h = [];
            end
        end

        function out = withCamera(obj, fcn)
            %withCamera Take exclusive use of the camera for a calibration.
            %   The live timer checks isCameraBusy and skips, so a calibration
            %   snap() and the display never fight over the device.
            %
            %   Deliberately try/catch rather than onCleanup: an onCleanup held
            %   in a function that also contains a nested function is captured
            %   by that nested function's shared workspace, which includes the
            %   onCleanup variable itself. The reference cycle keeps it alive
            %   past scope exit, so the camera would never be released — the
            %   live display then silently stops updating forever.
            wasLive = obj.liveOn_;
            obj.stopLive();
            obj.cameraBusy_ = true;
            try
                if nargout > 0
                    out = fcn();
                else
                    fcn();
                end
            catch ME
                obj.releaseCamera(wasLive);
                rethrow(ME);
            end
            obj.releaseCamera(wasLive);
        end

        function releaseCamera(obj, wasLive)
            obj.cameraBusy_ = false;
            if wasLive
                obj.startLive();
            end
        end

        function calib = finish(obj, stepName, calib, kind)
            obj.results.(stepName) = calib;
            obj.log('step_done', struct('step', stepName, ...
                'fields', {fieldnames(calib)'}));
            if ~isempty(kind)
                obj.saveCalibration(calib, kind);
            end
        end

        function options = withDefaults(~, options, name, value)
            if ~isfield(options, name) || isempty(options.(name))
                options.(name) = value;
            end
        end

        function assertLaserState(obj, what)
            if isempty(obj.laser_.getLaserState())
                error('tfp:gui:CalibrationSession:noLaserState', ...
                    ['%s puts light on the sample, and the pulse-energy ' ...
                     'interlock is fail-closed on rep rate. Call ' ...
                     'setLaserState first with the values shown by the ' ...
                     'CARBIDE software on the Holo PC.'], what);
            end
        end

        function p = stagePosition(obj)
            p = [];
            try
                if ismethod(obj.zstage_, 'getPositionXYZUm')
                    p = obj.zstage_.getPositionXYZUm();
                end
            catch
            end
        end

        function s = cameraSettings(obj)
            s = struct('class', class(obj.camera_));
            if isempty(obj.camera_), return; end
            s.nRows = obj.camera_.nRows;
            s.nCols = obj.camera_.nCols;
            caps = obj.camera_.getCapabilities();
            names = {'exposure', 'gain', 'binning', 'roi', 'pixelFormat', 'bitDepth'};
            getters = {@() obj.camera_.getExposureMs(), @() obj.camera_.getGain(), ...
                       @() obj.camera_.getBinning(),    @() obj.camera_.getRoi(), ...
                       @() obj.camera_.getPixelFormat(), @() obj.camera_.getBitDepth()};
            fields  = {'exposureMs', 'gain', 'binning', 'roi', 'pixelFormat', 'bitDepth'};
            for k = 1:numel(names)
                if caps.(names{k})
                    try, s.(fields{k}) = getters{k}(); catch, end
                end
            end
        end

        % --- preflight rows ---------------------------------------------
        function row = checkDevice(~, name, probe, remedy)
            try
                detail = probe();
                row = struct('device', name, 'status', 'ok', ...
                    'detail', summarise(detail), 'remedy', '');
            catch ME
                row = struct('device', name, 'status', 'fail', ...
                    'detail', ME.message, 'remedy', remedy);
            end
        end

        function d = zRulerProbe(obj)
            z0 = obj.zstage_.getPositionUm();
            obj.zstage_.moveToUm(z0 + 2);
            z1 = obj.zstage_.getPositionUm();
            obj.zstage_.moveToUm(z0);
            d = struct('class', class(obj.zstage_), 'startZUm', z0, ...
                'roundTripErrUm', abs((z1 - z0) - 2));
        end

        function row = laserRow(obj)
            if ~obj.laser_.isWired()
                row = struct('device', 'CARBIDE modulator', 'status', 'unwired', ...
                    'detail', 'laser.carbide_modulator_ao_channel is empty', ...
                    'remedy', ['Connect the CARBIDE external-modulator BNC to an ' ...
                               'NI-6323 AO terminal, record it in docs/WIRING.md, ' ...
                               'and set laser.carbide_modulator_ao_channel.']);
            elseif isempty(obj.laser_.getLaserState())
                row = struct('device', 'CARBIDE modulator', 'status', 'pending', ...
                    'detail', sprintf('wired on %s; laser state not entered', ...
                                obj.laser_.aoChannel), ...
                    'remedy', 'Enter rep rate, pulse-picker division and front-panel power.');
            else
                row = struct('device', 'CARBIDE modulator', 'status', 'ok', ...
                    'detail', sprintf('%s, %.3f-%.3f V, curve %s', ...
                        obj.laser_.aoChannel, obj.laser_.voltageMin, ...
                        obj.laser_.voltageMax, ...
                        yesNo(obj.laser_.hasPowerCurve())), ...
                    'remedy', '');
            end
        end

        function row = powerMeterRow(obj)
            if obj.isMock_
                row = struct('device', 'PM100D', 'status', 'simulated', ...
                    'detail', 'tfp.sim.SyntheticPowerMeter (mock session)', ...
                    'remedy', 'Nothing measured here is a power calibration.');
                return
            end
            % Detected lazily: constructing TLPM on a machine without the
            % driver throws, and that is information, not a failure.
            if exist('TLPM', 'class') == 8 || exist('TLPM', 'file') == 2
                row = struct('device', 'PM100D', 'status', 'ok', ...
                    'detail', 'TLPM driver present', 'remedy', '');
            else
                row = struct('device', 'PM100D', 'status', 'absent', ...
                    'detail', 'Thorlabs TLPM driver not on the path', ...
                    'remedy', ['Install Thorlabs Optical Power Monitor. ' ...
                               'Power calibration is unavailable without it.']);
            end
        end

        function row = scanImageRow(obj)
            siCfg = tfp.util.configField(obj.config, 'scanimage', struct());
            mode  = char(tfp.util.configField(siCfg, 'mode', 'ttl_only'));
            if strcmp(mode, 'ttl_only')
                row = struct('device', 'ScanImage link', 'status', 'ok', ...
                    'detail', 'TTL only — no software handshake, nothing to check', ...
                    'remedy', '');
            elseif isempty(obj.siBridge_)
                row = struct('device', 'ScanImage link', 'status', 'absent', ...
                    'detail', sprintf('mode ''%s'' but no bridge was supplied', mode), ...
                    'remedy', 'Pass options.hardware.siBridge, or set scanimage.mode: ttl_only.');
            else
                row = obj.checkDevice('ScanImage link', ...
                    @() obj.siBridge_.verifyProtocol(), ...
                    'Start the msocket server on the imaging PC (see docs/PORTS.md).');
            end
        end
    end
end

% ===========================================================================
function s = summarise(detail)
%summarise A short one-line rendering of a probe result.
if ischar(detail)
    s = detail;
elseif isstruct(detail) && isscalar(detail)
    f = fieldnames(detail);
    parts = cell(1, numel(f));
    for k = 1:numel(f)
        v = detail.(f{k});
        if ischar(v)
            parts{k} = sprintf('%s=%s', f{k}, v);
        elseif isnumeric(v) && isscalar(v)
            parts{k} = sprintf('%s=%g', f{k}, v);
        elseif islogical(v) && isscalar(v)
            parts{k} = sprintf('%s=%s', f{k}, yesNo(v));
        else
            parts{k} = sprintf('%s=%s', f{k}, class(v));
        end
    end
    s = strjoin(parts, ', ');
else
    s = class(detail);
end
end

function s = yesNo(tf)
if tf, s = 'yes'; else, s = 'no'; end
end

% ---------------------------------------------------------------------------
function p = jsonSafe(p)
%jsonSafe Make a payload safe for jsonencode inside tfp.io.sessionLog.
%   datetime and function_handle both break jsonencode; converting here keeps
%   every call site from having to remember.
if isstruct(p)
    for k = 1:numel(p)
        f = fieldnames(p);
        for j = 1:numel(f)
            p(k).(f{j}) = jsonSafe(p(k).(f{j}));
        end
    end
elseif isa(p, 'datetime')
    p = char(p);
elseif isa(p, 'function_handle')
    p = func2str(p);
elseif iscell(p)
    for k = 1:numel(p)
        p{k} = jsonSafe(p{k});
    end
end
end
