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
            % The guided path asks questions no instrument can answer, and
            % the axis-sign loop asks four. Both fall back to the console
            % when the session is driven without this view.
            options.askFcn         = @(spec) obj.askOperator(spec);
            options.signConfirmFcn = @(spec) obj.confirmAxisSign(spec);
            obj.session = tfp.gui.CalibrationSession(config, options);

            % Wizard state lives in w_ alongside the widget handles: the
            % plan as last rendered, the verdict of each completed step, and
            % which step is on screen.
            obj.w_.plan       = tfp.gui.bringupSteps();
            obj.w_.verdicts   = struct();
            obj.w_.currentStep = '';
            obj.w_.knobFields = struct();
            obj.w_.checkBoxes = gobjects(0);

            obj.buildUI();
            obj.refreshAll();
            obj.showStep(obj.w_.plan(1).id);
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
            % The guided tab comes first because it is the default way to
            % use this app: it walks the whole of BRINGUP_GUIDE sections
            % 1-7, one step at a time. The tabs after it are the same
            % instruments with the guardrails off, for someone who already
            % knows which measurement they came for.
            obj.buildWizardTab(uitab(tg, 'Title', 'Guided bringup'));
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

        % --- tab 0: the guided bringup ----------------------------------
        %
        %   Every word of instruction, every threshold and every remedy on
        %   this tab comes from tfp.gui.bringupSteps and tfp.gui.stepVerdict.
        %   This function decides only where things sit on the screen. That
        %   is what keeps the procedure testable: tests/test_bringup_steps.m
        %   reads the same registry under -nodisplay, where no uifigure can
        %   exist.

        function buildWizardTab(obj, tab)
            g = uigridlayout(tab, [1 2]);
            g.ColumnWidth = {340, '1x'};

            % --- left: the procedure, top to bottom -------------------
            left = uigridlayout(g, [4 1]);
            left.RowHeight = {24, '1x', 24, 76};
            uilabel(left, 'Text', 'Procedure — BRINGUP_GUIDE §1–§7', ...
                'FontWeight', 'bold');
            obj.w_.stepTable = uitable(left, ...
                'ColumnName', {'§', 'Step', 'State'}, ...
                'ColumnWidth', {42, 178, 84}, ...
                'CellSelectionCallback', @(~, evt) obj.onSelectStep(evt));
            uilabel(left, 'Text', 'Session record', 'FontWeight', 'bold');
            obj.w_.reportBox = uitextarea(left, 'Editable', 'off', ...
                'Value', {'The dated calibration folder opens on the first step.'});

            % --- right: the selected step -----------------------------
            right = uigridlayout(g, [2 1]);
            right.RowHeight = {'1.05x', '1x'};
            obj.buildStepBrief(right);
            obj.buildStepResult(right);
        end

        function buildStepBrief(obj, parent)
            %buildStepBrief The contract of the step, shown BEFORE it runs.
            p = uipanel(parent, 'Title', 'This step');
            g = uigridlayout(p, [8 1]);
            g.RowHeight = {26, 40, 22, '1.4x', '1x', 'fit', 34};

            obj.w_.stepTitle = uilabel(g, 'Text', 'Select a step on the left.', ...
                'FontSize', 15, 'FontWeight', 'bold');
            obj.w_.stepPurpose = uilabel(g, 'Text', '', 'WordWrap', 'on');
            obj.w_.stepHazard = uilabel(g, 'Text', '', 'WordWrap', 'on', ...
                'FontWeight', 'bold', 'FontColor', [0.72 0.25 0]);

            obj.w_.setupBox = uitextarea(g, 'Editable', 'off', ...
                'Value', {''}, 'FontSize', 13);
            obj.w_.willDoBox = uitextarea(g, 'Editable', 'off', 'Value', {''});

            % Knobs are rebuilt per step, so they live in a container this
            % code empties rather than in fixed widgets.
            obj.w_.knobPanel = uipanel(g, 'Title', 'Settings', ...
                'BorderType', 'none');

            btns = uigridlayout(g, [1 5]);
            btns.ColumnWidth = {150, 100, 110, '1x', 120};
            btns.Padding = [0 0 0 0];
            obj.w_.proceedBtn = uibutton(btns, 'Text', 'Proceed', ...
                'FontWeight', 'bold', 'BackgroundColor', [0.20 0.45 0.75], ...
                'FontColor', 'w', 'ButtonPushedFcn', @(~,~) obj.onProceedStep());
            obj.w_.retakeBtn = uibutton(btns, 'Text', 'Retake', ...
                'Enable', 'off', 'ButtonPushedFcn', @(~,~) obj.onProceedStep());
            obj.w_.skipBtn = uibutton(btns, 'Text', 'Skip step', ...
                'ButtonPushedFcn', @(~,~) obj.onSkipStep());
            obj.w_.blockerLabel = uilabel(btns, 'Text', '', 'WordWrap', 'on', ...
                'FontColor', [0.72 0.25 0]);
            obj.w_.nextBtn = uibutton(btns, 'Text', 'Next step ▸', ...
                'Enable', 'off', 'ButtonPushedFcn', @(~,~) obj.onNextStep());
        end

        function buildStepResult(obj, parent)
            %buildStepResult What was measured, what it means, what to do.
            p = uipanel(parent, 'Title', 'Result');
            g = uigridlayout(p, [2 2]);
            g.RowHeight   = {32, '1x'};
            g.ColumnWidth = {'1.1x', '1x'};

            obj.w_.verdictLabel = uilabel(g, 'Text', 'Not run yet.', ...
                'FontSize', 14, 'FontWeight', 'bold', 'WordWrap', 'on');
            obj.w_.verdictLabel.Layout.Column = [1 2];

            obj.w_.checksTable = uitable(g, ...
                'ColumnName', {'Check', 'Measured', 'Wanted', 'Result'}, ...
                'ColumnWidth', {'auto', 90, 90, 76});

            rightCol = uigridlayout(g, [2 1]);
            rightCol.Layout.Row = 2; rightCol.Layout.Column = 2;
            rightCol.RowHeight = {'1.25x', '1x'};
            obj.w_.wizAxes = uiaxes(rightCol);
            title(obj.w_.wizAxes, '');
            obj.w_.readingBox = uitextarea(rightCol, 'Editable', 'off', ...
                'Value', {''});
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

        % --- guided bringup ---------------------------------------------

        function refreshStepTable(obj)
            %refreshStepTable Repaint the step rail from the session's plan.
            plan = obj.session.stepPlan();
            obj.w_.plan = plan;
            data = cell(numel(plan), 3);
            for k = 1:numel(plan)
                data(k, :) = {plan(k).section, plan(k).title, ...
                              stateText(plan(k).status)};
            end
            obj.w_.stepTable.Data = data;
            try
                r = obj.session.report();
                obj.w_.reportBox.Value = { ...
                    'Session record (rebuilt after every step):', r.htmlPath()};
            catch
            end
        end

        function onSelectStep(obj, evt)
            if isempty(evt.Indices), return; end
            row = evt.Indices(1);
            if row < 1 || row > numel(obj.w_.plan), return; end
            obj.showStep(obj.w_.plan(row).id);
        end

        function showStep(obj, stepId)
            %showStep Render one step's contract, before it runs.
            obj.w_.currentStep = stepId;
            brief = obj.session.beginStep(stepId);

            obj.w_.stepTitle.Text = sprintf('§%s — %s', brief.section, brief.title);
            obj.w_.stepPurpose.Text = brief.purpose;
            obj.w_.stepHazard.Text = hazardText(brief.hazard);

            obj.w_.setupBox.Value = [{'DO THIS AT THE BENCH:'}, ...
                                     reshape(brief.setup, 1, [])];
            if isempty(brief.willDo)
                obj.w_.willDoBox.Value = {'Nothing is measured — this step is a checklist.'};
            else
                obj.w_.willDoBox.Value = [{'WHEN YOU PRESS PROCEED, THE SOFTWARE WILL:'}, ...
                                          reshape(brief.willDo, 1, [])];
            end

            obj.buildKnobs(brief);

            blocked = ~isempty(brief.blockers);
            obj.w_.blockerLabel.Text = strjoin(brief.blockers, '  •  ');
            obj.w_.proceedBtn.Enable = onOff(~blocked);

            % Show the result already on record for this step, if any.
            idx = find(strcmp({obj.w_.plan.id}, stepId), 1);
            st  = obj.w_.plan(idx).status;
            if isempty(st.verdict)
                obj.clearResultPane();
            elseif isfield(obj.w_.verdicts, stepId)
                obj.renderVerdict(obj.w_.verdicts.(stepId));
            end
            obj.w_.retakeBtn.Enable = onOff(~isempty(st.verdict) && ~blocked);
        end

        function buildKnobs(obj, brief)
            %buildKnobs Rebuild the per-step controls. Checklist steps get a
            %   checkbox per item; measurement steps get their declared knobs.
            delete(obj.w_.knobPanel.Children);
            obj.w_.knobFields = struct();
            obj.w_.checkBoxes = gobjects(0);

            if strcmp(brief.kind, 'checklist')
                g = uigridlayout(obj.w_.knobPanel, [numel(brief.checks) 1]);
                g.RowHeight = repmat({26}, 1, max(1, numel(brief.checks)));
                g.Scrollable = 'on';
                for k = 1:numel(brief.checks)
                    obj.w_.checkBoxes(k) = uicheckbox(g, 'Text', brief.checks{k});
                end
                return
            end

            n = numel(brief.knobs);
            if n == 0
                g = uigridlayout(obj.w_.knobPanel, [1 1]);
                uilabel(g, 'Text', 'No settings — this step takes no options.', ...
                    'FontColor', [0.4 0.4 0.4]);
                return
            end
            g = uigridlayout(obj.w_.knobPanel, [n 3]);
            g.ColumnWidth = {230, 110, '1x'};
            g.RowHeight = repmat({26}, 1, n);
            for k = 1:n
                kb = brief.knobs(k);
                label = kb.label;
                if ~isempty(kb.unit), label = sprintf('%s (%s)', label, kb.unit); end
                uilabel(g, 'Text', label);
                obj.w_.knobFields.(kb.name) = uieditfield(g, 'numeric', ...
                    'Value', double(kb.default));
                uilabel(g, 'Text', kb.hint, 'FontColor', [0.4 0.4 0.4], ...
                    'WordWrap', 'on');
            end
        end

        function values = knobValues(obj)
            values = struct();
            if ~isempty(obj.w_.checkBoxes)
                values.checked = arrayfun(@(c) c.Value, obj.w_.checkBoxes);
                return
            end
            f = fieldnames(obj.w_.knobFields);
            for k = 1:numel(f)
                values.(f{k}) = obj.w_.knobFields.(f{k}).Value;
            end
        end

        function onProceedStep(obj)
            stepId = obj.w_.currentStep;
            if isempty(stepId), return; end
            obj.guard(@() run(), '');
            function run()
                out = obj.session.runStep(stepId, obj.knobValues());
                obj.w_.verdicts.(stepId) = out;
                obj.renderVerdict(out);
                obj.exportStepFigure(stepId);
                obj.refreshStepTable();
                obj.setStatus(out.verdict.headline);
            end
        end

        function onSkipStep(obj)
            stepId = obj.w_.currentStep;
            if isempty(stepId), return; end
            idx = find(strcmp({obj.w_.plan.id}, stepId), 1);
            reason = inputdlg({sprintf(['Why is §%s being skipped? The report ' ...
                'records the reason, because a report that is silent about a ' ...
                'step reads as if the step passed.'], obj.w_.plan(idx).section)}, ...
                'Skip step', [2 70], {''});
            if isempty(reason) || isempty(strtrim(reason{1}))
                obj.setStatus('Skip cancelled — a reason is required.');
                return
            end
            obj.guard(@() obj.session.skipStep(stepId, reason{1}), ...
                sprintf('%s skipped.', stepId));
            obj.refreshStepTable();
        end

        function onNextStep(obj)
            idx = find(strcmp({obj.w_.plan.id}, obj.w_.currentStep), 1);
            if isempty(idx) || idx >= numel(obj.w_.plan), return; end
            obj.showStep(obj.w_.plan(idx + 1).id);
        end

        function clearResultPane(obj)
            obj.w_.verdictLabel.Text = 'Not run yet.';
            obj.w_.verdictLabel.FontColor = [0.2 0.2 0.2];
            obj.w_.checksTable.Data = {};
            obj.w_.readingBox.Value = {''};
            obj.w_.nextBtn.Enable = 'off';
            cla(obj.w_.wizAxes);
            title(obj.w_.wizAxes, '');
        end

        function renderVerdict(obj, out)
            %renderVerdict The judgement, the numbers behind it, and the plot.
            v = out.verdict;
            obj.w_.verdictLabel.Text = sprintf('%s  —  %s', ...
                upper(v.verdict), v.headline);
            obj.w_.verdictLabel.FontColor = verdictColour(v.verdict);

            data = cell(numel(v.rows), 4);
            for k = 1:numel(v.rows)
                r = v.rows(k);
                if isnan(r.ok),   mark = 'not evaluated';
                elseif r.ok,      mark = 'ok';
                else,             mark = upper(r.severity);
                end
                data(k, :) = {r.label, r.valueText, r.expectedText, mark};
            end
            obj.w_.checksTable.Data = data;

            lines = reshape(v.reading, 1, []);
            if ~isempty(v.remedy)
                lines = [lines, {''}, {'WHAT TO CHANGE:'}, reshape(v.remedy, 1, [])];
            end
            obj.w_.readingBox.Value = lines;

            obj.renderStepPlot(out);

            obj.w_.nextBtn.Enable = onOff(v.canAdvance);
            obj.w_.retakeBtn.Enable = 'on';
        end

        function renderStepPlot(obj, out)
            %renderStepPlot One plot recipe per step, into the wizard axes.
            ax = obj.w_.wizAxes;
            cla(ax);
            r = out.result;
            try
                switch out.step.plot
                    case 'powerCurve'
                        obj.renderPowerCurveInto(ax, r);
                    case 'residuals'
                        stem(ax, r.residualsPerPt, 'filled');
                        xlabel(ax, 'grid point'); ylabel(ax, 'residual (camera px)');
                        title(ax, sprintf('Affine residuals — RMS %.2f px', ...
                            r.residualErrorPx));
                    case 'tilt'
                        obj.renderTiltInto(ax, r);
                    case 'zfit'
                        plot(ax, r.dzCmdUm, r.zPhysUm, 'o', 'MarkerFaceColor', [0.2 0.45 0.75]);
                        hold(ax, 'on');
                        xs = [min(r.dzCmdUm) max(r.dzCmdUm)];
                        plot(ax, xs, r.fit.slopeUmPerCmd * xs + r.fit.interceptUm, 'r-');
                        hold(ax, 'off');
                        xlabel(ax, 'commanded defocus (um)');
                        ylabel(ax, 'measured best focus (um)');
                        title(ax, sprintf('slope %.4f, r^2 = %.4f', ...
                            r.fit.slopeUmPerCmd, r.fit.r2));
                    case 'planes'
                        plot(ax, r.zPositionsUm, r.brightness, '-');
                        xlabel(ax, 'objective z (um)'); ylabel(ax, 'plane brightness');
                        title(ax, sprintf('plane depths: %s um', ...
                            num2str(round(r.planeZUm, 1))));
                    case 'zcompose'
                        stem(ax, r.etlPlaneZUm, r.dzCmdForPlane, 'filled');
                        xlabel(ax, 'imaging plane depth (um)');
                        ylabel(ax, 'SLM command (um)');
                        title(ax, 'Command that focuses stim at each plane');
                    case 'marks'
                        obj.renderMarksInto(ax, r);
                    case 'scanRect'
                        if isfield(r, 'rectBboxPx') && numel(r.rectBboxPx) >= 4
                            b = r.rectBboxPx;
                            plot(ax, [b(1) b(1)+b(3) b(1)+b(3) b(1) b(1)], ...
                                     [b(2) b(2) b(2)+b(4) b(2)+b(4) b(2)], '-', ...
                                     'LineWidth', 2);
                            axis(ax, 'equal');
                            xlabel(ax, 'camera x (px)'); ylabel(ax, 'camera y (px)');
                            title(ax, sprintf('Raster rectangle %dx%d px', ...
                                round(b(3)), round(b(4))));
                        end
                    case 'preflight'
                        title(ax, 'See the checks table');
                    otherwise
                        title(ax, '');
                end
                grid(ax, 'on');
            catch ME
                title(ax, sprintf('(plot unavailable: %s)', ME.message));
            end
        end

        function renderPowerCurveInto(~, ax, curve)
            v  = curve.voltage.voltageV;
            mw = curve.voltage.powerMw;
            sd = curve.voltage.powerStdMw;
            if isempty(sd), sd = zeros(size(mw)); end
            errorbar(ax, v, mw, sd, 'k-o', 'LineWidth', 1.4);
            xlabel(ax, 'AO voltage (V)'); ylabel(ax, 'Power at sample (mW)');
            title(ax, 'Measured power vs AO voltage');
        end

        function renderTiltInto(~, ax, calib)
            hold(ax, 'on');
            scatter(ax, calib.xDispUm, calib.bestFocusZUm, 40, 'filled');
            xs = linspace(min(calib.xDispUm), max(calib.xDispUm), 50);
            plot(ax, xs, calib.fit.aUmPerUm * xs + calib.fit.cUm, 'r-', 'LineWidth', 1.6);
            plot(ax, xs, calib.expected.depthGradientUmPerUm * xs + calib.fit.cUm, ...
                'k--', 'LineWidth', 1.2);
            hold(ax, 'off');
            xlabel(ax, 'x_{disp} at sample (um)'); ylabel(ax, 'best focus z (um)');
            legend(ax, {'measured', 'fit', 'handoff design'}, 'Location', 'best');
            title(ax, sprintf('gradient %.5f um/um (r^2 = %.3f)', ...
                calib.fit.aUmPerUm, calib.fit.r2));
        end

        function renderMarksInto(~, ax, r)
            if isfield(r, 'perMark') && ~isempty(r.perMark)
                dz  = [r.perMark.dzCmdUm];
                obs = [r.perMark.observedPlane];
                pre = [r.perMark.predictedPlane];
                plot(ax, dz, pre, 'k--o', dz, obs, 'r-s', 'LineWidth', 1.4);
                legend(ax, {'predicted plane', 'observed plane'}, 'Location', 'best');
                xlabel(ax, 'commanded defocus (um)'); ylabel(ax, 'imaging plane');
                title(ax, sprintf('%d of %d marks agree', r.nAgree, r.nTotal));
            elseif isfield(r, 'planeIdx')
                plot(ax, r.xDispPx, r.planeIdx, 'o-', 'LineWidth', 1.4);
                xlabel(ax, 'position along dispersion diagonal (DMD px)');
                ylabel(ax, 'imaging plane');
                title(ax, sprintf('march direction = sign %+d', r.depthGradientSign));
            end
        end

        function exportStepFigure(obj, stepId)
            %exportStepFigure Put this step's plot in the report folder.
            %   PDF for the record and PNG for the report page, which embeds
            %   it so the report survives being copied off the rig.
            try
                rep = obj.session.report();
                [png, pdf] = rep.figurePaths(stepId);
                exportgraphics(obj.w_.wizAxes, png, 'Resolution', 150);
                exportgraphics(obj.w_.wizAxes, pdf, 'ContentType', 'vector');
                rep.attachFigure(stepId, png, pdf);
            catch
                % A figure that will not export must never fail the step it
                % belongs to — the measurement is already recorded.
            end
        end

        function answer = askOperator(obj, spec)
            %askOperator The dialog rendering of a guided-bringup question.
            %   Same spec the console prompt takes, so the two cannot drift.
            msg = strjoin(reshape(tfp.util.configField(spec, 'message', {}), 1, []), ...
                newline);
            switch lower(char(tfp.util.configField(spec, 'kind', 'yesno')))
                case 'yesno'
                    dflt = logical(tfp.util.configField(spec, 'default', true));
                    if dflt, defaultOpt = 'Yes'; else, defaultOpt = 'No'; end
                    a = uiconfirm(obj.fig_, msg, ...
                        char(tfp.util.configField(spec, 'title', 'Question')), ...
                        'Options', {'Yes', 'No'}, 'DefaultOption', defaultOpt, ...
                        'CancelOption', 'No', 'Icon', 'question');
                    answer = strcmp(a, 'Yes');
                case 'choice'
                    opts = tfp.util.configField(spec, 'options', {'Yes', 'No'});
                    answer = uiconfirm(obj.fig_, msg, ...
                        char(tfp.util.configField(spec, 'title', 'Question')), ...
                        'Options', opts, 'Icon', 'question');
                case 'data'
                    reply = inputdlg({[msg newline newline ...
                        'Base-workspace variable name, or path of a .mat holding it:']}, ...
                        char(tfp.util.configField(spec, 'title', 'Load data')), ...
                        [1 90], {''});
                    answer = [];
                    if isempty(reply) || isempty(strtrim(reply{1})), return; end
                    name = strtrim(reply{1});
                    try
                        if isfile(name)
                            loaded = load(name);
                            f = fieldnames(loaded);
                            answer = loaded.(f{1});
                        else
                            answer = evalin('base', name);
                        end
                    catch ME
                        uialert(obj.fig_, ME.message, 'Could not load that');
                    end
                otherwise
                    answer = [];
            end
        end

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
            if isfield(obj.w_, 'stepTable') && isvalid(obj.w_.stepTable)
                obj.refreshStepTable();
            end
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
function s = stateText(status)
%stateText The step rail's one-word state, blockers folded in.
if isempty(status.verdict)
    if isempty(status.blockers), s = 'ready'; else, s = 'blocked'; end
else
    s = status.verdict;
    if status.attempts > 1
        s = sprintf('%s (%d)', s, status.attempts);
    end
end
end

function s = hazardText(h)
if isempty(h), s = ''; else, s = ['SAFETY: ' h]; end
end

function c = verdictColour(verdict)
switch lower(char(verdict))
    case 'pass',    c = [0.10 0.50 0.22];
    case 'warn',    c = [0.60 0.42 0.03];
    case 'adjust',  c = [0.74 0.30 0.00];
    case 'fail',    c = [0.71 0.14 0.14];
    case 'skipped', c = [0.40 0.40 0.40];
    otherwise,      c = [0.20 0.20 0.20];
end
end

function s = onOff(tf)
if tf, s = 'on'; else, s = 'off'; end
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
