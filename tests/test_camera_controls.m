classdef test_camera_controls < matlab.unittest.TestCase
    %test_camera_controls Runtime camera controls on the SubstageCamera base
    %   and its mock, plus the makeCamera factory.
    %
    %   The controls are CONCRETE-with-default-throw on the base rather than
    %   abstract, so that adding them could not break construction of the
    %   existing subclasses or of any subclass in the sibling consumer repo.
    %   These tests pin both halves of that: the base refuses, the mock honours.
    %
    %   Methods:
    %     baseDefaultsRefuse / baseAdvertisesNothing
    %     snapAveragedIsConcreteOnTheBase — averaging is not a device feature.
    %     mockAdvertisesEverything
    %     exposureScalesSignal / gainScalesSignal
    %     binningChangesGeometryAndReducesNoise
    %     roiCropsAndReports / resetRoiRestores
    %     bitDepthFromFormat — the Mono12 normaliser, which was 16x wrong.
    %     rejectsBadArguments
    %     makeCameraDispatches / makeCameraLegacyClass / makeCameraBadBackend

    methods (Access = private)
        function cam = mockCam(~, varargin)
            cam = tfp.hardware.MockSubstageCamera();
            cfg = struct('nRows', 256, 'nCols', 256, 'noiseLevel', 0.1, ...
                'exposureMs', 10);
            for k = 1:2:numel(varargin)
                cfg.(varargin{k}) = varargin{k+1};
            end
            cam.initialize(cfg);
        end
    end

    methods (Test)

        % --- base class ---------------------------------------------------
        function baseDefaultsRefuse(testCase)
            % SubstageCamera_generic inherits every default untouched.
            cam = tfp.hardware.SubstageCamera_generic();
            for m = {'setExposureMs', 'setGain', 'setBinning', 'setPixelFormat'}
                testCase.verifyError(@() cam.(m{1})(1), ...
                    'tfp:hardware:SubstageCamera:notSupported', ...
                    sprintf('%s must refuse by default', m{1}));
            end
            testCase.verifyError(@() cam.getExposureMs(), ...
                'tfp:hardware:SubstageCamera:notSupported');
        end

        function baseAdvertisesNothing(testCase)
            cam  = tfp.hardware.SubstageCamera_generic();
            caps = cam.getCapabilities();
            testCase.verifyFalse(any(struct2array(caps)), ...
                'a backend must not advertise a control it has not implemented');
            testCase.verifyEqual(cam.getBitDepth(), 8);
        end

        function snapAveragedIsConcreteOnTheBase(testCase)
            % Averaging is image math, not a device API, so the base can
            % implement it for every backend at once.
            cam = testCase.mockCam('noiseLevel', 0.4);
            one  = cam.snap();
            many = cam.snapAveraged(16);
            testCase.verifyEqual(size(many), size(one));
            testCase.verifyLessThan(std(many(:)), std(one(:)), ...
                'averaging 16 frames must reduce the noise');
            testCase.verifyError(@() cam.snapAveraged(0), ...
                'tfp:hardware:SubstageCamera:badAverageCount');
        end

        % --- mock backend --------------------------------------------------
        function mockAdvertisesEverything(testCase)
            caps = testCase.mockCam().getCapabilities();
            testCase.verifyTrue(all(struct2array(caps)));
        end

        function exposureScalesSignal(testCase)
            cam = testCase.mockCam('noiseLevel', 0.1, 'exposureMs', 10);
            base = mean(cam.snap(), 'all');
            cam.setExposureMs(20);
            testCase.verifyEqual(cam.getExposureMs(), 20);
            doubled = mean(cam.snap(), 'all');
            testCase.verifyEqual(doubled / base, 2, 'RelTol', 0.15, ...
                'doubling the exposure must roughly double the signal');
        end

        function gainScalesSignal(testCase)
            cam = testCase.mockCam('noiseLevel', 0.1);
            base = mean(cam.snap(), 'all');
            cam.setGain(6);                     % +6 dB ~ x2 in amplitude
            gained = mean(cam.snap(), 'all');
            testCase.verifyEqual(gained / base, 10^(6/20), 'RelTol', 0.15);
        end

        function binningChangesGeometryAndReducesNoise(testCase)
            cam = testCase.mockCam('noiseLevel', 0.4);
            unbinned = cam.snap();
            cam.setBinning(2);
            testCase.verifyEqual(cam.getBinning(), 2);
            testCase.verifyEqual([cam.nRows, cam.nCols], [128, 128]);
            binned = cam.snap();
            testCase.verifyEqual(size(binned), [128, 128], ...
                'the returned array must match the reported geometry');
            testCase.verifyLessThan(std(binned(:)), std(unbinned(:)), ...
                '2x2 binning must reduce pixel noise');
        end

        function roiCropsAndReports(testCase)
            cam = testCase.mockCam();
            cam.setRoi([33, 17, 64, 48]);
            testCase.verifyEqual(cam.getRoi(), [33, 17, 64, 48]);
            testCase.verifyEqual([cam.nRows, cam.nCols], [48, 64]);
            testCase.verifyEqual(size(cam.snap()), [48, 64]);
        end

        function resetRoiRestores(testCase)
            cam = testCase.mockCam();
            cam.setRoi([10, 10, 32, 32]);
            cam.resetRoi();
            testCase.verifyEqual([cam.nRows, cam.nCols], [256, 256]);
            testCase.verifyEqual(size(cam.snap()), [256, 256]);
        end

        function roiAndBinningCompose(testCase)
            cam = testCase.mockCam();
            cam.setRoi([1, 1, 100, 80]);
            cam.setBinning(2);
            testCase.verifyEqual([cam.nRows, cam.nCols], [40, 50]);
            testCase.verifyEqual(size(cam.snap()), [40, 50]);
        end

        % --- the Mono12 normaliser ------------------------------------------
        function bitDepthFromFormat(testCase)
            % The bug: Mono12 rides in a uint16 container, so normalising by
            % intmax('uint16') made every 12-bit frame 16x too dim.
            testCase.verifyEqual( ...
                tfp.hardware.BaslerSubstageCamera.bitsForFormat('Mono8'),  8);
            testCase.verifyEqual( ...
                tfp.hardware.BaslerSubstageCamera.bitsForFormat('Mono12'), 12);
            testCase.verifyEqual( ...
                tfp.hardware.BaslerSubstageCamera.bitsForFormat('Mono16'), 16);
            testCase.verifyEqual( ...
                tfp.hardware.BaslerSubstageCamera.bitsForFormat('weird'),  8);

            cam = testCase.mockCam('format', 'Mono12');
            testCase.verifyEqual(cam.getBitDepth(), 12);
            % quantisation must be on the 12-bit grid, not the 8-bit one
            f = cam.snap();
            levels = 2^12 - 1;
            testCase.verifyEqual(f * levels, round(f * levels), 'AbsTol', 1e-9);
        end

        function rejectsBadArguments(testCase)
            cam = testCase.mockCam();
            testCase.verifyError(@() cam.setExposureMs(-1), ...
                'tfp:hardware:MockSubstageCamera:badExposure');
            testCase.verifyError(@() cam.setGain(NaN), ...
                'tfp:hardware:MockSubstageCamera:badGain');
            testCase.verifyError(@() cam.setBinning(3), ...
                'tfp:hardware:MockSubstageCamera:badBinning');
            testCase.verifyError(@() cam.setRoi([1 1 0 10]), ...
                'tfp:hardware:MockSubstageCamera:badRoi');
        end

        % --- factory ---------------------------------------------------------
        function makeCameraDispatches(testCase)
            cfg.camera = struct('backend', 'mock', 'nRows', 64, 'nCols', 64);
            cam = tfp.hardware.makeCamera(cfg);
            testCase.verifyClass(cam, 'tfp.hardware.MockSubstageCamera');
            testCase.verifyTrue(cam.isInitialized);
            testCase.verifyEqual([cam.nRows, cam.nCols], [64, 64]);

            % The Basler backend is dispatched by name but never initialised
            % here: the gentl adaptor does not exist on the dev machine.
            cfgB.camera = struct('backend', 'basler');
            camB = tfp.hardware.makeCamera(cfgB, struct('initialize', false));
            testCase.verifyClass(camB, 'tfp.hardware.BaslerSubstageCamera');
            testCase.verifyFalse(camB.isInitialized);
            caps = camB.getCapabilities();
            testCase.verifyTrue(all(struct2array(caps)), ...
                'the Basler backend must advertise every runtime control');
        end

        function makeCameraLegacyClass(testCase)
            % An unedited configs/real.yaml has camera.class and no backend.
            cfg.camera = struct('class', 'tfp.hardware.MockSubstageCamera', ...
                'nRows', 32, 'nCols', 32);
            cam = tfp.hardware.makeCamera(cfg);
            testCase.verifyClass(cam, 'tfp.hardware.MockSubstageCamera');
        end

        function makeCameraBadBackend(testCase)
            cfg.camera = struct('backend', 'nikon');
            testCase.verifyError(@() tfp.hardware.makeCamera(cfg), ...
                'tfp:hardware:makeCamera:badBackend');
        end

        function makeCameraInjectsMockOnlyConfig(testCase)
            % A .dmd handle and a truthAffine cannot come from YAML, so the
            % factory has to accept them out of band for mock sessions.
            dmd = tfp.hardware.MockDMD();
            dmd.initialize(struct('nRows', 100, 'nCols', 100));
            cfg.camera = struct('backend', 'mock', 'nRows', 64, 'nCols', 64);
            cam = tfp.hardware.makeCamera(cfg, struct('cameraConfig', ...
                struct('dmd', dmd, 'truthAffine', eye(3))));
            testCase.verifyTrue(cam.isInitialized);
        end
    end
end
