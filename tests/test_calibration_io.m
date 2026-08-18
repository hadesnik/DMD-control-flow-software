classdef test_calibration_io < matlab.unittest.TestCase
    %test_calibration_io saveCalibration / loadCalibration round-trip,
    %   the YAML write-back, and loadCalibrationOrIdentity's real load path
    %   (the "Phase 3 throw", finally retired).

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
        function rmTmp(testCase)
            if exist(testCase.tmpDir, 'dir')
                rmdir(testCase.tmpDir, 's');
            end
        end
    end

    methods (Test)

        function saveLoadRoundTrip(testCase)
            calib = struct('kind', 'slm_defocus', 'dzCmdUm', -10:10, ...
                'fit', struct('slopeUmPerCmd', 0.95, 'interceptUm', 1, 'r2', 0.99), ...
                'timestamp', datetime('now'));
            config.paths = struct('dataDir', testCase.tmpDir);
            path = tfp.io.saveCalibration(calib, 'slm_defocus', config);
            testCase.verifyTrue(isfile(path));

            back = tfp.io.loadCalibration(path, 'slm_defocus');
            testCase.verifyEqual(back.fit.slopeUmPerCmd, 0.95);

            testCase.verifyError(@() tfp.io.loadCalibration(path, 'etl_planes'), ...
                'tfp:io:loadCalibration:kindMismatch');
            testCase.verifyError(@() tfp.io.saveCalibration(calib, 'etl_planes', config), ...
                'tfp:io:saveCalibration:kindMismatch');
        end

        function acceptsForeignVariableNames(testCase)
            % The GUI's uiputfile save and run_powerMeterSweep use other
            % variable names ('calib' absent) — first variable wins.
            curve = struct('kind', 'power_curve', 'voltageV', 0:5);
            p = fullfile(testCase.tmpDir, 'legacy.mat');
            save(p, 'curve');
            back = tfp.io.loadCalibration(p);
            testCase.verifyEqual(back.voltageV, 0:5);
        end

        function configWriteBack(testCase)
            yamlPath = fullfile(testCase.tmpDir, 'rig.yaml');
            fid = fopen(yamlPath, 'w');
            fprintf(fid, ['hardwareKind: real\n' ...
                'slm:\n  enabled: true\n  calibration_file: ''''\n' ...
                'etl:\n  n_planes: 3\n  plane_calibration_file: ''old/path.mat''\n']);
            fclose(fid);

            tfp.io.updateConfigCalibrationPath(yamlPath, 'slm', ...
                'calibration_file', 'data/calibration/slm_defocus_1.mat');
            tfp.io.updateConfigCalibrationPath(yamlPath, 'etl', ...
                'plane_calibration_file', 'data\calibration\z_composed_2.mat');

            txt = fileread(yamlPath);
            testCase.verifySubstring(txt, ...
                'calibration_file: ''data/calibration/slm_defocus_1.mat''');
            testCase.verifySubstring(txt, ...
                'plane_calibration_file: ''data/calibration/z_composed_2.mat''');
            % Untouched keys survive.
            testCase.verifySubstring(txt, 'n_planes: 3');

            testCase.verifyError(@() tfp.io.updateConfigCalibrationPath( ...
                yamlPath, 'laser', 'calibration_file', 'x.mat'), ...
                'tfp:io:updateConfigCalibrationPath:sectionNotFound');
            testCase.verifyError(@() tfp.io.updateConfigCalibrationPath( ...
                yamlPath, 'slm', 'no_such_key', 'x.mat'), ...
                'tfp:io:updateConfigCalibrationPath:keyNotFound');
        end

        function loadCalibrationOrIdentityLoadsRealFiles(testCase)
            % With a configured file: LOADS (no more "Phase 3" throw).
            calib = struct('kind', 'dmd_affine', ...
                'dmdToScan_affine', [2 0 5; 0 2 7; 0 0 1], ...
                'dmdToSample_affine', eye(3), 'umPerPixel', 0.5);
            p = fullfile(testCase.tmpDir, 'lateral.mat');
            save(p, 'calib');

            config.calibration_file = p;
            out = tfp.io.loadCalibrationOrIdentity(config);
            testCase.verifyEqual(out.dmdToScan_affine(1, 1), 2);
            testCase.verifyEqual(out.pixelsPerUm, 2);   % derived from umPerPixel

            % Without a file: identity fallback from dmd.umPerPixel.
            cfg2 = struct('calibration_file', '', ...
                'dmd', struct('umPerPixel', 0.27));
            out2 = tfp.io.loadCalibrationOrIdentity(cfg2);
            testCase.verifyEqual(out2.dmdToScan_affine, eye(3));
            testCase.verifyEqual(out2.pixelsPerUm, 1 / 0.27, 'AbsTol', 1e-12);

            % A non-lateral file pointed at by mistake fails loudly.
            junk = struct('kind', 'slm_defocus', 'fit', struct());
            pj = fullfile(testCase.tmpDir, 'junk.mat');
            save(pj, 'junk');
            cfg3.calibration_file = pj;
            testCase.verifyError(@() tfp.io.loadCalibrationOrIdentity(cfg3), ...
                'tfp:io:loadCalibrationOrIdentity:badCalibration');
        end
    end
end
