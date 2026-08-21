classdef test_calibration_app_smoke < matlab.unittest.TestCase
    %test_calibration_app_smoke Construct the real GUI, invisibly.
    %
    %   tests/test_gui_headless_guard.m proves no LOGIC lives in the view; this
    %   proves the view itself still builds. Between them, a typo in a widget
    %   name or a layout call cannot reach the bench unnoticed — which matters
    %   because the app is otherwise only ever exercised by hand.
    %
    %   The window is created with Visible='off', so a normal
    %   `matlab -nodisplay -batch "runtests"` builds the whole layout without
    %   popping anything onto the operator's screen. If graphics are
    %   unavailable entirely the test is filtered by assumption rather than
    %   failing.
    %
    %   Methods:
    %     buildsEverySection      — figure, safety bar, all six tabs.
    %     demoConfigWiresAMockRig — the mock camera really sees the mock DMD.
    %     closingStopsTheLiveTimer — a stray timer keeps firing at 20 Hz
    %                                against a deleted figure forever.
    %     beamOffWorksWithoutALaserState — the one control that must never
    %                                depend on anything.

    properties
        tmpDir
    end

    methods (TestMethodSetup)
        function skipWithoutGraphics(testCase)
            try
                f = uifigure('Visible', 'off');
                delete(f);
            catch
                testCase.assumeFail('uifigure is unavailable in this environment.');
            end
            testCase.tmpDir = tempname();
            mkdir(testCase.tmpDir);
        end
    end

    methods (TestMethodTeardown)
        function removeTmp(testCase)
            if isfolder(testCase.tmpDir), rmdir(testCase.tmpDir, 's'); end
        end
    end

    methods (Access = private)
        function app = launch(testCase)
            root   = fileparts(fileparts(mfilename('fullpath')));
            config = tfp.io.loadConfig(fullfile(root, 'configs', 'mock.yaml'));
            config.paths = struct('dataDir', testCase.tmpDir);
            app = tfp.gui.CalibrationApp(config, struct( ...
                'visible', false, 'sessionName', 'smoke', ...
                'calibrationRoot', testCase.tmpDir, ...
                'configPath', fullfile(root, 'configs', 'mock.yaml')));
            testCase.addTeardown(@() closeIfValid(app));
        end

        function f = figureOf(~, app)
            f = findall(groot, 'Tag', 'tfp_calibration_app');
            if numel(f) > 1, f = f(1); end
        end
    end

    methods (Test)

        function buildsEverySection(testCase)
            app = testCase.launch();
            fig = testCase.figureOf(app);
            testCase.verifyNotEmpty(fig, 'the app figure was not created');

            tabs = findall(fig, 'Type', 'uitab');
            titles = sort({tabs.Title});
            testCase.verifyEqual(titles, sort({'Guided bringup', 'Laser state', ...
                'Preflight', 'Camera', 'Power', 'Spatial', 'Field tilt'}));

            % The safety bar must exist before anything else is usable.
            btns = findall(fig, 'Type', 'uibutton');
            testCase.verifyTrue(any(strcmp({btns.Text}, 'BEAM OFF')), ...
                'BEAM OFF must be present on every tab');

            % NB uiaxes report Type 'axes', so query by class instead.
            axesFound = findall(fig, '-isa', 'matlab.ui.control.UIAxes');
            testCase.verifyGreaterThanOrEqual(numel(axesFound), 7, ...
                'expected camera, histogram, profile, power, spatial, tilt and wizard axes');
        end

        function theGuidedTabOpensOnTheFirstStep(testCase)
            % The app is a guided procedure first and an instrument panel
            % second, so it must come up already showing step one rather than
            % waiting to be told where to start.
            app = testCase.launch();
            fig = testCase.figureOf(app);

            labels = findall(fig, 'Type', 'uilabel');
            texts  = {labels.Text};
            steps  = tfp.gui.bringupSteps();
            wanted = sprintf('§%s — %s', steps(1).section, steps(1).title);
            testCase.verifyTrue(any(strcmp(texts, wanted)), sprintf( ...
                'expected the guided tab to open on ''%s''', wanted));

            % And the step rail must list the whole procedure, not a subset.
            tables = findall(fig, 'Type', 'uitable');
            sizes  = cellfun(@(d) size(d, 1), {tables.Data});
            testCase.verifyTrue(any(sizes == numel(steps)), ...
                'the step rail must show every step of the procedure');
        end

        function launchingDoesNotCreateAnEmptySessionFolder(testCase)
            % Opening the app to look at a tab must not litter the
            % calibration folder with empty dated sessions.
            app = testCase.launch();
            testCase.verifyFalse(app.session.hasReport());
            root = app.session.calibrationRoot();
            listing = dir(fullfile(root, '2*'));
            testCase.verifyEmpty(listing, ...
                'no dated folder should exist until a step actually runs');
        end

        function demoConfigWiresAMockRig(testCase)
            % The trap this guards: a MockSubstageCamera built from YAML alone
            % returns pure noise, and alignDMDtoCamera will fit an affine to
            % noise and report a plausible residual. A demo must simulate a
            % rig, not pretend to measure one.
            app = testCase.launch();
            truth = app.session.mockTruth();
            testCase.verifyTrue(truth.wired, ...
                'the demo session must wire the mock camera to the mock DMD');
            testCase.verifySize(truth.truthAffine, [3 3]);

            app.session.setLaserState(struct('repRateKhz', 100, ...
                'frontPanelPowerW', 8.5));
            calib = app.session.runDmdToCamera( ...
                struct('nGridPoints', 3, 'exposureS', 0));
            testCase.verifyLessThan(calib.residualErrorPx, 0.5, ...
                'a wired mock rig must fit its own truth affine tightly');
            A = calib.dmdToSample_affine;
            testCase.verifyEqual(A(1,1), truth.truthAffine(1,1), 'RelTol', 0.05, ...
                'the recovered scale must match the injected one');
        end

        function closingStopsTheLiveTimer(testCase)
            app = testCase.launch();
            before = numel(timerfindall('Name', 'tfpCalibrationLive'));
            testCase.verifyGreaterThanOrEqual(before, 1);
            close(testCase.figureOf(app));
            drawnow;
            after = numel(timerfindall('Name', 'tfpCalibrationLive'));
            testCase.verifyLessThan(after, before, ...
                ['a live timer left running fires at 20 Hz against a deleted ' ...
                 'figure for the rest of the MATLAB session']);
        end

        function beamOffWorksWithoutALaserState(testCase)
            % BEAM OFF must not depend on the laser state, a power curve, or
            % anything else the operator might not have set yet.
            app = testCase.launch();
            fig = testCase.figureOf(app);
            btns = findall(fig, 'Type', 'uibutton');
            beamOff = btns(strcmp({btns.Text}, 'BEAM OFF'));
            testCase.verifyNumElements(beamOff, 1);
            beamOff.ButtonPushedFcn([], []);   % must not throw
            testCase.verifyEqual(app.session.laser().currentVolts, ...
                app.session.laser().voltageMin);
        end
    end
end

% ---------------------------------------------------------------------------
function closeIfValid(app)
try
    f = findall(groot, 'Tag', 'tfp_calibration_app');
    for k = 1:numel(f)
        close(f(k));
    end
catch
end
try, delete(app); catch, end
end
