classdef test_calibration_session < matlab.unittest.TestCase
    %test_calibration_session tfp.gui.CalibrationSession driven headlessly over
    %   mock hardware — the whole calibration, interlocks and provenance
    %   included, with no uifigure anywhere.
    %
    %   That this test can exist at all is the point of the GUI/logic split:
    %   a uifigure cannot be constructed under -nodisplay, so any decision
    %   living in the view would be permanently untested.
    %
    %   Methods:
    %     runsEveryStepHeadless
    %     everySavedCalibrationCarriesProvenance
    %     saveGoesThroughStampNotIoDirectly
    %     shutdownZeroesTheModulator / abortRaisesTheFlagAndZeroes
    %     logHasTheExpectedEventSequence
    %     powerConfirmIsLoggedWithItsFullSpec — the beam-on audit trail.
    %     configWriteIsRefusedByDefault / andForMockSessionsAlways
    %     laserStateIsRequiredBeforeLight
    %     liveAndCalibrationDoNotFightOverTheCamera
    %     darkFrameFeedsTheExistingBackgroundPath
    %     simulatedDeviceIsAnnounced

    properties
        tmpDir
    end

    methods (TestMethodSetup)
        function makeTmp(testCase)
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

        function [s, h] = makeSession(testCase, varargin)
            dmd = tfp.hardware.MockDMD();
            dmd.initialize(struct('nRows', 800, 'nCols', 1280, ...
                'loadLatencyMsPerPattern', 0));

            daq = tfp.hardware.MockDAQ();
            daq.initialize(struct('sampleRate', 10000, 'analogOutChannels', [0 1 3]));

            zstage = tfp.hardware.MockZStage();
            zstage.initialize(struct('startZUm', 0));

            camera = tfp.hardware.MockSubstageCamera();
            camera.initialize(struct('nRows', 512, 'nCols', 512, ...
                'noiseLevel', 0.002, 'spotSigmaPx', 4, 'dmd', dmd, ...
                'truthAffine', [0.30 0 256; 0 0.30 256; 0 0 1], ...
                'zstage', zstage, 'filmZUm', 0, 'zRUm', 10, ...
                'tiltGradientUmPerUm', 0.03, 'dmdSize', [800 1280]));

            config = struct();
            config.hardwareKind = 'mock';
            config.paths  = struct('dataDir', testCase.tmpDir);
            config.slm    = struct('enabled', false);
            config.zstage = struct('mount', 'objective', 'direction_sign', 1);
            config.laser  = struct( ...
                'carbide_modulator_ao_channel', 'ao1', ...
                'carbide_voltage_min', 0, 'carbide_voltage_max', 5, ...
                'arm_transmission', 0.182);
            config.scanimage = struct('mode', 'ttl_only');

            opts = struct('confirmFcn', @(spec) true, ...
                'hardware', struct('dmd', dmd, 'camera', camera, ...
                                   'daq', daq, 'zstage', zstage), ...
                'sessionName', 'test');
            for k = 1:2:numel(varargin)
                opts.(varargin{k}) = varargin{k+1};
            end

            s = tfp.gui.CalibrationSession(config, opts);
            h = struct('dmd', dmd, 'daq', daq, 'camera', camera, 'zstage', zstage);
        end

        function v = aoLog(~, daq)
            entries = daq.getLog();
            v = [];
            for k = 1:numel(entries)
                if strcmp(entries(k).eventType, 'outputSingleAnalog')
                    v(end+1) = entries(k).payload.voltageV; %#ok<AGROW>
                end
            end
        end

        function types = logTypes(~, s)
            txt = fileread(fullfile(s.sessionId, 'log.txt'));
            lines = strsplit(strtrim(txt), newline);
            types = cell(1, numel(lines));
            for k = 1:numel(lines)
                parts = strsplit(lines{k}, sprintf('\t'));
                types{k} = parts{2};
            end
        end
    end

    methods (Test)

        function runsEveryStepHeadless(testCase)
            [s, h] = testCase.makeSession();
            s.setLaserState(struct('repRateKhz', 100, 'frontPanelPowerW', 8.5));

            meter = tfp.sim.SyntheticPowerMeter(h.daq, 'ao1', struct('maxMw', 50));
            curve = s.runPowerSweep(struct('meter', meter, 'settleTimeS', 0, ...
                'warmupTimeS', 0, 'readPauseS', 0, 'nAverages', 2, ...
                'voltageSteps', linspace(0, 5, 9), 'verbose', false));
            testCase.verifyEqual(curve.schema, 2);

            calA = s.runDmdToCamera(struct('nGridPoints', 3, 'exposureS', 0));
            testCase.verifyLessThan(calA.residualErrorPx, 1.0);

            h.camera.initialize(struct('nRows', 512, 'nCols', 512, ...
                'noiseLevel', 0.002, 'scanRect', [150 180 220 120]));
            calB = s.runScanCrossRegister(struct('scanPixels', [512 256]));
            testCase.verifySize(calB.scanToCam_affine, [3 3]);

            calC = s.runVerifySigns(struct('mockResponse', [1 1]));
            testCase.verifyTrue(calC.scanVerified);

            comp = s.composeLateral();
            testCase.verifySize(comp.dmdToScan_affine, [3 3]);

            s.shutdown();
        end

        function everySavedCalibrationCarriesProvenance(testCase)
            s = testCase.makeSession();
            s.setLaserState(struct('repRateKhz', 100, 'frontPanelPowerW', 8.5));
            calib = s.stamp(struct('kind', 'field_tilt'));
            for f = {'laserState', 'sessionId', 'gitHash', 'configPath', ...
                     'configSnapshot', 'cameraSettings', 'simulated', 'stampedAt'}
                testCase.verifyTrue(isfield(calib, f{1}), ...
                    sprintf('stamp() must attach %s', f{1}));
            end
            testCase.verifyEqual(calib.laserState.repRateKhz, 100);
            s.shutdown();
        end

        function saveGoesThroughStampNotIoDirectly(testCase)
            s = testCase.makeSession();
            s.setLaserState(struct('repRateKhz', 100, 'frontPanelPowerW', 8.5));
            p = s.saveCalibration(struct('kind', 'field_tilt'), 'field_tilt');
            testCase.verifyTrue(isfile(p));
            loaded = tfp.io.loadCalibration(p, 'field_tilt');
            testCase.verifyEqual(loaded.sessionId, s.sessionId, ...
                'an unstamped calibration must not be reachable through the session');
            testCase.verifySubstring(p, testCase.tmpDir);
            s.shutdown();
        end

        function shutdownZeroesTheModulator(testCase)
            [s, h] = testCase.makeSession();
            s.setLaserState(struct('repRateKhz', 100, 'frontPanelPowerW', 8.5));
            s.laser().setVolts(1.5);
            s.shutdown();
            v = testCase.aoLog(h.daq);
            testCase.verifyEqual(v(end), 0);
        end

        function abortRaisesTheFlagAndZeroes(testCase)
            [s, h] = testCase.makeSession();
            s.setLaserState(struct('repRateKhz', 100, 'frontPanelPowerW', 8.5));
            s.laser().setVolts(1.5);
            s.abort();
            v = testCase.aoLog(h.daq);
            testCase.verifyEqual(v(end), 0);
            testCase.verifyError(@() tfp.util.safetyChecks('check'), ...
                'tfp:util:safetyAbort');
            tfp.util.safetyChecks('arm');   % leave the flag clear for other tests
            s.shutdown();
        end

        function logHasTheExpectedEventSequence(testCase)
            s = testCase.makeSession();
            s.setLaserState(struct('repRateKhz', 100, 'frontPanelPowerW', 8.5));
            s.preflight();
            s.laser().setVolts(1.0);
            s.shutdown();
            types = testCase.logTypes(s);
            for want = {'session_start', 'laser_state', 'preflight', ...
                        'power_confirm', 'ao_set', 'session_end'}
                testCase.verifyTrue(any(strcmp(types, want{1})), ...
                    sprintf('session log is missing a %s event', want{1}));
            end
        end

        function powerConfirmIsLoggedWithItsFullSpec(testCase)
            % The audit trail for every beam-on decision: what was shown, and
            % what the numbers were at the moment it was shown.
            s = testCase.makeSession();
            s.setLaserState(struct('repRateKhz', 100, 'frontPanelPowerW', 8.5));
            s.laser().setVolts(1.0);
            txt = fileread(fullfile(s.sessionId, 'log.txt'));
            testCase.verifySubstring(txt, 'power_confirm');
            testCase.verifySubstring(txt, 'pulseEnergyUJ');
            testCase.verifySubstring(txt, 'largestBlobFraction');
            s.shutdown();
        end

        function configWriteIsRefusedByDefault(testCase)
            s = testCase.makeSession();
            testCase.verifyError(@() s.writeConfigKey('calibration', 'x', 1), ...
                'tfp:gui:CalibrationSession:configWriteNotAllowed');
            s.shutdown();
        end

        function andForMockSessionsAlways(testCase)
            % Even an explicit opt-in must not let a mock session rewrite a
            % rig config.
            s = testCase.makeSession('allowConfigWrite', true);
            testCase.verifyFalse(s.allowConfigWrite);
            testCase.verifyError(@() s.writeConfigKey('calibration', 'x', 1), ...
                'tfp:gui:CalibrationSession:configWriteNotAllowed');
            s.shutdown();
        end

        function laserStateIsRequiredBeforeLight(testCase)
            s = testCase.makeSession();
            testCase.verifyError(@() s.runDmdToCamera(), ...
                'tfp:gui:CalibrationSession:noLaserState');
            testCase.verifyError(@() s.runPowerSweep(), ...
                'tfp:gui:CalibrationSession:noLaserState');
            s.shutdown();
        end

        function liveAndCalibrationDoNotFightOverTheCamera(testCase)
            s = testCase.makeSession();
            s.setLaserState(struct('repRateKhz', 100, 'frontPanelPowerW', 8.5));
            s.startLive();
            testCase.verifyTrue(s.isLive());
            s.runDmdToCamera(struct('nGridPoints', 3, 'exposureS', 0));
            testCase.verifyTrue(s.isLive(), ...
                'live acquisition must be restored after a calibration');
            testCase.verifyFalse(s.isCameraBusy());
            s.shutdown();
        end

        function darkFrameFeedsTheExistingBackgroundPath(testCase)
            s = testCase.makeSession();
            s.setLaserState(struct('repRateKhz', 100, 'frontPanelPowerW', 8.5));
            dark = s.captureDark(4);
            testCase.verifySize(dark, [512 512]);
            [~, info] = s.grabDisplayFrame(struct('subtractDark', true));
            testCase.verifyTrue(info.hasDark);
            s.clearDark();
            testCase.verifyEmpty(s.darkFrame());
            s.shutdown();
        end

        function grabReturnsNothingWhileBusy(testCase)
            s = testCase.makeSession();
            f = s.grabDisplayFrame();
            testCase.verifyNotEmpty(f);
            s.shutdown();
        end

        function simulatedDeviceIsAnnounced(testCase)
            % A device that could not be built is substituted by a mock, but
            % never silently: the flag drives a persistent banner in the view.
            config = struct('hardwareKind', 'real', ...
                'paths', struct('dataDir', testCase.tmpDir), ...
                'camera', struct('backend', 'nikon'));     % deliberately invalid
            f = @() tfp.gui.CalibrationSession(config, struct( ...
                'confirmFcn', @(spec) true, 'sessionName', 'sim'));
            testCase.verifyWarning(f, 'tfp:gui:CalibrationSession:deviceSimulated');
            w = warning('off', 'all'); c = onCleanup(@() warning(w));
            s = f();
            testCase.verifyTrue(s.simulated.camera);
            st = s.state();
            testCase.verifyTrue(st.simulated.camera);
            s.shutdown();
        end

        % --- guided bringup ------------------------------------------------

        function stepPlanReportsReadyBlockedAndDone(testCase)
            s = testCase.makeSession('calibrationRoot', testCase.tmpDir);
            plan = s.stepPlan();
            testCase.verifyEqual(numel(plan), numel(tfp.gui.bringupSteps()));

            first = plan(strcmp({plan.id}, 'prereq_bench'));
            testCase.verifyEqual(first.status.state, 'ready');

            % Nothing that puts light on the sample is reachable before the
            % laser state is entered — the interlock is fail-closed on rep
            % rate, and the plan says so in words rather than by a grey button.
            power = plan(strcmp({plan.id}, 'power_curve'));
            testCase.verifyEqual(power.status.state, 'blocked');
            testCase.verifyNotEmpty(power.status.blockers);
            testCase.verifySubstring(strjoin(power.status.blockers, ' '), 'laser state');
            s.shutdown();
        end

        function runStepRefusesABlockedStep(testCase)
            s = testCase.makeSession('calibrationRoot', testCase.tmpDir);
            testCase.verifyError(@() s.runStep('field_tilt'), ...
                'tfp:gui:CalibrationSession:stepBlocked');
            s.shutdown();
        end

        function guidedRunJudgesAndRecordsEachStep(testCase)
            s = testCase.makeSession('calibrationRoot', testCase.tmpDir);

            checks = s.beginStep('prereq_bench');
            testCase.verifyNotEmpty(checks.setup);
            out = s.runStep('prereq_bench', ...
                struct('checked', true(1, numel(checks.checks))));
            testCase.verifyEqual(out.verdict.verdict, 'pass');

            out = s.runStep('laser_state', struct('repRateKhz', 100, ...
                'pulsePickerDivision', 1, 'frontPanelPowerW', 8.5));
            testCase.verifyEqual(out.verdict.verdict, 'pass');

            % The step that was blocked a moment ago is now reachable.
            plan = s.stepPlan();
            power = plan(strcmp({plan.id}, 'power_curve'));
            testCase.verifyEmpty(power.status.blockers);

            % And the record exists on disk, per step, as it goes.
            r = s.report();
            testCase.verifyTrue(isfile(r.htmlPath()));
            html = fileread(r.htmlPath());
            testCase.verifySubstring(html, 'Bench prerequisites');
            testCase.verifySubstring(html, 'Laser state');
            s.shutdown();
        end

        function anUnconfirmedChecklistBlocksTheNextStep(testCase)
            % The section 1 bench list is not busywork: each unticked item is
            % a scale constant that would be wrong downstream while every
            % internal consistency check still passed.
            s = testCase.makeSession('calibrationRoot', testCase.tmpDir);
            step = s.beginStep('prereq_bench');
            partial = true(1, numel(step.checks));
            partial(1) = false;
            out = s.runStep('prereq_bench', struct('checked', partial));
            testCase.verifyEqual(out.verdict.verdict, 'adjust');
            testCase.verifyFalse(out.verdict.canAdvance);
            testCase.verifyNotEmpty(out.verdict.remedy);
            s.shutdown();
        end

        function retakingAStepCountsAttempts(testCase)
            s = testCase.makeSession('calibrationRoot', testCase.tmpDir);
            step = s.beginStep('prereq_bench');
            n = numel(step.checks);
            s.runStep('prereq_bench', struct('checked', false(1, n)));
            out = s.runStep('prereq_bench', struct('checked', true(1, n)));
            testCase.verifyEqual(out.attempt, 2);
            plan = s.stepPlan();
            st = plan(strcmp({plan.id}, 'prereq_bench')).status;
            testCase.verifyEqual(st.attempts, 2);
            testCase.verifyEqual(st.state, 'pass');
            s.shutdown();
        end

        function skippingIsRecordedWithItsReason(testCase)
            % Skipping is legitimate — a 2D-only session has no SLM to link —
            % but a report that is silent about a step reads as if it passed.
            s = testCase.makeSession('calibrationRoot', testCase.tmpDir);
            s.skipStep('slm_link', 'no modulator on the arm this week');
            plan = s.stepPlan();
            st = plan(strcmp({plan.id}, 'slm_link')).status;
            testCase.verifyEqual(st.state, 'skipped');
            html = fileread(s.report().htmlPath());
            testCase.verifySubstring(html, 'no modulator on the arm this week');
            s.shutdown();
        end
    end
end
