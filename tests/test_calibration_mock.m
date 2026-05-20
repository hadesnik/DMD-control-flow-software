classdef test_calibration_mock < matlab.unittest.TestCase
    %test_calibration_mock Calibration tests using mock hardware.
    %   fakeAffineRoundTrip        — verifies alignDMDtoCamera_mock struct fields
    %                                and inverse-transform round-trip error.
    %   liveMockCalibration        — runs alignDMDtoCamera end-to-end with
    %                                MockDMD + MockSubstageCamera and a known
    %                                truth affine; verifies the recovered affine
    %                                is close to the ground truth.
    %   composeCalibrationMath     — unit tests for composeCalibration: known
    %                                affines, NaN axis signs, field preservation,
    %                                round-trip, and error conditions.
    %   mockCrossRegRoundTrip      — verifies crossRegisterScanImage_mock fields,
    %                                affine composition math, and round-trip.
    %                                No Image Processing Toolbox required.
    %   liveMockCrossRegister      — runs crossRegisterScanImage end-to-end with
    %                                MockSubstageCamera (scanRect mode) and a known
    %                                truth scanToCam affine; verifies recovered
    %                                affine and composition.
    %                                Requires Image Processing Toolbox.
    %   verifySignsDefaultPositive — verifyScanFieldComposition with mockResponse
    %                                (+1,+1): signs confirmed, scanVerified=true,
    %                                dmdToScan_affine unchanged.
    %   verifySignsFlipFast        — mockResponse (-1,+1): fast-axis correction
    %                                matrix applied to dmdToScan_affine.

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
        function composeCalibrationMath(testCase)
            %composeCalibrationMath Direct unit tests for composeCalibration.
            %   Uses two known closed-form affines so composition and round-trip
            %   can be verified analytically.  No hardware or Image Processing
            %   Toolbox required.

            % --- build a minimal dmdCalib (as from alignDMDtoCamera_mock) ---
            dmdCalib.dmdToSample_affine = [0.5  0   20; ...
                                           0    0.5 10; ...
                                           0    0   1 ];
            dmdCalib.umPerPixel  = 1.56;
            dmdCalib.pixelsPerUm = 1/1.56;
            dmdCalib.powerCurve  = struct();
            dmdCalib.timestamp   = datetime('now');
            dmdCalib.notes       = 'unit test dmd calib';
            dmdCalib.residualErrorPx    = 0;
            dmdCalib.nCalibrationPoints = 0;

            % --- build a minimal scanReg with NaN axis signs ---
            scanReg.scanToCam_affine    = [2.0  0   50; ...
                                           0    2.0 25; ...
                                           0    0   1 ];
            scanReg.scan_fast_axis_sign = NaN;
            scanReg.scan_slow_axis_sign = NaN;

            composed = tfp.calibration.composeCalibration(dmdCalib, scanReg);

            % --- all original dmdCalib fields preserved ---
            origFields = fieldnames(dmdCalib);
            for k = 1:numel(origFields)
                testCase.verifyTrue(isfield(composed, origFields{k}), ...
                    ['Original field lost: ' origFields{k}]);
            end

            % --- new fields present ---
            testCase.verifyTrue(isfield(composed, 'scanToCam_affine'),    'Missing scanToCam_affine');
            testCase.verifyTrue(isfield(composed, 'dmdToScan_affine'),    'Missing dmdToScan_affine');
            testCase.verifyTrue(isfield(composed, 'scan_fast_axis_sign'), 'Missing scan_fast_axis_sign');
            testCase.verifyTrue(isfield(composed, 'scan_slow_axis_sign'), 'Missing scan_slow_axis_sign');
            testCase.verifyTrue(isfield(composed, 'composedAt'),          'Missing composedAt');

            % --- axis signs passed through as NaN ---
            testCase.verifyTrue(isnan(composed.scan_fast_axis_sign), 'fast sign should be NaN');
            testCase.verifyTrue(isnan(composed.scan_slow_axis_sign), 'slow sign should be NaN');

            % --- axis signs pass through as ±1 when set ---
            scanRegSigned = scanReg;
            scanRegSigned.scan_fast_axis_sign = 1;
            scanRegSigned.scan_slow_axis_sign = -1;
            c2 = tfp.calibration.composeCalibration(dmdCalib, scanRegSigned);
            testCase.verifyEqual(c2.scan_fast_axis_sign,  1, 'fast sign +1');
            testCase.verifyEqual(c2.scan_slow_axis_sign, -1, 'slow sign -1');

            % --- dmdToScan_affine equals inv(scanToCam) * dmdToSample exactly ---
            expected = inv(scanReg.scanToCam_affine) * dmdCalib.dmdToSample_affine; %#ok<MINV>
            testCase.verifyEqual(composed.dmdToScan_affine, expected, ...
                'AbsTol', 1e-12, 'dmdToScan must equal inv(scanToCam)*dmdToSample');

            % --- bottom row of dmdToScan is [0 0 1] ---
            testCase.verifyEqual(composed.dmdToScan_affine(3,:), [0 0 1], ...
                'AbsTol', 1e-12, 'bottom row must be [0 0 1]');

            % --- round-trip: DMD → scan → camera → DMD error < 1e-10 px ---
            dmdPts = [100 200; 640 400; 300 600; 1000 100; 500 500];
            N      = size(dmdPts, 1);
            hom    = [dmdPts, ones(N,1)]';
            homScan = composed.dmdToScan_affine * hom;
            homCam  = scanReg.scanToCam_affine  * homScan;
            homBack = inv(dmdCalib.dmdToSample_affine) * homCam; %#ok<MINV>
            dmdBack = homBack(1:2,:)';
            err = sqrt(sum((dmdPts - dmdBack).^2, 2));
            testCase.verifyLessThan(max(err), 1e-10, ...
                'DMD→scan→cam→DMD round-trip error must be < 1e-10 px');

            % --- error: missing dmdToSample_affine ---
            badDmd = rmfield(dmdCalib, 'dmdToSample_affine');
            testCase.verifyError( ...
                @() tfp.calibration.composeCalibration(badDmd, scanReg), ...
                'tfp:calibration:composeCalibration:missingDmdAffine');

            % --- error: missing scanToCam_affine ---
            badScan = rmfield(scanReg, 'scanToCam_affine');
            testCase.verifyError( ...
                @() tfp.calibration.composeCalibration(dmdCalib, badScan), ...
                'tfp:calibration:composeCalibration:missingScanRegField');

            % --- error: singular scanToCam ---
            singularScan          = scanReg;
            singularScan.scanToCam_affine = zeros(3);
            testCase.verifyError( ...
                @() tfp.calibration.composeCalibration(dmdCalib, singularScan), ...
                'tfp:calibration:composeCalibration:singularAffine');

            % --- error: bad axis sign value ---
            badSign = scanReg;
            badSign.scan_fast_axis_sign = 2;
            testCase.verifyError( ...
                @() tfp.calibration.composeCalibration(dmdCalib, badSign), ...
                'tfp:calibration:composeCalibration:badAxisSign');
        end

        function mockCrossRegRoundTrip(testCase)
            %mockCrossRegRoundTrip Verify crossRegisterScanImage_mock fields and math.
            %   Uses alignDMDtoCamera_mock to produce a dmdCalib, then calls
            %   crossRegisterScanImage_mock. Checks all output fields, the
            %   3x3 bottom row, sign fields are NaN, and that dmdToScan_affine
            %   equals inv(scanToCam) * dmdToSample exactly.

            dmdStub.nRows = 800; dmdStub.nCols = 1280;
            dmdCalib = tfp.calibration.alignDMDtoCamera_mock(dmdStub);

            opts.scaleF     = 1.8;
            opts.scaleS     = 1.8;
            opts.offsetX    = 45;
            opts.offsetY    = 25;
            opts.scanPixels = [512, 256];

            calib = tfp.calibration.crossRegisterScanImage_mock(dmdCalib, opts);

            % --- required fields ---
            requiredFields = {'dmdToSample_affine', 'scanToCam_affine', ...
                'dmdToScan_affine', 'scanPixels', 'scan_fast_axis_sign', ...
                'scan_slow_axis_sign', 'rectBboxPx', 'fastAxisIsHorizontal', ...
                'timestamp', 'notes'};
            for k = 1:numel(requiredFields)
                testCase.verifyTrue(isfield(calib, requiredFields{k}), ...
                    ['Missing field: ' requiredFields{k}]);
            end

            % --- scanToCam_affine is 3x3 with [0 0 1] bottom row ---
            testCase.verifySize(calib.scanToCam_affine, [3 3]);
            testCase.verifyEqual(calib.scanToCam_affine(3,:), [0 0 1], ...
                'AbsTol', 1e-12, 'Bottom row of scanToCam_affine must be [0 0 1]');

            % --- axis sign fields are NaN (pending verify step) ---
            testCase.verifyTrue(isnan(calib.scan_fast_axis_sign), ...
                'scan_fast_axis_sign must be NaN before verify step');
            testCase.verifyTrue(isnan(calib.scan_slow_axis_sign), ...
                'scan_slow_axis_sign must be NaN before verify step');

            % --- scale and offset match options ---
            testCase.verifyEqual(calib.scanToCam_affine(1,1), opts.scaleF, ...
                'AbsTol', 1e-12, 'fast scale');
            testCase.verifyEqual(calib.scanToCam_affine(2,2), opts.scaleS, ...
                'AbsTol', 1e-12, 'slow scale');
            testCase.verifyEqual(calib.scanToCam_affine(1,3), opts.offsetX, ...
                'AbsTol', 1e-12, 'x offset');
            testCase.verifyEqual(calib.scanToCam_affine(2,3), opts.offsetY, ...
                'AbsTol', 1e-12, 'y offset');

            % --- dmdToScan is exactly inv(scanToCam) * dmdToSample ---
            expected = inv(calib.scanToCam_affine) * calib.dmdToSample_affine; %#ok<MINV>
            testCase.verifyEqual(calib.dmdToScan_affine, expected, ...
                'AbsTol', 1e-10, 'dmdToScan_affine must equal inv(scanToCam)*dmdToSample');

            % --- round-trip: DMD → camera → scan-field → camera round trip ---
            dmdPts = [100 200; 640 400; 300 600; 1000 100];
            N      = size(dmdPts, 1);
            homDMD = [dmdPts, ones(N,1)]';
            % DMD → scan
            homScan = calib.dmdToScan_affine * homDMD;
            % scan → camera via scanToCam
            homCam  = calib.scanToCam_affine * homScan;
            % camera → DMD via inv(dmdToSample)
            homBack = inv(calib.dmdToSample_affine) * homCam; %#ok<MINV>
            dmdBack = homBack(1:2,:)';
            err = sqrt(sum((dmdPts - dmdBack).^2, 2));
            testCase.verifyLessThan(max(err), 0.01, ...
                'DMD → scan → cam → DMD round-trip error must be < 0.01 px');
        end

        function liveMockCrossRegister(testCase)
            %liveMockCrossRegister End-to-end crossRegisterScanImage with MockSubstageCamera.
            %   Sets up MockSubstageCamera with scanRect derived from a known truth
            %   scanToCam affine. Verifies the recovered affine is close to the
            %   truth and that dmdToScan_affine is correctly composed.
            %   Requires Image Processing Toolbox (bwconncomp, regionprops, etc.).

            nFast = 512; nSlow = 256;

            % Truth affine: [x;y;1] = A * [fast;slow;1] using BoundingBox-corner
            % convention (scan index 1 maps to BoundingBox edge, not pixel center).
            % With scale=2.0: width = 2*(nFast-1) = 1022, height = 2*(nSlow-1) = 510.
            trueScale = 2.0;
            x1 = 52; y1 = 32;           % rendered rectangle top-left pixel (1-indexed)
            W  = trueScale * (nFast-1);  % 1022 camera pixels wide
            H  = trueScale * (nSlow-1);  % 510  camera pixels tall
            % BoundingBox xmin = x1 - 0.5, so truth offset = (x1-0.5) - trueScale*1
            trueOffX = (x1 - 0.5) - trueScale;   % 49.5
            trueOffY = (y1 - 0.5) - trueScale;   % 29.5
            truthScanToCam = [trueScale  0          trueOffX; ...
                              0          trueScale  trueOffY; ...
                              0          0          1       ];

            camCfg.nRows     = 700;
            camCfg.nCols     = 1300;
            camCfg.noiseLevel = 0.01;  % low noise for clean rectangle detection
            camCfg.scanRect  = [x1, y1, round(W), round(H)];  % [52, 32, 1022, 510]
            cam = tfp.hardware.MockSubstageCamera();
            cam.initialize(camCfg);

            dmdCalib.dmdToSample_affine = eye(3);  % identity for simple composition check

            opts.scanPixels = [nFast, nSlow];
            opts.threshFrac = 0.3;
            opts.showFigure = false;

            calib = tfp.calibration.crossRegisterScanImage(cam, dmdCalib, opts);

            % --- required fields ---
            testCase.verifyTrue(isfield(calib, 'scanToCam_affine'),   'Missing scanToCam_affine');
            testCase.verifyTrue(isfield(calib, 'dmdToScan_affine'),   'Missing dmdToScan_affine');
            testCase.verifyTrue(isfield(calib, 'scan_fast_axis_sign'),'Missing scan_fast_axis_sign');
            testCase.verifyTrue(isfield(calib, 'scan_slow_axis_sign'),'Missing scan_slow_axis_sign');
            testCase.verifyTrue(isfield(calib, 'rectBboxPx'),         'Missing rectBboxPx');
            testCase.verifyEqual(calib.scanPixels, [nFast, nSlow]);

            % --- axis signs are NaN ---
            testCase.verifyTrue(isnan(calib.scan_fast_axis_sign), ...
                'scan_fast_axis_sign must be NaN before verify step');
            testCase.verifyTrue(isnan(calib.scan_slow_axis_sign), ...
                'scan_slow_axis_sign must be NaN before verify step');

            % --- fast axis identified correctly (W > H so horizontal) ---
            testCase.verifyTrue(calib.fastAxisIsHorizontal, ...
                'Fast axis should be horizontal (wider bbox dimension)');

            % --- recovered scale close to truth ---
            A = calib.scanToCam_affine;
            testCase.verifyEqual(A(1,1), truthScanToCam(1,1), 'AbsTol', 0.05, ...
                'fast-axis scale A(1,1)');
            testCase.verifyEqual(A(2,2), truthScanToCam(2,2), 'AbsTol', 0.05, ...
                'slow-axis scale A(2,2)');
            testCase.verifyEqual(A(1,3), truthScanToCam(1,3), 'AbsTol', 1.5, ...
                'fast-axis offset A(1,3)');
            testCase.verifyEqual(A(2,3), truthScanToCam(2,3), 'AbsTol', 1.5, ...
                'slow-axis offset A(2,3)');

            % --- dmdToScan composition is exact (identity dmdCalib case) ---
            %     dmdToScan = inv(scanToCam) * eye(3) = inv(scanToCam)
            expectedDmdToScan = inv(calib.scanToCam_affine) * dmdCalib.dmdToSample_affine; %#ok<MINV>
            testCase.verifyEqual(calib.dmdToScan_affine, expectedDmdToScan, ...
                'AbsTol', 1e-10, 'dmdToScan_affine composition');
        end

        function verifySignsDefaultPositive(testCase)
            %verifySignsDefaultPositive Signs (+1,+1) confirmed; dmdToScan_affine unchanged.
            %   Uses crossRegisterScanImage_mock to build calib, then calls
            %   verifyScanFieldComposition with mockResponse=[+1,+1]. Verifies
            %   signs are recorded, scanVerified is set, and dmdToScan_affine
            %   is numerically identical to the pre-verify value (no correction).

            dmdStub.nRows = 800; dmdStub.nCols = 1280;
            dmdCalib = tfp.calibration.alignDMDtoCamera_mock(dmdStub);
            calib    = tfp.calibration.crossRegisterScanImage_mock(dmdCalib);

            dmdCfg.nRows                   = 800;
            dmdCfg.nCols                   = 1280;
            dmdCfg.loadLatencyMsPerPattern = 0;
            dmd = tfp.hardware.MockDMD();
            dmd.initialize(dmdCfg);

            baseAffine = calib.dmdToScan_affine;

            opts.testDmdCoord = [640, 400];
            opts.fovSizeUm    = 800;
            opts.mockResponse = [1, 1];

            calibOut = tfp.calibration.verifyScanFieldComposition(dmd, calib, opts);

            % Signs confirmed correctly
            testCase.verifyEqual(calibOut.scan_fast_axis_sign, 1, ...
                'fast_sign should be +1');
            testCase.verifyEqual(calibOut.scan_slow_axis_sign, 1, ...
                'slow_sign should be +1');

            % Metadata fields set
            testCase.verifyTrue(calibOut.scanVerified, ...
                'scanVerified must be true after confirmation');
            testCase.verifyTrue(isfield(calibOut, 'scanVerifyTimestamp'), ...
                'scanVerifyTimestamp must be present');

            % With signs (+1,+1) the correction matrices are both identity,
            % so dmdToScan_affine must be numerically unchanged.
            testCase.verifyEqual(calibOut.dmdToScan_affine, baseAffine, ...
                'AbsTol', 1e-12, ...
                'dmdToScan_affine should be unchanged for default signs (+1,+1)');
        end

        function verifySignsFlipFast(testCase)
            %verifySignsFlipFast Signs (-1,+1) confirmed; fast-axis flip applied.
            %   Verifies that confirming fast_sign=-1 applies the correction
            %   matrix [-1 0 nFast+1; 0 1 0; 0 0 1] to dmdToScan_affine.

            dmdStub.nRows = 800; dmdStub.nCols = 1280;
            dmdCalib = tfp.calibration.alignDMDtoCamera_mock(dmdStub);

            crossOpts.scanPixels = [512, 256];
            calib = tfp.calibration.crossRegisterScanImage_mock(dmdCalib, crossOpts);

            dmdCfg.nRows                   = 800;
            dmdCfg.nCols                   = 1280;
            dmdCfg.loadLatencyMsPerPattern = 0;
            dmd = tfp.hardware.MockDMD();
            dmd.initialize(dmdCfg);

            baseAffine = calib.dmdToScan_affine;
            nFast      = calib.scanPixels(1);

            opts.testDmdCoord = [640, 400];
            opts.fovSizeUm    = 800;
            opts.mockResponse = [-1, 1];

            calibOut = tfp.calibration.verifyScanFieldComposition(dmd, calib, opts);

            % Signs confirmed correctly
            testCase.verifyEqual(calibOut.scan_fast_axis_sign, -1, ...
                'fast_sign should be -1');
            testCase.verifyEqual(calibOut.scan_slow_axis_sign,  1, ...
                'slow_sign should be +1');
            testCase.verifyTrue(calibOut.scanVerified, ...
                'scanVerified must be true');

            % Corrected dmdToScan = flipFast * baseAffine
            %   flipFast = [-1 0 nFast+1; 0 1 0; 0 0 1]
            corrFast   = [-1  0  (nFast+1); 0  1  0; 0  0  1];
            expected   = corrFast * baseAffine;
            testCase.verifyEqual(calibOut.dmdToScan_affine, expected, ...
                'AbsTol', 1e-12, ...
                'dmdToScan_affine must be corrFast * base after fast_sign=-1');
        end
    end
end
