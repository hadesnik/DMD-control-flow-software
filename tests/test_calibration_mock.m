classdef test_calibration_mock < matlab.unittest.TestCase
    %test_calibration_mock Calibration tests using mock hardware.
    %   fakeAffineRoundTrip  — verifies alignDMDtoCamera_mock struct fields
    %                          and inverse-transform round-trip error.
    %   liveMockCalibration  — runs alignDMDtoCamera end-to-end with
    %                          MockDMD + MockSubstageCamera and a known
    %                          truth affine; verifies the recovered affine
    %                          is close to the ground truth.

    methods (Test)
        function fakeAffineRoundTrip(testCase)
            dmd   = struct('nRows', 800, 'nCols', 1280);
            calib = tfp.calibration.alignDMDtoCamera_mock(dmd);

            % --- required fields present ---
            requiredFields = {'dmdToSample_affine', 'umPerPixel', ...
                'pixelsPerUm', 'powerCurve', 'timestamp', ...
                'notes', 'residualErrorPx', 'nCalibrationPoints'};
            for k = 1:numel(requiredFields)
                testCase.verifyTrue(isfield(calib, requiredFields{k}), ...
                    ['Missing field: ' requiredFields{k}]);
            end

            % --- affine matrix is 3×3 ---
            testCase.verifySize(calib.dmdToSample_affine, [3 3]);

            % --- umPerPixel and pixelsPerUm are consistent ---
            testCase.verifyEqual(calib.umPerPixel * calib.pixelsPerUm, 1.0, ...
                'AbsTol', 1e-10, 'umPerPixel * pixelsPerUm must equal 1');

            % --- bottom row is [0 0 1] (proper affine, not projective) ---
            testCase.verifyEqual(calib.dmdToSample_affine(3,:), [0 0 1], ...
                'AbsTol', 1e-12, 'Bottom row of affine must be [0 0 1]');

            % --- round-trip: DMD → image → DMD error < 0.1 px ---
            A    = calib.dmdToSample_affine;
            Ainv = inv(A);

            dmdCoords = [100, 200; 640, 400; 300, 600; 1000, 100; 500, 500];
            N         = size(dmdCoords, 1);

            % forward: DMD [col,row] → image [x,y]
            homDMD   = [dmdCoords, ones(N,1)]';     % 3 × N
            homImg   = A * homDMD;                  % 3 × N
            imgCoords = homImg(1:2,:)';              % N × 2

            % inverse: image [x,y] → DMD [col,row]
            homImgH  = [imgCoords, ones(N,1)]';     % 3 × N
            homBack  = Ainv * homImgH;              % 3 × N
            dmdBack  = homBack(1:2,:)';             % N × 2

            err = sqrt(sum((dmdCoords - dmdBack).^2, 2));
            testCase.verifyLessThan(max(err), 0.1, ...
                'Round-trip error must be < 0.1 pixels');
        end

        function liveMockCalibration(testCase)
            %liveMockCalibration End-to-end calibration with MockDMD + MockSubstageCamera.
            %   Uses a 3x3 grid (9 points) and a known truth affine. The
            %   recovered affine must match the truth to within 1 px in
            %   translation and 0.05 in scale, and the RMS residual must be
            %   below 1 camera pixel.

            % --- small DMD so pattern generation is fast ---
            dmdCfg.nRows                    = 200;
            dmdCfg.nCols                    = 320;
            dmdCfg.loadLatencyMsPerPattern  = 0;
            dmd = tfp.hardware.MockDMD();
            dmd.initialize(dmdCfg);

            % --- truth affine: 0.5x scale + translation ---
            truthAffine = [0.5  0   20; ...
                           0    0.5 10; ...
                           0    0   1 ];

            camCfg.nRows       = 256;
            camCfg.nCols       = 320;
            camCfg.dmd         = dmd;
            camCfg.truthAffine = truthAffine;
            camCfg.noiseLevel  = 0.02;   % low noise for reliable centroid
            camCfg.spotSigmaPx = 4;
            cam = tfp.hardware.MockSubstageCamera();
            cam.initialize(camCfg);

            opts.nGridPoints = 3;       % 3x3 = 9 points, fast
            opts.gridSpacing = 50;
            opts.spotRadius  = 8;
            opts.exposureS   = 0;       % no real pause needed in mock
            opts.showFigure  = false;

            calib = tfp.calibration.alignDMDtoCamera(dmd, cam, opts);

            % --- struct fields present ---
            testCase.verifyTrue(isfield(calib, 'dmdToSample_affine'));
            testCase.verifyTrue(isfield(calib, 'residualErrorPx'));
            testCase.verifyTrue(isfield(calib, 'nCalibrationPoints'));
            testCase.verifyEqual(calib.nCalibrationPoints, 9);

            % --- residual is small (clean synthetic data) ---
            testCase.verifyLessThan(calib.residualErrorPx, 1.0, ...
                'RMS residual should be < 1 px with clean mock images');

            % --- recovered affine is close to truth affine ---
            A = calib.dmdToSample_affine;
            testCase.verifyEqual(A(1,1), truthAffine(1,1), 'AbsTol', 0.05, ...
                'x scale (A(1,1)) should match truth');
            testCase.verifyEqual(A(2,2), truthAffine(2,2), 'AbsTol', 0.05, ...
                'y scale (A(2,2)) should match truth');
            testCase.verifyEqual(A(1,3), truthAffine(1,3), 'AbsTol', 1.0, ...
                'x offset (A(1,3)) should match truth');
            testCase.verifyEqual(A(2,3), truthAffine(2,3), 'AbsTol', 1.0, ...
                'y offset (A(2,3)) should match truth');
        end
    end
end
