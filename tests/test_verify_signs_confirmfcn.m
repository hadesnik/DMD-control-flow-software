classdef test_verify_signs_confirmfcn < matlab.unittest.TestCase
    %test_verify_signs_confirmfcn The injected confirmation callback and the
    %   config write-back added to tfp.calibration.verifyScanFieldComposition.
    %
    %   The GUI needs buttons instead of the blocking input() prompt, but
    %   forking this function would leave two copies of the four-combination
    %   sign logic. Instead options.confirmFcn was added alongside the existing
    %   options.mockResponse, with precedence mockResponse -> confirmFcn ->
    %   input(). These tests pin both the new path and the old one.
    %
    %   Methods:
    %     confirmFcnResolvesSigns        — a callback that says yes only at
    %                                      (-1,+1) recovers those signs and
    %                                      applies the fast-axis correction.
    %     mockResponseStillWins          — back-compat, pinned deliberately.
    %     confirmFcnSeesTheWholeSpec     — the app renders from this struct.
    %     writesSignsWhenAllowed         — TODO C8, opt-in.
    %     doesNotWriteByDefault          — configs/real.yaml belongs to the rig.

    properties
        tmpDir
        cfgPath
    end

    methods (Access = private)
        function [dmd, calib] = fixture(~)
            dmdStub.nRows = 800; dmdStub.nCols = 1280;
            dmdCalib = tfp.calibration.alignDMDtoCamera_mock(dmdStub);
            calib    = tfp.calibration.crossRegisterScanImage_mock(dmdCalib);
            dmd = tfp.hardware.MockDMD();
            dmd.initialize(struct('nRows', 800, 'nCols', 1280, ...
                'loadLatencyMsPerPattern', 0));
        end
    end

    methods (TestMethodSetup)
        function makeConfig(testCase)
            testCase.tmpDir  = tempname();
            mkdir(testCase.tmpDir);
            testCase.cfgPath = fullfile(testCase.tmpDir, 'rig.yaml');
            fid = fopen(testCase.cfgPath, 'w');
            fprintf(fid, ['hardwareKind: real\n' ...
                'calibration:\n' ...
                '  scan_fast_axis_sign: 0\n' ...
                '  scan_slow_axis_sign: 0\n']);
            fclose(fid);
        end
    end

    methods (TestMethodTeardown)
        function removeConfig(testCase)
            if isfolder(testCase.tmpDir), rmdir(testCase.tmpDir, 's'); end
        end
    end

    methods (Test)

        function confirmFcnResolvesSigns(testCase)
            [dmd, calib] = testCase.fixture();
            before = calib.dmdToScan_affine;
            out = tfp.calibration.verifyScanFieldComposition(dmd, calib, struct( ...
                'confirmFcn', @(spec) spec.fastSign == -1 && spec.slowSign == 1, ...
                'showFigure', false));
            testCase.verifyEqual(out.scan_fast_axis_sign, -1);
            testCase.verifyEqual(out.scan_slow_axis_sign,  1);
            testCase.verifyTrue(out.scanVerified);

            nFast    = out.scanPixels(1);
            corrFast = [-1 0 (nFast + 1); 0 1 0; 0 0 1];
            testCase.verifyEqual(out.dmdToScan_affine, corrFast * before, ...
                'AbsTol', 1e-9, ...
                'a confirmed -1 fast sign must apply the fast correction matrix');
        end

        function mockResponseStillWins(testCase)
            % Back-compat, pinned on purpose: if both are supplied,
            % mockResponse decides and confirmFcn is never called.
            [dmd, calib] = testCase.fixture();
            called = containers.Map({'n'}, {0});
            out = tfp.calibration.verifyScanFieldComposition(dmd, calib, struct( ...
                'mockResponse', [1 1], ...
                'confirmFcn',   @(spec) bumpTrue(called), ...
                'showFigure',   false));
            testCase.verifyEqual(out.scan_fast_axis_sign, 1);
            testCase.verifyEqual(out.scan_slow_axis_sign, 1);
            testCase.verifyEqual(called('n'), 0, ...
                'mockResponse must take precedence over confirmFcn');
        end

        function confirmFcnSeesTheWholeSpec(testCase)
            [dmd, calib] = testCase.fixture();
            seen = {};
            tfp.calibration.verifyScanFieldComposition(dmd, calib, struct( ...
                'confirmFcn', @(spec) collect(spec), 'showFigure', false));

            testCase.verifyNotEmpty(seen);
            s = seen{1};
            for f = {'comboIndex', 'nCombos', 'fastSign', 'slowSign', ...
                     'predFastPx', 'predSlowPx', 'predXUm', 'predYUm', ...
                     'nFast', 'nSlow', 'label'}
                testCase.verifyTrue(isfield(s, f{1}), ...
                    sprintf('spec is missing %s', f{1}));
            end
            testCase.verifyEqual(numel(seen), 4, ...
                'declining every combination must exhaust all four');

            function ok = collect(spec)
                seen{end+1} = spec; %#ok<AGROW>
                ok = false;
            end
        end

        function writesSignsWhenAllowed(testCase)
            [dmd, calib] = testCase.fixture();
            tfp.calibration.verifyScanFieldComposition(dmd, calib, struct( ...
                'confirmFcn',       @(spec) spec.fastSign == -1 && spec.slowSign == -1, ...
                'configPath',       testCase.cfgPath, ...
                'allowConfigWrite', true, ...
                'showFigure',       false));
            cfg = tfp.io.loadConfig(testCase.cfgPath);
            testCase.verifyEqual(cfg.calibration.scan_fast_axis_sign, -1);
            testCase.verifyEqual(cfg.calibration.scan_slow_axis_sign, -1);
        end

        function doesNotWriteByDefault(testCase)
            [dmd, calib] = testCase.fixture();
            tfp.calibration.verifyScanFieldComposition(dmd, calib, struct( ...
                'confirmFcn', @(spec) spec.fastSign == -1, ...
                'configPath', testCase.cfgPath, ...
                'showFigure', false));
            cfg = tfp.io.loadConfig(testCase.cfgPath);
            testCase.verifyEqual(cfg.calibration.scan_fast_axis_sign, 0, ...
                'a rig config must never be written without an explicit opt-in');
        end
    end
end

% ---------------------------------------------------------------------------
function ok = bumpTrue(m)
m('n') = m('n') + 1;
ok = true;
end
