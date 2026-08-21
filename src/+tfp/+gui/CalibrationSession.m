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
                              'daq', false, 'zstage', false, 'slm', false)
        results      = struct()
        allowConfigWrite = false
        % Guided-bringup bookkeeping, keyed by step id. One entry per step
        % that has been attempted: .state .verdict .attempts .lastRunAt.
        % Separate from `results` because a step can be attempted, fail, and
        % be retaken — the count of attempts is part of the record.
        stepStatus   = struct()
    end

    properties (Access = private)
        dmd_        = []
        camera_     = []
        daq_        = []
        zstage_     = []
        siBridge_   = []
        siCalib_    = []       % ScanImageCalibBridge, imaging PC port 3048
        slm_        = []
        report_     = []       % tfp.gui.CalibrationReport, opened lazily
        steps_      = []       % cached tfp.gui.bringupSteps registry
        laser_      = []
        confirmFcn_
        promptFcn_
        askFcn_                % @(spec) answer — the guided path's questions
        signConfirmFcn_ = []   % @(spec) logical for the axis-sign loop
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
            % The guided path asks questions a camera cannot answer ("did
            % focus move deeper?", "load the stack"). The app substitutes a
            % dialog; the console default keeps the same wording.
            obj.askFcn_     = tfp.util.configField(options, 'askFcn', ...
                                @tfp.util.consoleAsk);
            obj.signConfirmFcn_ = tfp.util.configField(options, 'signConfirmFcn', []);

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
                mockRig = tfp.util.configField(options, 'mockRig', struct());
                % Hand the modulator over too, so simulated best focus MOVES
                % with the commanded defocus. Without it section 6a would
                % sweep a focus that never responds to the command it is
                % calibrating — the same "measures nothing while looking
                % fine" trap this whole function exists to close.
                if ~isfield(mockRig, 'slm'), mockRig.slm = obj.slm_; end
                obj.mockTruth_ = tfp.sim.wireMockRig(obj.dmd_, obj.camera_, ...
                    obj.zstage_, mockRig);
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
                'zstage', obj.zstage_, 'siBridge', obj.siBridge_, ...
                'siCalib', obj.siCalib_, 'slm', obj.slm_, 'laser', obj.laser_);
            if nargout == 0
                disp(h);
            else
                varargout{1} = h;
            end
        end

        % ==================================================================
        % Preflight
        % ==================================================================
        function status = preflight(obj, ~)
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
            % Put the simulated raster on the mock camera for the duration,
            % and take it off again — the software equivalent of pressing
            % Focus in ScanImage for this step and stopping afterwards. On
            % real hardware this is a no-op and the operator does it.
            restore = obj.withMockRaster();  %#ok<NASGU>
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
            if ~isempty(obj.signConfirmFcn_)
                options = obj.withDefaults(options, 'confirmFcn', obj.signConfirmFcn_);
            end
            if obj.isMock_
                % In a mock session the simulation answers this one, and
                % overrides whatever front end is attached. The question is
                % "look at the mROI — is the spot centred in it?", and there
                % is no bench to look at: a dialog here would be asking the
                % operator to guess, and a guess that lands on the first
                % combination silently composes a MIRRORED transform that
                % every later step then treats as verified. The simulated
                % answer applies the same physical criterion the operator
                % does — does the prediction land inside the raster.
                options.confirmFcn = @(spec) obj.mockSignAnswer(spec);
                obj.log('mock_sign_answer', struct('reason', ...
                    'mock session: the simulation answers the axis-sign question'));
            end
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

        function calib = composeLateral(obj, ~)
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
        % Guided bringup — the whole procedure, driven step by step
        % ==================================================================
        %
        %   The wizard in tfp.gui.CalibrationApp is a rendering of these six
        %   methods and nothing else. They are equally usable from the
        %   command line, which is the point: the guided path and the expert
        %   path run the same code, take the same interlocks, and leave the
        %   same record.
        %
        %       s = tfp.gui.CalibrationSession(config);
        %       disp(struct2table(rmfield(s.stepPlan(), ...
        %            {'setup','willDo','checks','knobs','criteria','remedy','records'})));
        %       brief = s.beginStep('power_curve');   % read setup out loud
        %       out   = s.runStep('power_curve');     % measure, judge, record
        %       disp(out.verdict.headline);

        function steps = stepPlan(obj)
            %stepPlan The procedure, with live status and blockers merged in.
            steps = obj.registry();
            for k = 1:numel(steps)
                id = steps(k).id;
                if isfield(obj.stepStatus, id)
                    st = obj.stepStatus.(id);
                else
                    st = obj.blankStatus();
                end
                st.blockers = obj.stepBlockers(steps(k));
                % A step that already ran keeps its verdict as its state; a
                % step that has not is 'ready' or 'blocked' depending on
                % whether its prerequisites and devices are in place.
                if isempty(st.verdict)
                    if isempty(st.blockers), st.state = 'ready';
                    else,                    st.state = 'blocked';
                    end
                end
                steps(k).status = st;
            end
        end

        function brief = beginStep(obj, stepId)
            %beginStep What to tell the operator before anything happens.
            %   Returns the physical setup, what the software will do, the
            %   hazard sentence, the knobs and the acceptance criteria — so
            %   the operator can read the whole contract of the step before
            %   consenting to it, not after.
            step = obj.stepById(stepId);
            brief = struct( ...
                'id',        step.id, ...
                'section',   step.section, ...
                'title',     step.title, ...
                'kind',      step.kind, ...
                'purpose',   step.purpose, ...
                'setup',     {step.setup}, ...
                'willDo',    {step.willDo}, ...
                'hazard',    step.hazard, ...
                'checks',    {step.checks}, ...
                'knobs',     step.knobs, ...
                'criteria',  step.criteria, ...
                'records',   {step.records}, ...
                'blockers',  {obj.stepBlockers(step)});
            obj.log('step_begin', struct('step', step.id));
        end

        function out = runStep(obj, stepId, knobValues)
            %runStep Acquire, judge, record. The one entry point per step.
            %
            %   Refuses to run a blocked step: a prerequisite that has not
            %   passed, or a device that is missing or simulated, produces a
            %   measurement that looks fine and means nothing.
            step = obj.stepById(stepId);
            blockers = obj.stepBlockers(step);
            if ~isempty(blockers)
                error('tfp:gui:CalibrationSession:stepBlocked', ...
                    'Step %s (section %s) is blocked:\n  - %s', ...
                    step.id, step.section, strjoin(blockers, sprintf('\n  - ')));
            end
            if nargin < 3 || isempty(knobValues), knobValues = struct(); end
            knobValues = obj.knobValuesFor(step, knobValues);

            attempt = 1;
            if isfield(obj.stepStatus, step.id)
                attempt = obj.stepStatus.(step.id).attempts + 1;
            end
            obj.log('step_run', struct('step', step.id, 'attempt', attempt, ...
                'knobs', knobValues));

            result  = obj.invokeStep(step, knobValues);
            verdict = tfp.gui.stepVerdict(step, result, obj.verdictContext());

            % Keyed by STEP ID here; the underlying methods additionally
            % store under their own historical names (results.powerSweep and
            % friends) so command-line callers written before the wizard keep
            % working unchanged.
            obj.results.(step.id) = result;

            st = obj.blankStatus();
            st.state     = verdict.verdict;
            st.verdict   = verdict.verdict;
            st.attempts  = attempt;
            st.lastRunAt = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
            obj.stepStatus.(step.id) = st;

            obj.report().recordStep(step, result, verdict, struct( ...
                'knobValues', knobValues, 'attempt', attempt));
            obj.log('step_verdict', struct('step', step.id, ...
                'verdict', verdict.verdict, 'headline', verdict.headline, ...
                'attempt', attempt));

            out = struct('step', step, 'result', result, 'verdict', verdict, ...
                'attempt', attempt, 'reportPath', obj.report().htmlPath());
        end

        function skipStep(obj, stepId, reason)
            %skipStep Record a deliberate omission, with its reason.
            %   Skipping is legitimate — a 2D-only session has no SLM to
            %   link — but it must be recorded, because a report that is
            %   silent about a step reads as if the step passed.
            step = obj.stepById(stepId);
            st = obj.blankStatus();
            st.state    = 'skipped';
            st.verdict  = 'skipped';
            st.note     = char(reason);
            st.lastRunAt = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
            obj.stepStatus.(step.id) = st;

            verdict = struct('stepId', step.id, 'verdict', 'skipped', ...
                'headline', sprintf('Skipped: %s', st.note), ...
                'rows', struct('label', {}, 'valueText', {}, ...
                               'expectedText', {}, 'ok', {}, 'severity', {}, ...
                               'why', {}), ...
                'reading', {{step.purpose}}, 'remedy', {{}}, ...
                'canAdvance', true, 'mustRetake', false, 'metrics', struct());
            obj.report().recordStep(step, struct('skipped', true), verdict, ...
                struct('operatorNote', st.note));
            obj.log('step_skipped', struct('step', step.id, 'reason', st.note));
        end

        function noteStep(obj, stepId, text)
            %noteStep Attach an operator note to a step in the report.
            obj.report().note(char(stepId), char(text));
            if isfield(obj.stepStatus, stepId)
                obj.stepStatus.(stepId).note = char(text);
            end
            obj.log('step_note', struct('step', char(stepId), 'note', char(text)));
        end

        function r = report(obj)
            %report The dated calibration folder, opened on first use.
            if isempty(obj.report_) || ~isvalid(obj.report_)
                meta = struct( ...
                    'configPath',   obj.configPath, ...
                    'hardwareKind', char(tfp.util.configField(obj.config, 'hardwareKind', '')), ...
                    'gitHash',      obj.gitHash_, ...
                    'sessionLog',   obj.sessionId, ...
                    'simulated',    simulatedList(obj.simulated));
                obj.report_ = tfp.gui.CalibrationReport( ...
                    obj.calibrationRoot(), obj.sessionName, meta);
                obj.log('report_opened', struct('dir', obj.report_.dir));
            end
            r = obj.report_;
        end

        function root = calibrationRoot(obj)
            %calibrationRoot Where dated calibration folders live.
            %   The repo's calibration/ by default — a rig's calibration
            %   history is part of the record, not scratch output, and the
            %   .gitignore tracks the small artifacts while ignoring the
            %   heavy .mat results. Override with config.paths.calibrationDir.
            pathsCfg = tfp.util.configField(obj.config, 'paths', struct());
            root = char(tfp.util.configField(pathsCfg, 'calibrationDir', ''));
            if isempty(root)
                here = fileparts(mfilename('fullpath'));            % src/+tfp/+gui
                repo = fileparts(fileparts(fileparts(here)));       % repo root
                root = fullfile(repo, 'calibration');
            end
            if ~isfolder(root), mkdir(root); end
        end

        % ==================================================================
        % Step implementations added for the guided path
        % ==================================================================

        function state = applyLaserState(obj, options)
            %applyLaserState The laser-state step, as a step method.
            if nargin < 2 || isempty(options), options = struct(); end
            state = obj.setLaserState(struct( ...
                'repRateKhz',           tfp.util.configField(options, 'repRateKhz', 100), ...
                'pulsePickerDivision',  tfp.util.configField(options, 'pulsePickerDivision', 1), ...
                'frontPanelPowerW',     positiveOrEmpty(tfp.util.configField(options, 'frontPanelPowerW', 0)), ...
                'frontPanelSetpointNm', tfp.util.configField(options, 'frontPanelSetpointNm', 1030), ...
                'shutterOpen',          logical(tfp.util.configField(options, 'shutterOpen', false)), ...
                'operator',             char(tfp.util.configField(options, 'operator', '')), ...
                'attenuatorNote',       char(tfp.util.configField(options, 'attenuatorNote', ''))));
        end

        function result = runSlmLinkCheck(obj, options)
            %runSlmLinkCheck BRINGUP_GUIDE section 2 — prove the SLM link.
            %   Connect, prepare a short defocus sequence, blank. No light is
            %   involved; this is a network and protocol check.
            if nargin < 2 || isempty(options), options = struct(); end
            if isempty(obj.slm_)
                error('tfp:gui:CalibrationSession:noModulator', ...
                    ['no modulator is configured. Set slm.enabled: true and ' ...
                     'slm.backend in the config, or skip this step for a ' ...
                     '2D-only bringup.']);
            end
            slm    = obj.slm_;
            notes  = {};
            result = struct('connected', false, 'readyOk', false, ...
                'blankOk', false, 'dryRun', [], 'backend', class(slm), ...
                'dzListUm', [], 'notes', '');

            if ismethod(slm, 'connect')
                try
                    slm.connect(tfp.util.configField(options, 'connectOptions', struct()));
                catch ME
                    notes{end+1} = sprintf('connect: %s', ME.message);
                end
            end
            st = slm.getStatus();
            % A local simulator has no socket and reports no 'connected'
            % field; it is reachable by definition.
            result.connected = ~isfield(st, 'connected') || logical(st.connected);

            dzList = double(tfp.util.configField(options, 'dzListUm', [-20 0 20]));
            result.dzListUm = dzList;
            try
                sys = tfp.optics.buildDefocusSys(obj.config);
                slm.prepareDefocusSequence(dzList, sys);
                result.readyOk = true;
            catch ME
                notes{end+1} = sprintf('prepareDefocusSequence: %s', ME.message);
            end

            if ismethod(slm, 'blank')
                try
                    slm.blank();
                    result.blankOk = true;
                catch ME
                    notes{end+1} = sprintf('blank: %s', ME.message);
                end
            else
                result.blankOk = true;
                notes{end+1} = ['this modulator has no blank command — it is a ' ...
                    'local simulator, so there is no device to leave safe'];
            end

            % dryRun lives on the SLM PC and the wire protocol has no key for
            % it, so it is left UNKNOWN rather than guessed. Declaring
            % slm.server_dry_run in the config is the operator asserting it;
            % tfp.gui.stepVerdict reports an unknown as "not evaluated"
            % instead of quietly passing.
            slmCfg = tfp.util.configField(obj.config, 'slm', struct());
            if isfield(slmCfg, 'server_dry_run')
                result.dryRun = logical(slmCfg.server_dry_run);
            end

            result.notes = strjoin(notes, '; ');
            obj.results.slmLink = result;
        end

        function result = runZRulerCheck(obj, options)
            %runZRulerCheck BRINGUP_GUIDE section 5 — the one common z axis.
            %   Round-trips the ruler, then asks the one question no camera
            %   can answer: which way did focus actually move.
            if nargin < 2 || isempty(options), options = struct(); end
            moveUm = double(tfp.util.configField(options, 'testMoveUm', 10));
            z      = obj.zstage_;
            zCfg   = tfp.util.configField(obj.config, 'zstage', struct());
            mount  = char(tfp.util.configField(zCfg, 'mount', 'objective'));

            z0 = z.getPositionUm();
            z.moveRelativeUm(moveUm);
            z1 = z.getPositionUm();

            % Ask while the stage is still displaced, so the operator is
            % looking at the moved focus rather than remembering it.
            deeper = obj.ask(struct('kind', 'yesno', ...
                'title',   'Z ruler direction', ...
                'message', {{sprintf('The stage was just commanded %+g um.', moveUm), ...
                             'Looking at the film, did the focus move DEEPER into the sample?', ...
                             '', ...
                             'This is the ZStage contract (+z is deeper) and the only place it is checked:', ...
                             'calibrateSlmDefocus compares the ABSOLUTE slope, so an inverted ruler', ...
                             'passes every later test silently.'}}, ...
                'default', true));

            z.moveToUm(z0);

            result = struct();
            result.class          = class(z);
            result.mount          = mount;
            result.directionSign  = double(tfp.util.configField(zCfg, 'direction_sign', 1));
            result.commandedUm    = moveUm;
            result.observedUm     = z1 - z0;
            result.roundTripErrUm = abs((z1 - z0) - moveUm);
            result.returnErrUm    = abs(z.getPositionUm() - z0);
            result.directionConfirmed = logical(deeper);

            % Probe the XY gate on the objective mount, where the CORRECT
            % behaviour is to throw before moving anything — so the probe is
            % itself the safe direction. On the sample mount XY is allowed,
            % and there is nothing here to check.
            result.xyGateCorrect = [];
            if strcmp(mount, 'objective') && ismethod(z, 'moveToXYUm')
                try
                    z.moveToXYUm(0, 0);
                    result.xyGateCorrect = false;
                catch ME
                    result.xyGateCorrect = contains(ME.identifier, ...
                        'xyRequiresSampleMount');
                end
            end

            obj.results.zRuler = result;
            obj.log('z_ruler_check', result);
        end

        function calib = runSlmDefocus(obj, options)
            %runSlmDefocus BRINGUP_GUIDE section 6a — SLM commands to microns.
            if nargin < 2 || isempty(options), options = struct(); end
            obj.assertLaserState('runSlmDefocus');
            if isempty(obj.slm_)
                error('tfp:gui:CalibrationSession:noModulator', ...
                    'the SLM defocus calibration needs a modulator.');
            end
            calib = obj.withCamera(@() tfp.calibration.calibrateSlmDefocus( ...
                obj.dmd_, obj.slm_, obj.camera_, obj.zstage_, obj.config, options));
            calib = obj.finish('slmDefocus', calib, 'slm_defocus');
        end

        function calib = runEtlPlanes(obj, options)
            %runEtlPlanes BRINGUP_GUIDE section 6b — imaging planes to microns.
            if nargin < 2 || isempty(options), options = struct(); end
            options = obj.withDefaults(options, 'planeBrightnessFcn', ...
                obj.planeBrightnessSource());
            calib = tfp.calibration.calibrateEtlPlanes(obj.zstage_, obj.config, options);
            calib = obj.finish('etlPlanes', calib, 'etl_planes');
        end

        function zcal = composeZ(obj, ~)
            %composeZ BRINGUP_GUIDE section 6c — the ETL/SLM tag.
            slmCal = obj.requireResult({'z_slm_defocus', 'slmDefocus'}, 'section 6a');
            etlCal = obj.requireResult({'z_etl_planes',  'etlPlanes'},  'section 6b');
            % composeZCalibration WARNS on a ruler mismatch rather than
            % throwing, so the warning is captured here and turned into a
            % field the criteria can gate on.
            [lastMsg, lastId] = lastwarn();
            lastwarn('');
            zcal = tfp.calibration.composeZCalibration(slmCal, etlCal);
            [~, wid] = lastwarn();
            zcal.rulerMismatch = strcmp(wid, ...
                'tfp:calibration:composeZCalibration:rulerMismatch');
            lastwarn(lastMsg, lastId);
            zcal = obj.finish('zComposed', zcal, 'z_composed');
        end

        function out = runMarkAndVerify(obj, options)
            %runMarkAndVerify BRINGUP_GUIDE section 7 — the direct cross-check.
            if nargin < 2 || isempty(options), options = struct(); end
            obj.assertLaserState('runMarkAndVerify');
            zcal   = obj.requireResult({'z_compose', 'zComposed'}, 'section 6c');
            latCal = obj.requireResult({'lateral_persist', 'lateral'}, 'section 4d');
            options = obj.withDefaults(options, 'mode', 'burn');
            % Lay the dz-encoded grid along the GROOVE diagonal (1,-1).
            %
            % The grid encodes defocus in LATERAL position, and the
            % excitation plane is TILTED along the dispersion diagonal — so a
            % grid laid along dispersion adds a depth offset that grows with
            % the same coordinate that encodes dz, and the two are then
            % inseparable. At the default 120 px spacing that offset is
            % several microns per mark, comparable to the plane spacing this
            % step is checking. Along the groove axis the tilt contributes
            % nothing, so lateral position encodes defocus and only defocus.
            % Section 7.4 deliberately does the opposite, and for the same
            % reason: it wants the tilt, so it runs along (1,1).
            options = obj.withDefaults(options, 'gridStepVecPx', [1 -1]);

            ledger = tfp.calibration.markFluorescentSlab(obj.dmd_, obj.slm_, ...
                obj.daq_, obj.config, options);

            nPlanes = double(tfp.util.configField( ...
                tfp.util.configField(obj.config, 'etl', struct()), 'n_planes', 3));
            stack = obj.acquireStack(sprintf( ...
                'Acquire an ETL z-stack (%d planes) over the marked region and load it here.', ...
                nPlanes), struct('nPlanes', nPlanes, 'ledger', ledger, ...
                                 'zcal', zcal, 'calibration', latCal));

            found = tfp.calibration.locateMarksInStack(stack, ledger, latCal, ...
                struct('nPlanes', nPlanes, 'zcal', zcal));

            acknowledged = obj.ask(struct('kind', 'yesno', ...
                'title',   'Mark verification', ...
                'message', {{'The mark table is about to be compared against the indirect calibration.', ...
                             'Confirm you have seen the located marks.'}}, ...
                'default', true));
            out = tfp.calibration.verifyZCalibration(zcal, found, ...
                struct('mockResponse', logical(acknowledged)));
            out.ledger = ledger;
            out.found  = found;
            out.mode   = char(options.mode);
            obj.results.markVerify = out;
        end

        function out = runTiltSign(obj, options)
            %runTiltSign BRINGUP_GUIDE section 7.4 — the SIGN of the tilt.
            %   A row of marks at ZERO commanded defocus, running along the
            %   chip's (1,1) diagonal. Because the excitation plane is
            %   tilted, they land at progressively different depths, and the
            %   direction of that march across imaging planes IS the sign.
            if nargin < 2 || isempty(options), options = struct(); end
            obj.assertLaserState('runTiltSign');
            latCal  = obj.requireResult({'lateral_persist', 'lateral'}, 'section 4d');
            zcal    = obj.requireResult({'z_compose', 'zComposed'}, 'section 6c');
            nMarks  = double(tfp.util.configField(options, 'nMarks', 5));

            markOpts = options;
            markOpts.dzCmdUm       = zeros(1, nMarks);   % same command, every mark
            markOpts.gridStepVecPx = [1 1];              % the dispersion diagonal
            markOpts.mode          = char(tfp.util.configField(options, 'mode', 'burn'));
            ledger = tfp.calibration.markFluorescentSlab(obj.dmd_, obj.slm_, ...
                obj.daq_, obj.config, markOpts);

            nPlanes = double(tfp.util.configField( ...
                tfp.util.configField(obj.config, 'etl', struct()), 'n_planes', 3));
            stack = obj.acquireStack(sprintf( ...
                'Acquire an ETL z-stack (%d planes) over the diagonal mark row and load it here.', ...
                nPlanes), struct('nPlanes', nPlanes, 'ledger', ledger, ...
                                 'zcal', zcal, 'calibration', latCal));

            found = tfp.calibration.locateMarksInStack(stack, ledger, latCal, ...
                struct('nPlanes', nPlanes, 'zcal', zcal));

            out = struct();
            out.ledger   = ledger;
            out.found    = found;
            out.planeIdx = [found.planeIdx];
            % Position along the diagonal, in the same +dispersion sense
            % dmdToDispersionUm defines, so the sign that comes out is
            % expressed in the same convention as the field-tilt proposal.
            coords = vertcat(ledger.dmdCoords);
            centre = [obj.dmd_.nCols, obj.dmd_.nRows] / 2;
            out.xDispPx = ((coords(:,1) - centre(1)) + (coords(:,2) - centre(2))) / sqrt(2);
            depths = zcal.etlPlaneZUm(max(min(out.planeIdx, zcal.nPlanes), 1));
            p = polyfit(out.xDispPx(:)', depths(:)', 1);
            out.slopeUmPerPx      = p(1);
            out.depthGradientSign = sign(p(1));
            out.nPlanes           = nPlanes;
            obj.results.tiltSign  = out;
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
            % Blank the SLM before tearing it down: a flat mask is the
            % walk-away state, and a session that ends leaving a defocus
            % mask on the device is a trap for whoever arrives next.
            try
                if ~isempty(obj.slm_) && ismethod(obj.slm_, 'blank'), obj.slm_.blank(); end
            catch
            end
            try
                if ~isempty(obj.siCalib_) && ismethod(obj.siCalib_, 'disconnect')
                    obj.siCalib_.disconnect();
                end
            catch
            end
            for h = {obj.camera_, obj.dmd_, obj.slm_, obj.zstage_, obj.daq_}
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

            % The modulator is optional by design: makeModulator returns []
            % when config.slm is absent or disabled, and callers read an
            % empty modulator as "2D mode". Only steps that declare a need
            % for it are blocked, so a 2D-only bringup runs to completion
            % with no SLM on the bench at all.
            obj.slm_ = tfp.util.configField(given, 'slm', []);
            if isempty(obj.slm_) && auto
                slmCfg = tfp.util.configField(obj.config, 'slm', struct());
                if logical(tfp.util.configField(slmCfg, 'enabled', false))
                    obj.slm_ = obj.adopt(struct(), 'slm', true, ...
                        @() tfp.hardware.makeModulator(obj.config));
                end
            end

            % Imaging-PC calibration helper (port 3048). Built but not
            % connected: the steps that need it connect on demand and report
            % a missing helper as a remedy rather than a crash.
            obj.siCalib_ = tfp.util.configField(given, 'siCalib', []);
            if isempty(obj.siCalib_) && auto
                try
                    obj.siCalib_ = tfp.hardware.ScanImageCalibBridge( ...
                        tfp.util.configField(obj.config, 'scanimage', struct()));
                catch
                    obj.siCalib_ = [];
                end
            end
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
                case 'slm'
                    h = tfp.hardware.MockSLM();
                    h.initialize(tfp.util.configField(obj.config, 'slm', struct()));
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

        % --- guided-bringup plumbing -------------------------------------

        function steps = registry(obj)
            %registry The step list, cached for the session.
            if isempty(obj.steps_)
                obj.steps_ = tfp.gui.bringupSteps();
            end
            steps = obj.steps_;
        end

        function step = stepById(obj, stepId)
            steps = obj.registry();
            idx = find(strcmp({steps.id}, char(stepId)), 1);
            if isempty(idx)
                error('tfp:gui:CalibrationSession:unknownStep', ...
                    'no bringup step called ''%s''. Known steps: %s.', ...
                    char(stepId), strjoin({steps.id}, ', '));
            end
            step = steps(idx);
        end

        function st = blankStatus(~)
            st = struct('state', 'ready', 'verdict', '', 'attempts', 0, ...
                'lastRunAt', '', 'note', '', 'blockers', {{}});
        end

        function blockers = stepBlockers(obj, step)
            %stepBlockers Everything standing between this step and running.
            %   Returned as sentences rather than codes: they are shown to
            %   the operator verbatim, and "the DMD is simulated" is more
            %   use at the bench than a boolean.
            blockers = {};
            steps = obj.registry();
            for k = 1:numel(step.requires)
                need = step.requires{k};
                if ~isfield(obj.stepStatus, need) || ...
                        ~ismember(obj.stepStatus.(need).state, {'pass', 'warn', 'skipped'})
                    idx = find(strcmp({steps.id}, need), 1);
                    if isempty(idx)
                        label = need;
                    else
                        label = sprintf('section %s (%s)', steps(idx).section, steps(idx).title);
                    end
                    blockers{end+1} = sprintf('%s has not passed yet', label); %#ok<AGROW>
                end
            end
            for k = 1:numel(step.needs)
                blockers = [blockers, obj.deviceBlocker(step.needs{k})]; %#ok<AGROW>
            end
        end

        function b = deviceBlocker(obj, key)
            %deviceBlocker One device requirement, checked against reality.
            b = {};
            switch char(key)
                case 'laserState'
                    if isempty(obj.laser_.getLaserState())
                        b = {['the laser state has not been entered, and the ' ...
                              'pulse-energy interlock is fail-closed on rep rate']};
                    end
                case 'laser'
                    if ~obj.laser_.isWired()
                        b = {['the CARBIDE modulator is not wired — set ' ...
                              'laser.carbide_modulator_ao_channel after recording ' ...
                              'the terminal in docs/WIRING.md']};
                    end
                case 'slm'
                    if isempty(obj.slm_)
                        b = {['no modulator is configured (slm.enabled is false, ' ...
                              'or slm is absent from the config)']};
                    elseif obj.flagged('slm')
                        b = {'the modulator is SIMULATED — nothing measured against it is a calibration'};
                    end
                otherwise
                    if isempty(obj.deviceHandle(key))
                        b = {sprintf('the %s is not available', char(key))};
                    elseif obj.flagged(key)
                        b = {sprintf(['the %s is SIMULATED — nothing measured ' ...
                            'against it is a calibration'], char(key))};
                    end
            end
        end

        function h = deviceHandle(obj, key)
            switch char(key)
                case 'dmd',    h = obj.dmd_;
                case 'camera', h = obj.camera_;
                case 'daq',    h = obj.daq_;
                case 'zstage', h = obj.zstage_;
                case 'slm',    h = obj.slm_;
                otherwise,     h = [];
            end
        end

        function tf = flagged(obj, key)
            %flagged Is this device running simulated?
            %   A mock session is exempt: it is simulated on purpose, says so
            %   in a banner on every tab, and refuses to write a rig config or
            %   emit real light. Blocking every step there would make the
            %   whole demo unrunnable, which is the opposite of the intent.
            tf = ~obj.isMock_ && isfield(obj.simulated, char(key)) && ...
                 logical(obj.simulated.(char(key)));
        end

        function values = knobValuesFor(~, step, given)
            %knobValuesFor Fill unset knobs from the step's declared defaults.
            values = struct();
            for k = 1:numel(step.knobs)
                name = step.knobs(k).name;
                if isfield(given, name) && ~isempty(given.(name))
                    values.(name) = given.(name);
                else
                    values.(name) = step.knobs(k).default;
                end
            end
            % Anything the caller passed that is not a declared knob is
            % forwarded untouched — that is how a test injects a
            % planeBrightnessFcn or a mock stack.
            f = fieldnames(given);
            for k = 1:numel(f)
                if ~isfield(values, f{k}), values.(f{k}) = given.(f{k}); end
            end
        end

        function result = invokeStep(obj, step, knobValues)
            %invokeStep Run one step's acquisition.
            if strcmp(step.kind, 'checklist')
                checked = tfp.util.configField(knobValues, 'checked', ...
                    false(1, numel(step.checks)));
                result = struct('checked', logical(checked(:)'), ...
                    'items', {step.checks}, ...
                    'confirmedAt', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')));
                return
            end
            if isempty(step.method)
                error('tfp:gui:CalibrationSession:noMethod', ...
                    'step %s declares no method to run.', step.id);
            end
            options = obj.optionsForStep(step, knobValues);
            result  = obj.(step.method)(options);
        end

        function options = optionsForStep(obj, step, k)
            %optionsForStep Translate operator knobs into a method's options.
            %   The knobs are named for what the operator is choosing; the
            %   methods take what they have always taken. This is the one
            %   place the two vocabularies meet.
            options = k;
            switch step.id
                case 'power_curve'
                    options.voltageSteps = linspace(knobField(k, 'vMin', 0), ...
                        knobField(k, 'vMax', 5), max(3, round(knobField(k, 'nSteps', 21))));
                    options = stripKnobs(options, {'vMin', 'vMax', 'nSteps'});
                case 'lateral_dmd_camera'
                    n = round(knobField(k, 'gridSize', 5));
                    options.gridSize = [n n];
                    options.backgroundFrame = obj.darkFrame_;
                case 'lateral_scan_camera'
                    options.scanPixels = [round(knobField(k, 'scanPixelsFast', 512)), ...
                                          round(knobField(k, 'scanPixelsSlow', 256))];
                    options = stripKnobs(options, {'scanPixelsFast', 'scanPixelsSlow'});
                case 'z_slm_defocus'
                    dzMax  = knobField(k, 'dzMaxUm', 100);
                    dzStep = max(1, knobField(k, 'dzStepUm', 25));
                    options.dzCmdUm = -dzMax:dzStep:dzMax;
                    options = stripKnobs(options, {'dzMaxUm', 'dzStepUm'});
                case 'z_etl_planes'
                    zr = knobField(k, 'zRangeUm', 40);
                    zs = max(0.1, knobField(k, 'zStepUm', 2));
                    options.zPositionsUm = -zr:zs:zr;
                    options = stripKnobs(options, {'zRangeUm', 'zStepUm'});
                case 'verify_marks'
                    dzMax  = knobField(k, 'dzMaxUm', 40);
                    dzStep = max(1, knobField(k, 'dzStepUm', 20));
                    options.dzCmdUm = -dzMax:dzStep:dzMax;
                    options = stripKnobs(options, {'dzMaxUm', 'dzStepUm'});
            end
        end

        function tf = mockSignAnswer(obj, spec)
            %mockSignAnswer The simulation's answer to "is the spot centred?".
            %   The operator's real criterion, applied to simulated optics: a
            %   correct sign combination predicts a position INSIDE the scan
            %   field, and a flipped one predicts a mirror image outside it.
            tf = false;
            try
                n = obj.results.scanCrossRegister.scanPixels;
                tf = spec.predFastPx >= 1 && spec.predFastPx <= n(1) && ...
                     spec.predSlowPx >= 1 && spec.predSlowPx <= n(2);
            catch
            end
        end

        function guard = withMockRaster(obj)
            %withMockRaster Switch the simulated 2p raster on for one step.
            %   Returns an onCleanup that switches it off again. A no-op on
            %   anything that is not a mock camera, and on a mock camera that
            %   was never wired with a rectangle.
            guard = [];
            if ~isa(obj.camera_, 'tfp.hardware.MockSubstageCamera'), return; end
            if isempty(obj.mockTruth_) || ~isfield(obj.mockTruth_, 'scanRect') || ...
                    isempty(obj.mockTruth_.scanRect)
                return
            end
            obj.camera_.setScanRect(obj.mockTruth_.scanRect);
            cam = obj.camera_;
            guard = onCleanup(@() cam.setScanRect([]));
        end

        function ctx = verdictContext(obj)
            ctx = struct('config', obj.config, 'results', obj.results, ...
                'simulated', obj.simulated);
            try
                ctx.handoff = tfp.util.readHandoffConstants();
            catch
                ctx.handoff = [];
            end
        end

        function answer = ask(obj, spec)
            %ask Put a question to the operator through whatever front end
            %   this session has. Never silently assumes an answer.
            answer = obj.askFcn_(spec);
        end

        function r = requireResult(obj, names, whatFor)
            %requireResult Fetch an earlier step's result under either its
            %   step id or its historical expert-mode name.
            for k = 1:numel(names)
                if isfield(obj.results, names{k}) && ~isempty(obj.results.(names{k}))
                    r = obj.results.(names{k});
                    return
                end
            end
            error('tfp:gui:CalibrationSession:missingStep', ...
                '%s must be completed first (looked for %s).', ...
                whatFor, strjoin(names, ' or '));
        end

        function fcn = planeBrightnessSource(obj)
            %planeBrightnessSource Where per-plane brightness comes from.
            %   Three routes, in the order the guide offers them: the live
            %   imaging-PC helper, a simulation for a mock session, and
            %   otherwise an explicit error naming the offline route rather
            %   than a silent zero.
            if ~isempty(obj.siCalib_)
                try
                    obj.siCalib_.connect();
                    fcn = @() obj.siCalib_.planeBrightness();
                    return
                catch
                end
            end
            if obj.isMock_
                fcn = tfp.sim.syntheticPlaneBrightness(obj.zstage_, obj.config);
                return
            end
            error('tfp:gui:CalibrationSession:noPlaneBrightness', ...
                ['no source of per-plane brightness. Either start ' ...
                 'si_calib_helper in the ScanImage MATLAB on the imaging PC ' ...
                 '(port 3048), or pass options.planeBrightnessFcn — the ' ...
                 'offline route, where you grab one small stack per z step ' ...
                 'and a wrapper reads the per-plane means.']);
        end

        function stack = acquireStack(obj, message, spec)
            %acquireStack Get an imaging stack to this PC, however it can.
            if ~isempty(obj.siCalib_)
                try
                    obj.siCalib_.connect();
                    stack = obj.siCalib_.grabStack(spec.nPlanes);
                    obj.log('stack_acquired', struct('source', 'si_calib_helper', ...
                        'size', size(stack)));
                    return
                catch ME
                    obj.log('stack_helper_failed', struct('message', ME.message));
                end
            end
            if obj.isMock_
                stack = tfp.sim.syntheticMarkStack(spec.ledger, spec.zcal, ...
                    struct('nPlanes', spec.nPlanes, 'calibration', spec.calibration));
                obj.log('stack_acquired', struct('source', 'simulated', ...
                    'size', size(stack)));
                return
            end
            stack = obj.ask(struct('kind', 'data', ...
                'title',   'Load the imaging stack', ...
                'message', {{message, '', ...
                             'Frames must be plane-interleaved, as ScanImage writes volumes.', ...
                             'Give a base-workspace variable name or the path of a .mat holding it.'}}, ...
                'default', ''));
            if isempty(stack)
                error('tfp:gui:CalibrationSession:noStack', ...
                    'no imaging stack was provided, so the marks cannot be located.');
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
function v = positiveOrEmpty(v)
%positiveOrEmpty A zero front-panel power means "not entered", not "zero
%   watts" — the interlock must fall back to the sample-plane estimate
%   rather than believing the laser is off.
if isempty(v) || ~isfinite(v) || v <= 0, v = []; end
end

function names = simulatedList(sim)
%simulatedList The simulated devices, as one readable string.
names = '';
if ~isstruct(sim), return; end
f = fieldnames(sim);
on = f(cellfun(@(n) islogical(sim.(n)) && sim.(n), f));
if isempty(on), names = 'none'; else, names = strjoin(on', ', '); end
end

function v = knobField(s, name, default)
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    v = double(s.(name));
else
    v = default;
end
end

function s = stripKnobs(s, names)
%stripKnobs Drop the operator-facing knob names once they have been
%   translated, so a method never receives an option it does not know.
for k = 1:numel(names)
    if isfield(s, names{k}), s = rmfield(s, names{k}); end
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
