classdef test_threeDShot_calibration < matlab.unittest.TestCase
%test_threeDShot_calibration Unit tests for Task 2 calibration parsers.
%
%   Covers:
%     loadSLMScanCalibration  — identity fallback, known affine round-trip
%     mapScanToSLM            — translate+scale affine, z passthrough
%     loadEfficiencyMap       — uniform fallback, grid parsing
%     efficiencyAtTargets     — uniform → ones; grid → interpolated values

    methods (Test)

        % --- loadSLMScanCalibration ---

        function testIdentityOnEmptyString(tc)
            calib = tfp.patterns.threeDShot.loadSLMScanCalibration('');
            tc.verifyEqual(calib.type,   'identity');
            tc.verifyEqual(calib.affine, eye(3));
            tc.verifyEqual(calib.zDefault, 0);
            tc.verifyEqual(calib.source,  'identity');
        end

        function testIdentityOnMissingArg(tc)
            calib = tfp.patterns.threeDShot.loadSLMScanCalibration();
            tc.verifyEqual(calib.type, 'identity');
            tc.verifyEqual(calib.affine, eye(3));
        end

        function testFileNotFoundError(tc)
            tc.verifyError( ...
                @() tfp.patterns.threeDShot.loadSLMScanCalibration('/no/such/file.mat'), ...
                'tfp:patterns:threeDShot:loadSLMScanCalibration:fileNotFound');
        end

        function testBadSchemaError(tc)
            % Create a .mat without the required field.
            tmpFile = [tempname, '.mat'];
            cleanupObj = onCleanup(@() deleteIfExists(tmpFile));
            wrongField = 42;  %#ok<NASGU>
            save(tmpFile, 'wrongField');
            tc.verifyError( ...
                @() tfp.patterns.threeDShot.loadSLMScanCalibration(tmpFile), ...
                'tfp:patterns:threeDShot:loadSLMScanCalibration:badSchema');
        end

        function testLoadValidCalibFile(tc)
            % Build a translate+scale affine and save it.
            % Translate by (10, 20) µm and scale x by 2, y by 3.
            scanToSlm_affine = [2 0 10; 0 3 20; 0 0 1];  %#ok<NASGU>
            tmpFile = [tempname, '.mat'];
            cleanupObj = onCleanup(@() deleteIfExists(tmpFile));
            save(tmpFile, 'scanToSlm_affine');

            calib = tfp.patterns.threeDShot.loadSLMScanCalibration(tmpFile);
            tc.verifyEqual(calib.type,   'affine');
            tc.verifyEqual(calib.affine, [2 0 10; 0 3 20; 0 0 1]);
            tc.verifyEqual(calib.zDefault, 0);
            tc.verifyEqual(calib.source, tmpFile);
        end

        function testLoadCalibFileWithZDefault(tc)
            scanToSlm_affine = eye(3);  %#ok<NASGU>
            zDefault = 15.5;            %#ok<NASGU>
            tmpFile = [tempname, '.mat'];
            cleanupObj = onCleanup(@() deleteIfExists(tmpFile));
            save(tmpFile, 'scanToSlm_affine', 'zDefault');

            calib = tfp.patterns.threeDShot.loadSLMScanCalibration(tmpFile);
            tc.verifyEqual(calib.zDefault, 15.5, 'AbsTol', 1e-10);
        end

        % --- mapScanToSLM ---

        function testMapIdentityCalib(tc)
            calib = tfp.patterns.threeDShot.loadSLMScanCalibration('');
            pts   = [3 7; -5 2; 0 0];
            out   = tfp.patterns.threeDShot.mapScanToSLM(pts, calib);
            tc.verifySize(out, [3 3]);
            tc.verifyEqual(out(:,1:2), pts, 'AbsTol', 1e-10);
            tc.verifyEqual(out(:,3), zeros(3,1), 'AbsTol', 1e-10);
        end

        function testMapTranslateScaleAffine(tc)
            % A = scale(2,3) + translate(10,20)
            A = [2 0 10; 0 3 20; 0 0 1];
            calib = struct('affine', A, 'type', 'affine', ...
                           'zDefault', 5, 'source', 'test');
            pts = [0 0; 1 1; -1 2];
            out = tfp.patterns.threeDShot.mapScanToSLM(pts, calib);

            expected_x = 2*pts(:,1) + 10;
            expected_y = 3*pts(:,2) + 20;
            tc.verifyEqual(out(:,1), expected_x, 'AbsTol', 1e-10);
            tc.verifyEqual(out(:,2), expected_y, 'AbsTol', 1e-10);
            % z must equal zDefault for all rows
            tc.verifyEqual(out(:,3), repmat(5, 3, 1), 'AbsTol', 1e-10);
        end

        function testMapRoundTripWithSavedCalib(tc)
            % Save an affine, load it, map a point, check result.
            scanToSlm_affine = [1 0 -7; 0 1 13; 0 0 1];  %#ok<NASGU>
            tmpFile = [tempname, '.mat'];
            cleanupObj = onCleanup(@() deleteIfExists(tmpFile));
            save(tmpFile, 'scanToSlm_affine');

            calib = tfp.patterns.threeDShot.loadSLMScanCalibration(tmpFile);
            pts   = [4 6];
            out   = tfp.patterns.threeDShot.mapScanToSLM(pts, calib);
            tc.verifyEqual(out(1,1), 4 - 7,  'AbsTol', 1e-10);
            tc.verifyEqual(out(1,2), 6 + 13, 'AbsTol', 1e-10);
            tc.verifyEqual(out(1,3), 0,       'AbsTol', 1e-10);
        end

        function testMapIgnoresInputZColumn(tc)
            % N×3 input: z column should be dropped and replaced by zDefault.
            calib = struct('affine', eye(3), 'type', 'identity', ...
                           'zDefault', 7, 'source', 'identity');
            pts3 = [1 2 999; 3 4 -50];
            out  = tfp.patterns.threeDShot.mapScanToSLM(pts3, calib);
            tc.verifyEqual(out(:,3), [7;7], 'AbsTol', 1e-10);
        end

        % --- loadEfficiencyMap ---

        function testUniformOnEmptyString(tc)
            effMap = tfp.patterns.threeDShot.loadEfficiencyMap('');
            tc.verifyEqual(effMap.type,   'uniform');
            tc.verifyEqual(effMap.source, 'uniform');
        end

        function testUniformOnMissingArg(tc)
            effMap = tfp.patterns.threeDShot.loadEfficiencyMap();
            tc.verifyEqual(effMap.type, 'uniform');
        end

        function testEffMapFileNotFound(tc)
            tc.verifyError( ...
                @() tfp.patterns.threeDShot.loadEfficiencyMap('/no/such/effmap.mat'), ...
                'tfp:patterns:threeDShot:loadEfficiencyMap:fileNotFound');
        end

        function testEffMapBadSchema(tc)
            tmpFile = [tempname, '.mat'];
            cleanupObj = onCleanup(@() deleteIfExists(tmpFile));
            junk = 1;  %#ok<NASGU>
            save(tmpFile, 'junk');
            tc.verifyError( ...
                @() tfp.patterns.threeDShot.loadEfficiencyMap(tmpFile), ...
                'tfp:patterns:threeDShot:loadEfficiencyMap:badSchema');
        end

        function testLoadValidEffMapFile(tc)
            x_um = linspace(-50, 50, 5);  %#ok<NASGU>
            y_um = linspace(-40, 40, 4);  %#ok<NASGU>
            eff  = 0.8 * ones(4, 5);      %#ok<NASGU>
            tmpFile = [tempname, '.mat'];
            cleanupObj = onCleanup(@() deleteIfExists(tmpFile));
            save(tmpFile, 'eff', 'x_um', 'y_um');

            effMap = tfp.patterns.threeDShot.loadEfficiencyMap(tmpFile);
            tc.verifyEqual(effMap.type, 'grid');
            tc.verifyEqual(effMap.source, tmpFile);
            tc.verifySize(effMap.eff, [4 5]);
        end

        % --- efficiencyAtTargets ---

        function testUniformEffMap(tc)
            effMap = tfp.patterns.threeDShot.loadEfficiencyMap('');
            targets = [0 0 0; 10 5 0; -3 7 0];
            eta = tfp.patterns.threeDShot.efficiencyAtTargets(targets, effMap);
            tc.verifySize(eta, [3 1]);
            tc.verifyEqual(eta, ones(3,1), 'AbsTol', 1e-10);
        end

        function testGridEffMapInterpolation(tc)
            % Build a simple grid where eff = (x+50)/100 (linear in x only).
            % x_um: 5 points -50,-25,0,25,50; y_um: 3 points -50,0,50.
            % meshgrid(x_um, y_um) → Xg is [3×5], eff is [3×5].
            % eff = 0 at x=-50, 0.5 at x=0, 1 at x=50.
            x_um = (-50:25:50);    % row vector, 5 points
            y_um = (-50:50:50);    % row vector, 3 points
            [Xg, ~] = meshgrid(x_um, y_um);
            eff = (Xg + 50) / 100;  %#ok<NASGU>

            tmpFile = [tempname, '.mat'];
            cleanupObj = onCleanup(@() deleteIfExists(tmpFile));
            save(tmpFile, 'eff', 'x_um', 'y_um');

            effMap = tfp.patterns.threeDShot.loadEfficiencyMap(tmpFile);

            % Query at x=0, y=0 → expected eff = 0.5
            targets = [0 0 0];
            eta = tfp.patterns.threeDShot.efficiencyAtTargets(targets, effMap);
            tc.verifyEqual(eta, 0.5, 'AbsTol', 1e-6);
        end

        function testGridEffMapOutOfRange(tc)
            % Out-of-range points should get the minimum positive value, not NaN.
            x_um = [0 10 20];
            y_um = [0 10];
            eff  = [0.5 0.6 0.7; 0.4 0.5 0.6];
            tmpFile = [tempname, '.mat'];
            cleanupObj = onCleanup(@() deleteIfExists(tmpFile));
            save(tmpFile, 'eff', 'x_um', 'y_um');

            effMap = tfp.patterns.threeDShot.loadEfficiencyMap(tmpFile);
            targets = [1000 1000 0];  % way outside grid
            eta = tfp.patterns.threeDShot.efficiencyAtTargets(targets, effMap);
            minEff = min(eff(:));
            tc.verifyEqual(eta, minEff, 'AbsTol', 1e-10);
        end

        function testGridEffMapAllOnes(tc)
            % Uniform grid with value 1.0 → all ones
            x_um = 0:10:50;
            y_um = 0:10:50;
            eff  = ones(numel(y_um), numel(x_um));
            tmpFile = [tempname, '.mat'];
            cleanupObj = onCleanup(@() deleteIfExists(tmpFile));
            save(tmpFile, 'eff', 'x_um', 'y_um');

            effMap = tfp.patterns.threeDShot.loadEfficiencyMap(tmpFile);
            targets = [25 25 0; 10 10 0];
            eta = tfp.patterns.threeDShot.efficiencyAtTargets(targets, effMap);
            tc.verifyEqual(eta, ones(2,1), 'AbsTol', 1e-10);
        end

    end % methods Test

end % classdef

% --- Local helper ---
function deleteIfExists(f)
if isfile(f), delete(f); end
end
