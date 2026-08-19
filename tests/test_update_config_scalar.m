classdef test_update_config_scalar < matlab.unittest.TestCase
    %test_update_config_scalar tfp.io.updateConfigScalar — the unquoted-value
    %   sibling of updateConfigCalibrationPath, needed to close TODO C8 (the
    %   +/-1 axis signs must land in YAML as numbers, not as strings).
    %
    %   Methods:
    %     writesSignsAndRoundTrips — through the real loadConfig parser.
    %     writesNegativeAndLogical
    %     missingSectionOrKeyThrows — a silent no-op would leave the rig
    %                                 believing it had persisted a result.
    %     rejectsNonScalar
    %     pathWriterStillQuotes — the two formatters share one implementation;
    %                             pin that the path one did not lose its quotes.

    properties
        tmpDir
        cfgPath
    end

    methods (TestMethodSetup)
        function makeConfig(testCase)
            testCase.tmpDir  = tempname();
            mkdir(testCase.tmpDir);
            testCase.cfgPath = fullfile(testCase.tmpDir, 'rig.yaml');
            text = [ ...
                'hardwareKind: real', newline, ...
                'calibration:', newline, ...
                '  scan_fast_axis_sign: 0     # 0 = unresolved', newline, ...
                '  scan_slow_axis_sign: 0', newline, ...
                '  field_tilt_file: ''''', newline, ...
                'session:', newline, ...
                '  calibration_file: ''''', newline];
            fid = fopen(testCase.cfgPath, 'w');
            fprintf(fid, '%s', text);
            fclose(fid);
        end
    end

    methods (TestMethodTeardown)
        function removeConfig(testCase)
            if isfolder(testCase.tmpDir)
                rmdir(testCase.tmpDir, 's');
            end
        end
    end

    methods (Test)

        function writesSignsAndRoundTrips(testCase)
            tfp.io.updateConfigScalar(testCase.cfgPath, 'calibration', ...
                'scan_fast_axis_sign', 1);
            tfp.io.updateConfigScalar(testCase.cfgPath, 'calibration', ...
                'scan_slow_axis_sign', -1);
            cfg = tfp.io.loadConfig(testCase.cfgPath);
            testCase.verifyEqual(cfg.calibration.scan_fast_axis_sign,  1);
            testCase.verifyEqual(cfg.calibration.scan_slow_axis_sign, -1);
            testCase.verifyClass(cfg.calibration.scan_fast_axis_sign, 'double', ...
                'the sign must parse back as a number, not as a string');
        end

        function writesNegativeAndLogical(testCase)
            tfp.io.updateConfigScalar(testCase.cfgPath, 'calibration', ...
                'scan_fast_axis_sign', true);
            cfg = tfp.io.loadConfig(testCase.cfgPath);
            testCase.verifyTrue(logical(cfg.calibration.scan_fast_axis_sign));
        end

        function missingSectionOrKeyThrows(testCase)
            testCase.verifyError(@() tfp.io.updateConfigScalar( ...
                testCase.cfgPath, 'nosuch', 'k', 1), ...
                'tfp:io:updateConfigScalar:sectionNotFound');
            testCase.verifyError(@() tfp.io.updateConfigScalar( ...
                testCase.cfgPath, 'calibration', 'nosuch', 1), ...
                'tfp:io:updateConfigScalar:keyNotFound');
            testCase.verifyError(@() tfp.io.updateConfigScalar( ...
                fullfile(testCase.tmpDir, 'nope.yaml'), 'calibration', 'k', 1), ...
                'tfp:io:updateConfigScalar:fileNotFound');
        end

        function rejectsNonScalar(testCase)
            testCase.verifyError(@() tfp.io.updateConfigScalar( ...
                testCase.cfgPath, 'calibration', 'scan_fast_axis_sign', [1 2]), ...
                'tfp:io:updateConfigScalar:badValue');
        end

        function pathWriterStillQuotes(testCase)
            % Both formatters now share writeConfigValue; make sure the path
            % one did not lose its quoting in the refactor.
            tfp.io.updateConfigCalibrationPath(testCase.cfgPath, 'session', ...
                'calibration_file', 'data/calibration/x.mat');
            txt = fileread(testCase.cfgPath);
            testCase.verifySubstring(txt, "calibration_file: 'data/calibration/x.mat'");
            cfg = tfp.io.loadConfig(testCase.cfgPath);
            testCase.verifyEqual(cfg.session.calibration_file, 'data/calibration/x.mat');
        end
    end
end
