classdef CalibrationApp < handle
    %CalibrationApp Operator front end for the first DMD-at-sample calibrations.
    %
    %   THIS FILE IS A VIEW. It builds widgets, forwards clicks to
    %   tfp.gui.CalibrationSession, and renders what the session returns. It
    %   contains no arithmetic, no thresholds, no hardware call and no safety
    %   decision — all of that lives in the session, which is headless and
    %   therefore testable under matlab -nodisplay. A uifigure cannot be
    %   constructed headless, so anything that lived here would be permanently
    %   untested. tests/test_gui_headless_guard.m enforces the split
    %   mechanically rather than by good intentions.
    %
    %   Written as a programmatic classdef rather than an App Designer .mlapp
    %   on purpose: a .mlapp is a binary MAT container that cannot be diffed,
    %   reviewed in a pull request, merged, or grepped — and the guard test
    %   literally could not run against it.
    %
    %   Launch via scripts/run_calibrationGUI.m, which handles the addpath:
    %       app = run_calibrationGUI                          % the rig
    %       app = run_calibrationGUI('configs/mock.yaml')     % demo, no hardware
    %
    %   In demo mode every device is simulated and tfp.sim.wireMockRig connects
    %   them into a self-consistent optical model, so each step is a real
    %   measurement of a simulation rather than a plausible fit to noise. A red
    %   banner names every simulated device.
    %
    %   LAYOUT
    %     Row 1  the safety bar, visible on every tab: laser state, live AO
    %            readout in volts and mW, a pulse-energy gauge against the
    %            handoff's 89 uJ ceiling, a red banner naming any simulated
    %            device, and a BEAM OFF button that is never gated by any
    %            dialog.
    %     Row 2  six tabs: Laser state, Preflight, Camera, Power, Spatial,
    %            Field tilt.
    %
    %   The live display runs on a timer rather than a while-ishandle loop
    %   (which is what scripts/basler_live_preview.m does): a loop blocks the
    %   command line, and this app must leave the operator able to type. The
    %   tick skips whenever the session reports the camera busy, so the display
    %   never fights a calibration snap().
    %
    %   See also tfp.gui.CalibrationSession, tfp.gui.FrameProcessor.

    properties (SetAccess = private)
        session
    end

    properties (Access = private)
        fig_
        w_       = struct()   % widget handles
        timer_   = []
        lastFrame_ = []
    end

    methods
        function obj = CalibrationApp(config, options)
            if nargin < 2 || isempty(options), options = struct(); end
            if nargin < 1 || isempty(config),  config  = struct(); end

            % options.visible = false builds the window hidden, so a smoke
            % test can verify the whole layout constructs without popping a
            % window onto the operator's screen.
            visible = tfp.util.configField(options, 'visible', true);
            obj.fig_ = uifigure('Name', 'TF-Photostim calibration', ...
                'Position', [60 60 1600 950], 'Tag', 'tfp_calibration_app', ...
                'Visible', matlab.lang.OnOffSwitchState(logical(visible)));

            % The session's confirmFcn is this app's modal dialog. The spec is
            % rendered by tfp.util.formatPowerConfirmSpec so the console
            % prompt, this dialog and the session log all say the same thing.
            options.confirmFcn = @(spec) obj.confirmPower(spec);
            obj.session = tfp.gui.CalibrationSession(config, options);

            obj.buildUI();
            obj.refreshAll();
            obj.startTimer();

            obj.fig_.CloseRequestFcn = @(~,~) obj.onClose();
        end

        function delete(obj)
            obj.stopTimer();
        end
    end

    % =======================================================================
    % UI construction
    % =======================================================================
    methods (Access = private)

        function buildUI(obj)
            outer = uigridlayout(obj.fig_, [2 1]);
            outer.RowHeight = {110, '1x'};

            obj.buildSafetyBar(outer);

            tg = uitabgroup(outer);
            tg.Layout.Row = 2;
            obj.buildLaserTab(uitab(tg, 'Title', 'Laser state'));
            obj.buildPreflightTab(uitab(tg, 'Title', 'Preflight'));
            obj.buildCameraTab(uitab(tg, 'Title', 'Camera'));
            obj.buildPowerTab(uitab(tg, 'Title', 'Power'));
            obj.buildSpatialTab(uitab(tg, 'Title', 'Spatial'));
            obj.buildTiltTab(uitab(tg, 'Title', 'Field tilt'));
        end

        % --- safety bar ------------------------------------------------
        function buildSafetyBar(obj, parent)
            bar = uigridlayout(parent, [2 5]);
            bar.Layout.Row  = 1;
            bar.RowHeight   = {'1x', '1x'};
            bar.ColumnWidth = {260, 210, 260, '1x', 190};

            obj.w_.laserSummary = uilabel(bar, 'Text', 'Laser: not entered', ...
                'FontWeight', 'bold');
            obj.w_.aoReadout = uilabel(bar, 'Text', 'AO: -- V / -- mW', ...
                'FontSize', 15, 'FontWeight', 'bold');
            obj.w_.energyLabel = uilabel(bar, 'Text', 'Pulse energy: --');
            obj.w_.banner = uilabel(bar, 'Text', '', 'FontWeight', 'bold', ...
                'FontColor', [0.75 0 0]);

            b = uibutton(bar, 'Text', 'BEAM OFF', ...
                'BackgroundColor', [0.85 0.1 0.1], 'FontColor', 'w', ...
                'FontSize', 16, 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(~,~) obj.onBeamOff());
            b.Layout.Row = [1 2];
            b.Layout.Column = 5;
            obj.w_.beamOff = b;

            obj.w_.energyGauge = uigauge(bar, 'linear', 'Limits', [0 100], ...
                'ScaleColors', {[0.2 0.7 0.2], [0.95 0.7 0.1], [0.85 0.1 0.1]}, ...
                'ScaleColorLimits', [0 60; 60 85; 85 100]);
            obj.w_.energyGauge.Layout.Row = 2;
            obj.w_.energyGauge.Layout.Column = [1 3];

            obj.w_.statusLabel = uilabel(bar, 'Text', 'Ready.');
            obj.w_.statusLabel.Layout.Row = 2;
            obj.w_.statusLabel.Layout.Column = 4;
        end

        % --- tab 1: laser state -----------------------------------------
        function buildLaserTab(obj, tab)
            g = uigridlayout(tab, [9 3]);
            g.ColumnWidth = {280, 200, '1x'};
            g.RowHeight   = repmat({34}, 1, 9);

            uilabel(g, 'Text', ['Read these off the CARBIDE control software ' ...
                'on the Holo PC and enter them here.'], 'FontWeight', 'bold');
            uilabel(g, 'Text', ''); uilabel(g, 'Text', '');

            obj.w_.repRate = obj.formRow(g, 'Base rep rate (kHz)', ...
                @() uieditfield(g, 'numeric', 'Value', 100), ...
                'CARBIDE base rate before the pulse picker.');
            obj.w_.division = obj.formRow(g, 'Pulse-picker division', ...
                @() uieditfield(g, 'numeric', 'Value', 1, 'RoundFractionalValues', 'on'), ...
                'A wrong division mis-scales every pulse-energy check.');
            obj.w_.frontPanelW = obj.formRow(g, 'Front-panel average power (W)', ...
                @() uieditfield(g, 'numeric', 'Value', 0), ...
                'PREFERRED interlock input: a laser-plane number needs no arm-transmission assumption.');
            obj.w_.setpointNm = obj.formRow(g, 'Front-panel setpoint (nm)', ...
                @() uieditfield(g, 'numeric', 'Value', 1030), ...
                'Certificate s/n C264570 measures 1038; both are recorded.');
            obj.w_.shutter = obj.formRow(g, 'Shutter open', ...
                @() uicheckbox(g, 'Text', '', 'Value', false), '');
            obj.w_.operator = obj.formRow(g, 'Operator', ...
                @() uieditfield(g, 'text'), '');
            obj.w_.attenNote = obj.formRow(g, 'Attenuator / notes', ...
                @() uieditfield(g, 'text'), '');

            uibutton(g, 'Text', 'Apply laser state', ...
                'ButtonPushedFcn', @(~,~) obj.onApplyLaserState());
            uilabel(g, 'Text', ['Nothing that puts light on the sample is ' ...
                'enabled until this is applied.']);
        end

        % --- tab 2: preflight --------------------------------------------
        function buildPreflightTab(obj, tab)
            g = uigridlayout(tab, [2 1]);
            g.RowHeight = {40, '1x'};
            uibutton(g, 'Text', 'Run preflight checks', ...
                'ButtonPushedFcn', @(~,~) obj.onPreflight());
            obj.w_.preflightTable = uitable(g, ...
                'ColumnName', {'Device', 'Status', 'Detail', 'What to do'}, ...
                'ColumnWidth', {150, 90, 460, '1x'});
        end

        % --- tab 3: camera -------------------------------------------------
        function buildCameraTab(obj, tab)
            g = uigridlayout(tab, [2 2]);
            g.ColumnWidth = {'1x', 300};
            g.RowHeight   = {'2x', '1x'};

            obj.w_.camAxes = uiaxes(g);
            title(obj.w_.camAxes, 'Substage camera');

            knobs = uigridlayout(g, [14 2]);
            knobs.Layout.Row = [1 2];
            knobs.Layout.Column = 2;
            knobs.RowHeight = repmat({30}, 1, 14);

            uilabel(knobs, 'Text', 'Live', 'FontWeight', 'bold');
            obj.w_.liveSwitch = uicheckbox(knobs, 'Text', 'running', ...
                'ValueChangedFcn', @(src,~) obj.onLiveToggle(src.Value));

            obj.w_.exposure = obj.knobRow(knobs, 'Exposure (ms)', ...
                @() uieditfield(knobs, 'numeric', 'Value', 10, ...
                    'ValueChangedFcn', @(src,~) obj.onCameraSet('exposure', src.Value)));
            obj.w_.gain = obj.knobRow(knobs, 'Gain (dB)', ...
                @() uieditfield(knobs, 'numeric', 'Value', 0, ...
                    'ValueChangedFcn', @(src,~) obj.onCameraSet('gain', src.Value)));
            obj.w_.binning = obj.knobRow(knobs, 'Binning', ...
                @() uidropdown(knobs, 'Items', {'1', '2', '4'}, ...
                    'ValueChangedFcn', @(src,~) obj.onCameraSet('binning', str2double(src.Value))));
            obj.w_.format = obj.knobRow(knobs, 'Pixel format', ...
                @() uidropdown(knobs, 'Items', {'Mono8', 'Mono12'}, ...
                    'ValueChangedFcn', @(src,~) obj.onCameraSet('format', src.Value)));
            obj.w_.nAverages = obj.knobRow(knobs, 'Frame averages', ...
                @() uieditfield(knobs, 'numeric', 'Value', 1, ...
                    'RoundFractionalValues', 'on', 'Limits', [1 64]));
            obj.w_.subDark = obj.knobRow(knobs, 'Subtract dark', ...
                @() uicheckbox(knobs, 'Text', ''));
            obj.w_.showSat = obj.knobRow(knobs, 'Mark saturation', ...
                @() uicheckbox(knobs, 'Text', '', 'Value', true));

            uibutton(knobs, 'Text', 'Capture dark', ...
                'ButtonPushedFcn', @(~,~) obj.onCaptureDark());
            uibutton(knobs, 'Text', 'Clear dark', ...
                'ButtonPushedFcn', @(~,~) obj.session.clearDark());
            uibutton(knobs, 'Text', 'Reset ROI', ...
                'ButtonPushedFcn', @(~,~) obj.onCameraSet('resetRoi', []));
            obj.w_.focusLabel = uilabel(knobs, 'Text', 'focus --  sat --');

            lower = uigridlayout(g, [1 2]);
            lower.Layout.Row = 2; lower.Layout.Column = 1;
            obj.w_.histAxes = uiaxes(lower);
            title(obj.w_.histAxes, 'Histogram (log counts)');
            obj.w_.profileAxes = uiaxes(lower);
            title(obj.w_.profileAxes, 'Line profile through the brightest row');
        end

        % --- tab 4: power ---------------------------------------------------
        function buildPowerTab(obj, tab)
            g = uigridlayout(tab, [2 2]);
            g.ColumnWidth = {320, '1x'};
            g.RowHeight   = {'1x', '1x'};

            ctl = uigridlayout(g, [10 2]);
            ctl.Layout.Row = [1 2];
            ctl.RowHeight = repmat({32}, 1, 10);

            uilabel(ctl, 'Text', 'CARBIDE volts -> mW', 'FontWeight', 'bold');
            uilabel(ctl, 'Text', '');
            obj.w_.pwrVMin  = obj.knobRow(ctl, 'Start (V)', @() uieditfield(ctl, 'numeric', 'Value', 0));
            obj.w_.pwrVMax  = obj.knobRow(ctl, 'End (V)',   @() uieditfield(ctl, 'numeric', 'Value', 5));
            obj.w_.pwrSteps = obj.knobRow(ctl, 'Steps',     @() uieditfield(ctl, 'numeric', 'Value', 21, 'RoundFractionalValues', 'on'));
            obj.w_.pwrSettle = obj.knobRow(ctl, 'Settle (s)', @() uieditfield(ctl, 'numeric', 'Value', 5));
            obj.w_.pwrAvg   = obj.knobRow(ctl, 'Readings/step', @() uieditfield(ctl, 'numeric', 'Value', 5, 'RoundFractionalValues', 'on'));
            uibutton(ctl, 'Text', 'Run power sweep', ...
                'ButtonPushedFcn', @(~,~) obj.onRunPowerSweep());
            uilabel(ctl, 'Text', 'Asks once for the ramp ceiling.');
            obj.w_.pwrLookupMw = obj.knobRow(ctl, 'Convert mW ->', ...
                @() uieditfield(ctl, 'numeric', 'Value', 5, ...
                    'ValueChangedFcn', @(src,~) obj.onConvertPower(src.Value)));
            obj.w_.pwrLookupOut = uilabel(ctl, 'Text', '-- V');

            obj.w_.powerAxes = uiaxes(g);
            obj.w_.powerAxes.Layout.Row = 1; obj.w_.powerAxes.Layout.Column = 2;
            title(obj.w_.powerAxes, 'Measured power vs AO voltage');

            obj.w_.powerNotes = uitextarea(g, 'Editable', 'off');
            obj.w_.powerNotes.Layout.Row = 2; obj.w_.powerNotes.Layout.Column = 2;
        end

        % --- tab 5: spatial ---------------------------------------------------
        function buildSpatialTab(obj, tab)
            g = uigridlayout(tab, [2 2]);
            g.ColumnWidth = {360, '1x'};
            g.RowHeight   = {'1x', '1x'};

            ctl = uigridlayout(g, [12 1]);
            ctl.Layout.Row = [1 2];
            ctl.RowHeight = repmat({32}, 1, 12);

            uilabel(ctl, 'Text', 'A. DMD -> camera', 'FontWeight', 'bold');
            uibutton(ctl, 'Text', 'Run spot-grid affine', ...
                'ButtonPushedFcn', @(~,~) obj.onRunStepA());
            uilabel(ctl, 'Text', 'B. ScanImage -> camera', 'FontWeight', 'bold');
            uilabel(ctl, 'Text', ['Put ScanImage in Focus with a NON-SQUARE ' ...
                'pixel count (e.g. 512 x 256).']);
            uibutton(ctl, 'Text', 'Run cross-registration', ...
                'ButtonPushedFcn', @(~,~) obj.onRunStepB());
            uilabel(ctl, 'Text', 'C. Axis signs (mandatory)', 'FontWeight', 'bold');
            uibutton(ctl, 'Text', 'Verify axis signs', ...
                'ButtonPushedFcn', @(~,~) obj.onRunStepC());
            uibutton(ctl, 'Text', 'Compose and save', ...
                'ButtonPushedFcn', @(~,~) obj.onComposeLateral());
            obj.w_.allowWrite = uicheckbox(ctl, 'Text', ...
                'Allow writing results into the rig config', 'Value', false, ...
                'Enable', 'off');

            obj.w_.spatialAxes = uiaxes(g);
            obj.w_.spatialAxes.Layout.Row = 1; obj.w_.spatialAxes.Layout.Column = 2;
            title(obj.w_.spatialAxes, 'Affine residuals');

            obj.w_.spatialNotes = uitextarea(g, 'Editable', 'off');
            obj.w_.spatialNotes.Layout.Row = 2; obj.w_.spatialNotes.Layout.Column = 2;
        end

        % --- tab 6: field tilt -------------------------------------------------
        function buildTiltTab(obj, tab)
            g = uigridlayout(tab, [2 2]);
            g.ColumnWidth = {320, '1x'};
            g.RowHeight   = {'1x', '1x'};

            ctl = uigridlayout(g, [10 2]);
            ctl.Layout.Row = [1 2];
            ctl.RowHeight = repmat({32}, 1, 10);

            uilabel(ctl, 'Text', 'Depth plane across the field', 'FontWeight', 'bold');
            uilabel(ctl, 'Text', '');
            obj.w_.tiltNRing = obj.knobRow(ctl, 'Points per ring', ...
                @() uieditfield(ctl, 'numeric', 'Value', 8, 'RoundFractionalValues', 'on'));
            obj.w_.tiltHalf = obj.knobRow(ctl, 'Search +/- (um)', ...
                @() uieditfield(ctl, 'numeric', 'Value', 30));
            obj.w_.tiltStep = obj.knobRow(ctl, 'Step (um)', ...
                @() uieditfield(ctl, 'numeric', 'Value', 5));
            obj.w_.tiltPower = obj.knobRow(ctl, 'Power (mW)', ...
                @() uieditfield(ctl, 'numeric', 'Value', 5));
            uibutton(ctl, 'Text', 'Measure field tilt', ...
                'ButtonPushedFcn', @(~,~) obj.onRunFieldTilt());
            uilabel(ctl, 'Text', 'Needs the z ruler (see Preflight).');
            obj.w_.tiltSummary = uitextarea(ctl, 'Editable', 'off');
            obj.w_.tiltSummary.Layout.Column = [1 2];

            obj.w_.tiltAxes = uiaxes(g);
            obj.w_.tiltAxes.Layout.Row = 1; obj.w_.tiltAxes.Layout.Column = 2;
            title(obj.w_.tiltAxes, 'Best focus vs dispersion-axis position');

            obj.w_.tiltMapAxes = uiaxes(g);
            obj.w_.tiltMapAxes.Layout.Row = 2; obj.w_.tiltMapAxes.Layout.Column = 2;
            title(obj.w_.tiltMapAxes, 'Field points on the chip');
        end

        % --- small layout helpers ------------------------------------------
        function h = formRow(~, g, labelText, factory, hint)
            uilabel(g, 'Text', labelText);
            h = factory();
            uilabel(g, 'Text', hint, 'FontColor', [0.35 0.35 0.35]);
        end

        function h = knobRow(~, g, labelText, factory)
            uilabel(g, 'Text', labelText);
            h = factory();
        end
    end

    % =======================================================================
    % Callbacks — each forwards to the session and renders the result
    % =======================================================================
    methods (Access = private)

        function onApplyLaserState(obj)
            obj.guard(@() obj.session.setLaserState(struct( ...
                'repRateKhz',          obj.w_.repRate.Value, ...
                'pulsePickerDivision', obj.w_.division.Value, ...
                'frontPanelPowerW',    nonZeroOrEmpty(obj.w_.frontPanelW.Value), ...
                'frontPanelSetpointNm', obj.w_.setpointNm.Value, ...
                'shutterOpen',         obj.w_.shutter.Value, ...
                'operator',            obj.w_.operator.Value, ...
                'attenuatorNote',      obj.w_.attenNote.Value)), ...
                'Laser state applied.');
        end

        function onPreflight(obj)
            obj.guard(@() obj.renderPreflight(obj.session.preflight()), ...
                'Preflight complete.');
        end

        function renderPreflight(obj, status)
            data = cell(numel(status), 4);
            for k = 1:numel(status)
                data(k, :) = {status(k).device, status(k).status, ...
                              status(k).detail, status(k).remedy};
            end
            obj.w_.preflightTable.Data = data;
        end

        function onLiveToggle(obj, on)
            obj.guard(@() toggle(), '');
            function toggle()
                if on, obj.session.startLive(); else, obj.session.stopLive(); end
            end
        end

        function onCameraSet(obj, what, value)
            cam = obj.session.hardware().camera;
            obj.guard(@() apply(), '');
            function apply()
                switch what
                    case 'exposure', cam.setExposureMs(value);
                    case 'gain',     cam.setGain(value);
                    case 'binning',  cam.setBinning(value);
                    case 'format',   cam.setPixelFormat(value);
                    case 'resetRoi', cam.resetRoi();
                end
            end
        end

        function onCaptureDark(obj)
            obj.guard(@() obj.session.captureDark(8), ...
                'Dark frame captured with the beam off.');
        end

        function onBeamOff(obj)
            % Never gated by any dialog: blocking the safe direction is how a
            % safety dialog becomes a hazard.
            try
                obj.session.laser().zeroQuiet();
                obj.setStatus('BEAM OFF — modulator at minimum.');
            catch ME
                obj.setStatus(sprintf('BEAM OFF failed: %s', ME.message));
            end
            obj.refreshSafetyBar();
        end

        function onRunPowerSweep(obj)
            steps = linspace(obj.w_.pwrVMin.Value, obj.w_.pwrVMax.Value, ...
                max(3, obj.w_.pwrSteps.Value));
            opts = struct('voltageSteps', steps, ...
                'settleTimeS', obj.w_.pwrSettle.Value, ...
                'nAverages',   obj.w_.pwrAvg.Value, ...
                'onStep',      @(k, n, v, mw, sd) obj.renderPowerProgress(k, n, v, mw, sd));
            obj.guard(@() obj.renderPowerCurve(obj.session.runPowerSweep(opts)), ...
                'Power curve measured and saved.');
        end

        function renderPowerProgress(obj, k, n, volts, mw, ~)
            plot(obj.w_.powerAxes, volts, mw, 'o-', 'LineWidth', 1.4);
            xlabel(obj.w_.powerAxes, 'AO voltage (V)');
            ylabel(obj.w_.powerAxes, 'Power at sample (mW)');
            grid(obj.w_.powerAxes, 'on');
            title(obj.w_.powerAxes, sprintf('Sweep step %d/%d', k, n));
            drawnow limitrate;
        end

        function renderPowerCurve(obj, curve)
            v  = curve.voltage.voltageV;
            mw = curve.voltage.powerMw;
            sd = curve.voltage.powerStdMw;
            if isempty(sd), sd = zeros(size(mw)); end
            errorbar(obj.w_.powerAxes, v, mw, sd, 'k-o', 'LineWidth', 1.4);
            xlabel(obj.w_.powerAxes, 'AO voltage (V)');
            ylabel(obj.w_.powerAxes, 'Power at sample (mW)');
            grid(obj.w_.powerAxes, 'on');
            title(obj.w_.powerAxes, 'Measured power vs AO voltage');
            obj.w_.powerNotes.Value = obj.powerSummaryText(curve);
        end

        function txt = powerSummaryText(obj, curve)
            lp = obj.session.laser();
            txt = {curve.notes, ''};
            txt{end+1} = sprintf('Max measured: %.3g mW at %.3f V', ...
                max(curve.voltage.powerMw), max(curve.voltage.voltageV));
            % BRINGUP_GUIDE section 3 asks the operator to record where the
            % calibration working power and the SLM alignment cap sit.
            for target = [5, 44]
                try
                    txt{end+1} = sprintf('%g mW is at %.3f V', ...
                        target, lp.voltsForMw(target)); %#ok<AGROW>
                catch
                    txt{end+1} = sprintf('%g mW is outside the measured range', target); %#ok<AGROW>
                end
            end
        end

        function onConvertPower(obj, mw)
            try
                obj.w_.pwrLookupOut.Text = sprintf('%.3f V', ...
                    obj.session.laser().voltsForMw(mw));
            catch ME
                obj.w_.pwrLookupOut.Text = ME.message;
            end
        end

        function onRunStepA(obj)
            obj.guard(@() obj.renderResiduals(obj.session.runDmdToCamera()), ...
                'DMD -> camera affine fitted.');
        end

        function onRunStepB(obj)
            obj.guard(@() obj.renderSpatialNotes(obj.session.runScanCrossRegister()), ...
                'Scan field cross-registered.');
        end

        function onRunStepC(obj)
            obj.guard(@() obj.renderSpatialNotes(obj.session.runVerifySigns( ...
                struct('confirmFcn', @(spec) obj.confirmAxisSign(spec)))), ...
                'Axis signs resolved.');
        end

        function onComposeLateral(obj)
            obj.guard(@() obj.renderSpatialNotes(obj.session.composeLateral()), ...
                'Lateral calibration composed and saved.');
        end

        function renderResiduals(obj, calib)
            ax = obj.w_.spatialAxes;
            if isfield(calib, 'residualsPerPt') && ~isempty(calib.residualsPerPt)
                stem(ax, calib.residualsPerPt, 'filled');
                xlabel(ax, 'grid point'); ylabel(ax, 'residual (camera px)');
                grid(ax, 'on');
                title(ax, sprintf('Affine residuals — RMS %.2f px', ...
                    calib.residualErrorPx));
            end
            obj.renderSpatialNotes(calib);
        end

        function renderSpatialNotes(obj, calib)
            obj.w_.spatialNotes.Value = structLines(calib, ...
                {'residualErrorPx', 'nCalibrationPoints', 'scan_fast_axis_sign', ...
                 'scan_slow_axis_sign', 'scanVerified', 'umPerPixel', 'notes'});
        end

        function onRunFieldTilt(obj)
            opts = struct('nRing', obj.w_.tiltNRing.Value, ...
                'zSearchHalfUm', obj.w_.tiltHalf.Value, ...
                'zStepUm',       obj.w_.tiltStep.Value, ...
                'powerMw',       obj.w_.tiltPower.Value);
            obj.guard(@() obj.renderTilt(obj.session.runFieldTilt(opts)), ...
                'Field tilt measured and saved.');
        end

        function renderTilt(obj, calib)
            ax = obj.w_.tiltAxes;
            cla(ax);
            hold(ax, 'on');
            scatter(ax, calib.xDispUm, calib.bestFocusZUm, 40, 'filled');
            xs = linspace(min(calib.xDispUm), max(calib.xDispUm), 50);
            plot(ax, xs, calib.fit.aUmPerUm * xs + calib.fit.cUm, 'r-', 'LineWidth', 1.6);
            % The handoff's design slope, for comparison rather than judgement.
            plot(ax, xs, calib.expected.depthGradientUmPerUm * xs + calib.fit.cUm, ...
                'k--', 'LineWidth', 1.2);
            hold(ax, 'off');
            xlabel(ax, 'x_{disp} at sample (um)');
            ylabel(ax, 'best focus z (um)');
            legend(ax, {'measured', 'fit', 'handoff design'}, 'Location', 'best');
            grid(ax, 'on');
            title(ax, sprintf('Tilt %.3f deg, gradient %.5f um/um (r^2 = %.3f)', ...
                calib.tiltAngleDeg, calib.fit.aUmPerUm, calib.fit.r2));

            mapAx = obj.w_.tiltMapAxes;
            cla(mapAx);
            scatter(mapAx, calib.dmdPts(:,1), calib.dmdPts(:,2), 40, ...
                calib.bestFocusZUm, 'filled');
            axis(mapAx, 'equal');
            colorbar(mapAx);
            xlabel(mapAx, 'DMD col'); ylabel(mapAx, 'DMD row');
            title(mapAx, 'Best focus by field position (um)');

            obj.w_.tiltSummary.Value = structLines(calib, ...
                {'tiltAngleDeg', 'walkUm', 'walkFullPatchUm', 'axialFwhmUm', ...
                 'depthGradientSign'});
        end

        % --- dialogs ----------------------------------------------------
        function ok = confirmPower(obj, spec)
            %confirmPower The uifigure rendering of the power-step spec.
            %   Wording comes from tfp.util.formatPowerConfirmSpec, shared with
            %   the console prompt and the session log, so the operator, the
            %   terminal and the audit trail cannot disagree.
            lines = tfp.util.formatPowerConfirmSpec(spec);
            msg   = strjoin(lines, newline);
            switch lower(spec.severity)
                case 'danger',  icon = 'warning';
                case 'caution', icon = 'question';
                otherwise,      icon = 'info';
            end
            if spec.defaultAnswer
                defaultOpt = 'Proceed';
            else
                defaultOpt = 'Cancel';
            end
            answer = uiconfirm(obj.fig_, msg, spec.title, ...
                'Options', {'Proceed', 'Cancel'}, ...
                'DefaultOption', defaultOpt, 'CancelOption', 'Cancel', ...
                'Icon', icon);
            ok = strcmp(answer, 'Proceed');
        end

        function ok = confirmAxisSign(obj, spec)
            msg = sprintf(['Combination %d of %d: fast %+d, slow %+d.\n\n' ...
                'Predicted mROI centre: x = %.1f um, y = %.1f um\n' ...
                '(scan-field pixel fast = %.1f, slow = %.1f)\n\n' ...
                'Command that mROI in ScanImage. Is the DMD spot centred in it?'], ...
                spec.comboIndex, spec.nCombos, spec.fastSign, spec.slowSign, ...
                spec.predXUm, spec.predYUm, spec.predFastPx, spec.predSlowPx);
            answer = uiconfirm(obj.fig_, msg, 'Verify axis signs', ...
                'Options', {'Yes, centred', 'No'}, ...
                'DefaultOption', 'No', 'CancelOption', 'No', 'Icon', 'question');
            ok = strcmp(answer, 'Yes, centred');
        end

        % --- shared plumbing --------------------------------------------
        function guard(obj, fcn, successMsg)
            %guard Run a session call, surface any failure as an alert.
            %   The app must never die on a hardware fault: the operator needs
            %   BEAM OFF to keep working.
            try
                obj.setStatus('Working...');
                fcn();
                if ~isempty(successMsg), obj.setStatus(successMsg); end
            catch ME
                obj.setStatus(sprintf('Failed: %s', ME.message));
                uialert(obj.fig_, ME.message, 'Step failed');
            end
            obj.refreshAll();
        end

        function setStatus(obj, txt)
            if isvalid(obj.fig_)
                obj.w_.statusLabel.Text = txt;
                drawnow limitrate;
            end
        end

        function refreshAll(obj)
            obj.refreshSafetyBar();
            st = obj.session.state();
            obj.w_.allowWrite.Value = st.allowConfigWrite;
        end

        function refreshSafetyBar(obj)
            if ~isvalid(obj.fig_), return; end
            st = obj.session.state();
            L  = st.laser;

            if isempty(L.laserState)
                obj.w_.laserSummary.Text = 'Laser: NOT ENTERED';
            else
                ls = L.laserState;
                obj.w_.laserSummary.Text = sprintf('Laser: %g kHz / %g = %.3g kHz', ...
                    ls.repRateKhz, ls.pulsePickerDivision, ls.effectiveRepRateHz / 1e3);
            end

            if ~L.wired
                obj.w_.aoReadout.Text = 'AO: UNWIRED';
            else
                obj.w_.aoReadout.Text = sprintf('AO: %.3f V / %s', ...
                    L.currentVolts, mwText(L.currentPowerMw));
            end

            obj.renderEnergyGauge(L);

            sims = fieldnames(st.simulated);
            named = sims(cellfun(@(f) st.simulated.(f), sims));
            if isempty(named)
                obj.w_.banner.Text = '';
            else
                obj.w_.banner.Text = sprintf('SIMULATED: %s — nothing measured here is a calibration.', ...
                    strjoin(named', ', '));
            end
        end

        function renderEnergyGauge(obj, L)
            %renderEnergyGauge Percent of the handoff's pulse-energy ceiling.
            %   Computed by tfp.util.assertPulseEnergySafe in 'report' mode —
            %   the view must not do this arithmetic, and 'report' exists so
            %   displaying the number never trips the interlock it describes.
            pct = 0;
            txt = 'Pulse energy: --';
            try
                info = tfp.util.assertPulseEnergySafe([], [], L.laserState, ...
                    struct('mode', 'report'));
                pct = min(100, 100 * info.pulseEnergyUJ / info.ceilingUJ);
                txt = sprintf('Worst case %.1f uJ of %.0f uJ (%.2fx margin)', ...
                    info.pulseEnergyUJ, info.ceilingUJ, info.marginX);
            catch
            end
            obj.w_.energyGauge.Value = pct;
            obj.w_.energyLabel.Text  = txt;
        end

        % --- live timer -------------------------------------------------
        function startTimer(obj)
            obj.timer_ = timer('ExecutionMode', 'fixedSpacing', 'Period', 0.05, ...
                'BusyMode', 'drop', 'TimerFcn', @(~,~) obj.onTick(), ...
                'Name', 'tfpCalibrationLive');
            start(obj.timer_);
        end

        function stopTimer(obj)
            if ~isempty(obj.timer_) && isvalid(obj.timer_)
                stop(obj.timer_);
                delete(obj.timer_);
            end
            obj.timer_ = [];
        end

        function onTick(obj)
            if ~isvalid(obj.fig_) || ~obj.session.isLive() || obj.session.isCameraBusy()
                return
            end
            try
                [frame, info] = obj.session.grabDisplayFrame(struct( ...
                    'nAverages',    obj.w_.nAverages.Value, ...
                    'subtractDark', obj.w_.subDark.Value));
                if isempty(frame), return; end
                obj.lastFrame_ = frame;
                obj.renderFrame(frame, info);
            catch
                % A display fault must never take the session down.
            end
        end

        function renderFrame(obj, frame, info)
            ax = obj.w_.camAxes;
            imagesc(ax, frame, info.limits);
            colormap(ax, gray);
            axis(ax, 'image');
            if obj.w_.showSat.Value && any(info.saturation(:))
                hold(ax, 'on');
                [sy, sx] = find(info.saturation);
                plot(ax, sx, sy, '.', 'Color', [1 0 0], 'MarkerSize', 3);
                hold(ax, 'off');
            end
            obj.w_.focusLabel.Text = sprintf('focus %.4g   sat %.2f%%', ...
                info.focusMetric, 100 * info.saturatedFraction);

            fp = tfp.gui.FrameProcessor;
            [counts, centres] = fp.histogramCounts(frame, 128);
            semilogy(obj.w_.histAxes, centres, max(counts, 0.5));
            grid(obj.w_.histAxes, 'on');

            [~, brightRow] = max(mean(frame, 2));
            [profile, dist] = fp.lineProfile(frame, [1 brightRow], ...
                [size(frame, 2) brightRow]);
            sigma = fp.gaussianSigma(profile, dist);
            plot(obj.w_.profileAxes, dist, profile);
            grid(obj.w_.profileAxes, 'on');
            title(obj.w_.profileAxes, sprintf('Row %d — sigma %.1f px', ...
                brightRow, sigma));
            drawnow limitrate;
        end

        function onClose(obj)
            obj.stopTimer();
            try, obj.session.shutdown(); catch, end
            delete(obj.fig_);
        end
    end
end

% ===========================================================================
function v = nonZeroOrEmpty(v)
if isempty(v) || v == 0, v = []; end
end

function s = mwText(mw)
if isempty(mw) || ~isfinite(mw)
    s = 'uncalibrated';
else
    s = sprintf('%.3g mW', mw);
end
end

function lines = structLines(s, names)
lines = {};
for k = 1:numel(names)
    if ~isfield(s, names{k}), continue; end
    v = s.(names{k});
    if isnumeric(v) && isscalar(v)
        lines{end+1} = sprintf('%-22s %g', names{k}, v); %#ok<AGROW>
    elseif islogical(v) && isscalar(v)
        lines{end+1} = sprintf('%-22s %d', names{k}, v); %#ok<AGROW>
    elseif ischar(v)
        lines{end+1} = sprintf('%-22s %s', names{k}, v); %#ok<AGROW>
    end
end
if isempty(lines), lines = {'(no result yet)'}; end
end
