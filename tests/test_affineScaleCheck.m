classdef test_affineScaleCheck < matlab.unittest.TestCase
    %test_affineScaleCheck Unit tests for the affine sanity check (T-BU-3a).
    %   Covers the SVD diagnostic added to the private helper
    %   src/+tfp/+calibration/private/fitAffineCalib.m: the two principal
    %   scales, their ratio (the anisotropy), the DMD-frame clocking angle, the
    %   camera-pixel units conversion, and the periscope-reversal diagnostic.
    %
    %   HOW THE PRIVATE HELPER IS REACHED. fitAffineCalib lives in a `private`
    %   folder, which MATLAB refuses to put on the path ("Private directories
    %   not allowed in MATLAB path"). The class fixture therefore copies the
    %   file into a scratch folder and puts THAT on the path, so the tests can
    %   call it directly and exercise its options. One end-to-end case
    %   (warningReachesAlignDMDtoCamera) goes through the real public caller
    %   instead, to prove the diagnostic actually surfaces on a calibration run.
    %
    %   Test list:
    %     legacyCallsUnchanged            — 2/3-arg calls and the rejected mask
    %     nominalDesignFitIsSilent        — a fit of the documented optics warns nothing
    %     expectedScalesAreCameraValued   — the units subtlety: ~0.72 / ~0.91
    %     umValuedGridIsFlagged           — forgetting to divide by the camera px
    %     reversedPeriscopeIsAmbiguous    — 1.778x: >1 hypothesis fits, no verdict
    %     reversedPeriscopeNamedWhenAlone — tight tolerance: named, still hedged
    %     anisotropyBlamesTheGrating      — wrong ratio, right scale
    %     ratioSurvivesPureMagnification  — the ratio's invariance, demonstrated
    %     clockingMeasuredInDmdFrame      — camera rotation must NOT trip it
    %     clockingDeviationWarns          — principal axis off the diagonals
    %     autoModeIgnoresNonDmdFits       — crossRegisterScanImage protection
    %     dmdModeChecksUnconditionally    — opt-in removes that blind spot
    %     offModeComputesNothing          — escape hatch
    %     summaryAlwaysAvailable          — report present even when silent
    %     cameraUmPerPixelIsHonoured      — option and config routes
    %     badOptionsRejected              — option validation
    %     warningReachesAlignDMDtoCamera  — end-to-end through the public caller

    properties (Constant)
        SCALE_ID = 'tfp:calibration:fitAffineCalib:suspiciousScale';
        ANISO_ID = 'tfp:calibration:fitAffineCalib:suspiciousAnisotropy';
        CLOCK_ID = 'tfp:calibration:fitAffineCalib:suspiciousClocking';
    end

    properties (Access = private)
        model_          % tfp.util.opticalModel design constants
        cameraUmPerPx_ = 1.56   % configs/real.yaml camera.umPerPixel
    end

    methods (TestClassSetup)

        function stagePrivateHelper(tc)
            %stagePrivateHelper Copy the private helper somewhere callable.
            import matlab.unittest.fixtures.PathFixture

            repo   = fileparts(fileparts(mfilename('fullpath')));
            srcDir = fullfile(repo, 'src');
            tc.applyFixture(PathFixture(srcDir));

            helper  = fullfile(srcDir, '+tfp', '+calibration', 'private', ...
                               'fitAffineCalib.m');
            tc.assertEqual(exist(helper, 'file'), 2, ...
                'fitAffineCalib.m not found where T-BU-3a expects it.');

            scratch = tempname();
            mkdir(scratch);
            tc.addTeardown(@() rmdir(scratch, 's'));
            copyfile(helper, scratch);
            tc.applyFixture(PathFixture(scratch));
            rehash();

            tc.model_ = tfp.util.opticalModel();
        end

    end

    methods (Test)

        % ---- backwards compatibility ------------------------------------

        function legacyCallsUnchanged(tc)
            %legacyCallsUnchanged Pre-existing outputs and call forms survive.
            %   T-BU-3a is additive: alignDMDtoCamera, calibrationGUI and
            %   crossRegisterScanImage all call the 3-arg form and read the
            %   original fields.
            A = tc.designCameraAffine();
            [dmdPts, camPts] = tc.gridFrom(A);

            twoArg   = fitAffineCalib(dmdPts, camPts);
            threeArg = fitAffineCalib(dmdPts, camPts, []);

            for f = {'dmdToSample_affine', 'residualErrorPx', 'nAccepted', ...
                     'residualsPerPt', 'dmdPtsAccepted', 'imgPtsAccepted', ...
                     'imgPtsPredicted'}
                tc.verifyTrue(isfield(twoArg, f{1}), ...
                    sprintf('Legacy field %s must still be returned.', f{1}));
                tc.verifyEqual(twoArg.(f{1}), threeArg.(f{1}), ...
                    'The 2-arg and 3-arg forms must agree.');
            end

            tc.verifyEqual(twoArg.dmdToSample_affine, A, 'AbsTol', 1e-9, ...
                'The fit must still recover the truth affine.');
            tc.verifyLessThan(twoArg.residualErrorPx, 1e-9);
            tc.verifyEqual(twoArg.nAccepted, size(dmdPts, 1));

            % Rejection mask still honoured, and still throws below 4 points.
            rejected = true(size(dmdPts, 1), 1);
            rejected([1 5 21 25]) = false;     % four non-collinear grid corners
            masked = fitAffineCalib(dmdPts, camPts, rejected);
            tc.verifyEqual(masked.nAccepted, 4);
            tc.verifyError(@() fitAffineCalib(dmdPts(1:3,:), camPts(1:3,:)), ...
                'tfp:calibration:fitAffineCalib:tooFewPoints');

            % And the new field is present, so callers can log it.
            tc.verifyTrue(isfield(twoArg, 'scaleCheck'));
        end

        % ---- the nominal case -------------------------------------------

        function nominalDesignFitIsSilent(tc)
            %nominalDesignFitIsSilent A fit of the documented optics warns nothing.
            A = tc.designCameraAffine();
            [dmdPts, camPts] = tc.gridFrom(A);

            calib = tc.verifyWarningFree(@() ...
                fitAffineCalib(dmdPts, camPts, [], struct('scaleCheck', 'dmd')));
            chk = calib.scaleCheck;

            tc.verifyTrue(chk.performed);
            tc.verifyEqual(chk.mode, 'dmd');
            tc.verifyTrue(chk.scaleOk && chk.anisotropyOk && chk.clockingOk);
            tc.verifyEmpty(chk.warningsIssued);
            tc.verifyEqual(chk.scaleRatio, 1, 'AbsTol', 1e-6);
            tc.verifyEqual(chk.anisotropy, tc.model_.anisotropy, 'AbsTol', 1e-6, ...
                'The singular-value ratio must recover the design anisotropy.');
            tc.verifyEqual(chk.clockingDeviationDeg, 0, 'AbsTol', 1e-6, ...
                'The stretched axis must land on a chip diagonal.');
            tc.verifyEqual(chk.principalAxisDmdDeg, tc.model_.clockingDeg, ...
                'AbsTol', 1e-6);
        end

        function expectedScalesAreCameraValued(tc)
            %expectedScalesAreCameraValued The units subtlety, pinned.
            %   fitAffineCalib fits DMD px -> substage CAMERA px, so the µm
            %   design scales must be divided by the camera pixel size before
            %   comparison: ~1.1250/1.56 = 0.72 and ~1.4162/1.56 = 0.91 camera
            %   px per DMD px. A units slip here would make the check the bug.
            A = tc.designCameraAffine();
            [dmdPts, camPts] = tc.gridFrom(A);
            calib = tc.quiet(@() fitAffineCalib(dmdPts, camPts, [], ...
                struct('scaleCheck', 'dmd')));
            chk = calib.scaleCheck;

            tc.verifyEqual(chk.cameraUmPerPixel, tc.cameraUmPerPx_, 'AbsTol', 1e-12);
            tc.verifyEqual(chk.expectedUmPerDmdPx, ...
                [tc.model_.umPerPixelDispersion, tc.model_.umPerPixelGroove], ...
                'AbsTol', 1e-12, 'Expectation in µm must come from opticalModel.');
            tc.verifyEqual(chk.expectedCamPxPerDmdPx, [0.9078, 0.7212], ...
                'AbsTol', 1e-3, ...
                'Expected camera-px scales must be the µm ones over 1.56.');
            tc.verifyEqual(chk.singularValuesCamPxPerDmdPx, [0.9078, 0.7212], ...
                'AbsTol', 1e-3);
            tc.verifyEqual(chk.singularValuesUmPerDmdPx, ...
                chk.singularValuesCamPxPerDmdPx * tc.cameraUmPerPx_, ...
                'AbsTol', 1e-12, 'The µm echo must be the camera-px pair times c.');
        end

        function umValuedGridIsFlagged(tc)
            %umValuedGridIsFlagged Measured points in µm instead of camera px.
            %   The scale then reads 1.56x high. The camera-units hypothesis
            %   must be among those that fit — and so must the periscope one,
            %   which is the ambiguity this whole diagnostic is careful about.
            A = tc.designCameraAffine(1, 1, 1);        % no camera-px division
            [dmdPts, camPts] = tc.gridFrom(A);
            opts = struct('scaleCheck', 'dmd');

            tc.verifyWarning(@() fitAffineCalib(dmdPts, camPts, [], opts), ...
                tc.SCALE_ID);
            calib = tc.quiet(@() fitAffineCalib(dmdPts, camPts, [], opts));
            chk   = calib.scaleCheck;

            tc.verifyEqual(chk.scaleRatio, tc.cameraUmPerPx_, 'RelTol', 1e-6);
            tc.verifyTrue(tc.hypothesisNear(chk, tc.cameraUmPerPx_).fits, ...
                'The camera-pixel hypothesis must fit a µm-valued grid.');
            tc.verifyTrue(tc.hypothesisNear(chk, ...
                tc.model_.periscopeReversalFactor).fits, ...
                ['The periscope hypothesis is only 14%% away and must also be ' ...
                 'marked — scale alone cannot separate them.']);
            tc.verifyTrue(chk.anisotropyOk, ...
                'A units error is isotropic: the ratio must be untouched.');
        end

        % ---- the periscope diagnostic and its ambiguity -------------------

        function reversedPeriscopeIsAmbiguous(tc)
            %reversedPeriscopeIsAmbiguous 1.778x must NOT be asserted as a cause.
            %   T-BU-2e: the camera-pixel factor (1.56) and the periscope
            %   reversal (1.778) are only ~14% apart, so at the default
            %   tolerance both fit and the message must say so rather than
            %   diagnose.
            f = tc.model_.periscopeReversalFactor;
            A = tc.designCameraAffine(f);
            [dmdPts, camPts] = tc.gridFrom(A);

            msg = tc.captureWarning(@() ...
                fitAffineCalib(dmdPts, camPts, [], struct('scaleCheck', 'dmd')));
            calib = tc.quiet(@() fitAffineCalib(dmdPts, camPts, [], ...
                struct('scaleCheck', 'dmd')));
            chk = calib.scaleCheck;

            tc.verifyEqual(chk.scaleRatio, f, 'RelTol', 1e-6);
            tc.verifyEqual(chk.residualErrorPx, calib.residualErrorPx, ...
                'The check reports the fit quality it is reasoning about.');
            tc.verifySubstring(msg, 'options.scaleTolerance below');
            tc.verifyGreaterThanOrEqual(chk.nHypothesesFitting, 2, ...
                ['At the default tolerance the periscope and camera-pixel ' ...
                 'hypotheses are indistinguishable; both must be marked.']);
            tc.verifyTrue(tc.hypothesisNear(chk, f).fits);
            tc.verifyTrue(tc.hypothesisNear(chk, tc.cameraUmPerPx_).fits);

            tc.verifySubstring(msg, 'MORE THAN ONE explanation fits');
            tc.verifySubstring(msg, 'does NOT');
            tc.verifySubstring(msg, 'T-BU-M1');
            % The ratio is intact, so the message must point at magnification.
            tc.verifySubstring(msg, 'points at MAGNIFICATION');
            tc.verifyEqual(chk.warningsIssued, {tc.SCALE_ID});
        end

        function reversedPeriscopeNamedWhenAlone(tc)
            %reversedPeriscopeNamedWhenAlone Named once it is the only fit — hedged.
            %   The two competing factors are 14% apart, so a tolerance tighter
            %   than that isolates the periscope. Even then the wording must
            %   stay a hypothesis, not a measurement.
            f = tc.model_.periscopeReversalFactor;
            A = tc.designCameraAffine(f);
            [dmdPts, camPts] = tc.gridFrom(A);
            opts = struct('scaleCheck', 'dmd', 'scaleTolerance', 1.08);

            msg = tc.captureWarning(@() fitAffineCalib(dmdPts, camPts, [], opts));
            chk = tc.quiet(@() fitAffineCalib(dmdPts, camPts, [], opts)).scaleCheck;

            tc.verifyEqual(chk.nHypothesesFitting, 1);
            tc.verifySubstring(msg, 'APPEARS TO BE INSTALLED REVERSED');
            tc.verifySubstring(msg, 'LEADING HYPOTHESIS TO CHECK');
            tc.verifySubstring(msg, 'not exhaustive');
            tc.verifyFalse(contains(msg, 'MORE THAN ONE explanation fits'));
        end

        % ---- the anisotropy ratio -----------------------------------------

        function anisotropyBlamesTheGrating(tc)
            %anisotropyBlamesTheGrating Wrong ratio, right scale -> grating.
            %   The ratio cannot be moved by any magnification, so the message
            %   must not offer one.
            A = tc.designCameraAffine(1, 1.35);   % stretch the ratio, keep area
            [dmdPts, camPts] = tc.gridFrom(A);

            msg = tc.captureWarning(@() ...
                fitAffineCalib(dmdPts, camPts, [], struct('scaleCheck', 'dmd')));
            chk = tc.quiet(@() fitAffineCalib(dmdPts, camPts, [], ...
                struct('scaleCheck', 'dmd'))).scaleCheck;

            tc.verifyTrue(chk.scaleOk, 'The area scale was deliberately preserved.');
            tc.verifyFalse(chk.anisotropyOk);
            tc.verifyEqual(chk.anisotropy, 1.35 * tc.model_.anisotropy, ...
                'RelTol', 1e-6);
            tc.verifyEqual(chk.warningsIssued, {tc.ANISO_ID});
            tc.verifySubstring(msg, 'robust discriminator');
            tc.verifySubstring(msg, 'grating');
            tc.verifySubstring(msg, 'invariant to every pure magnification');
        end

        function ratioSurvivesPureMagnification(tc)
            %ratioSurvivesPureMagnification Why the ratio is the better test.
            %   Every isotropic magnification error in the chain leaves the
            %   ratio untouched; this pins that claim numerically over a wide
            %   sweep, including the periscope factor itself.
            for m = [0.25, 1/tc.model_.periscopeReversalFactor, 1, ...
                     tc.cameraUmPerPx_, tc.model_.periscopeReversalFactor, 4]
                A = tc.designCameraAffine(m);
                [dmdPts, camPts] = tc.gridFrom(A);
                chk = tc.quiet(@() fitAffineCalib(dmdPts, camPts, [], ...
                    struct('scaleCheck', 'dmd'))).scaleCheck;
                tc.verifyEqual(chk.anisotropy, tc.model_.anisotropy, ...
                    'RelTol', 1e-6, sprintf( ...
                    'Magnification %.4gx must not move the anisotropy.', m));
                tc.verifyEqual(chk.scaleRatio, m, 'RelTol', 1e-6);
            end
        end

        % ---- clocking ------------------------------------------------------

        function clockingMeasuredInDmdFrame(tc)
            %clockingMeasuredInDmdFrame A rotated camera must not trip the check.
            %   The substage camera's mounting angle is arbitrary and no
            %   document pins it, so the clocking check reads the DMD-frame
            %   (right) singular vectors instead of the overall rotation.
            base = tc.designCameraAffine();
            [d0, c0] = tc.gridFrom(base);
            chk0 = tc.quiet(@() fitAffineCalib(d0, c0, [], ...
                struct('scaleCheck', 'dmd'))).scaleCheck;

            A = base;
            A(1:2,1:2) = tc.rot(31) * A(1:2,1:2);      % rotate the camera 31 deg
            [dmdPts, camPts] = tc.gridFrom(A);

            calib = tc.verifyWarningFree(@() ...
                fitAffineCalib(dmdPts, camPts, [], struct('scaleCheck', 'dmd')));
            chk = calib.scaleCheck;
            tc.verifyEqual(chk.clockingDeviationDeg, 0, 'AbsTol', 1e-6, ...
                'A rotated camera must not move the DMD-frame clocking.');
            tc.verifyEqual(chk.principalAxisDmdDeg, chk0.principalAxisDmdDeg, ...
                'AbsTol', 1e-6);
            wrapped = mod(chk.rotationDeg - chk0.rotationDeg - 31 + 180, 360) - 180;
            tc.verifyEqual(wrapped, 0, 'AbsTol', 1e-4, ...
                'The camera-frame rotation should still be reported, and move.');
        end

        function clockingDeviationWarns(tc)
            %clockingDeviationWarns Principal axis off the chip diagonals.
            A = tc.designCameraAffine();
            A(1:2,1:2) = A(1:2,1:2) * tc.rot(20);      % rotate in the DMD frame
            [dmdPts, camPts] = tc.gridFrom(A);

            msg = tc.captureWarning(@() ...
                fitAffineCalib(dmdPts, camPts, [], struct('scaleCheck', 'dmd')));
            chk = tc.quiet(@() fitAffineCalib(dmdPts, camPts, [], ...
                struct('scaleCheck', 'dmd'))).scaleCheck;

            tc.verifyEqual(chk.clockingDeviationDeg, 20, 'AbsTol', 1e-4);
            tc.verifyEqual(chk.warningsIssued, {tc.CLOCK_ID});
            tc.verifySubstring(msg, 'chip diagonal');
            tc.verifySubstring(msg, 'does NOT depend on how the substage');

            % Near-isotropic maps have ill-conditioned principal directions;
            % the check must decline to measure rather than invent an angle.
            iso = [0.81 0 100; 0 0.81 50; 0 0 1];
            [d2, c2] = tc.gridFrom(iso);
            chkIso = tc.quiet(@() fitAffineCalib(d2, c2, [], ...
                struct('scaleCheck', 'dmd'))).scaleCheck;
            tc.verifyTrue(isnan(chkIso.clockingDeviationDeg));
            tc.verifyTrue(chkIso.clockingOk);
        end

        % ---- modes ---------------------------------------------------------

        function autoModeIgnoresNonDmdFits(tc)
            %autoModeIgnoresNonDmdFits crossRegisterScanImage must stay quiet.
            %   That caller fits ScanImage scan-field px -> camera px with this
            %   same helper. Nothing about such a fit matches the DMD model, so
            %   the default mode must decline to comment.
            A = [2.05 0 300; 0 1.02 200; 0 0 1];     % scan-field-like, aniso 2.0
            [dmdPts, camPts] = tc.gridFrom(A);

            calib = tc.verifyWarningFree(@() fitAffineCalib(dmdPts, camPts, []));
            chk = calib.scaleCheck;
            tc.verifyTrue(chk.performed, ...
                'The numbers are still computed; only the warning is withheld.');
            tc.verifyEqual(chk.mode, 'auto');
            tc.verifyEmpty(chk.warningsIssued);
            tc.verifyNotEmpty(chk.skipReason);
            tc.verifySubstring(chk.skipReason, 'crossRegisterScanImage');

            % A recognisable DMD fit that is wrong in one respect DOES warn in
            % auto mode — the anisotropy is intact here, so it is recognised.
            B = tc.designCameraAffine(tc.model_.periscopeReversalFactor);
            [d2, c2] = tc.gridFrom(B);
            tc.verifyWarning(@() fitAffineCalib(d2, c2, []), tc.SCALE_ID);
        end

        function dmdModeChecksUnconditionally(tc)
            %dmdModeChecksUnconditionally The opt-in removes auto's blind spot.
            A = [2.05 0 300; 0 1.02 200; 0 0 1];
            [dmdPts, camPts] = tc.gridFrom(A);

            chk = tc.quiet(@() fitAffineCalib(dmdPts, camPts, [], ...
                struct('scaleCheck', 'dmd'))).scaleCheck;
            tc.verifyEmpty(chk.skipReason);
            tc.verifyTrue(ismember(tc.SCALE_ID, chk.warningsIssued));
            tc.verifyTrue(ismember(tc.ANISO_ID, chk.warningsIssued));
            tc.verifyWarning(@() fitAffineCalib(dmdPts, camPts, [], ...
                struct('scaleCheck', 'dmd')), {tc.SCALE_ID, tc.ANISO_ID});
        end

        function offModeComputesNothing(tc)
            %offModeComputesNothing Escape hatch for callers that know better.
            A = tc.designCameraAffine(5);
            [dmdPts, camPts] = tc.gridFrom(A);

            calib = tc.verifyWarningFree(@() fitAffineCalib(dmdPts, camPts, [], ...
                struct('scaleCheck', 'off')));
            tc.verifyFalse(calib.scaleCheck.performed);
            tc.verifyEmpty(calib.scaleCheck.warningsIssued);
            tc.verifyNotEmpty(calib.scaleCheck.skipReason);
            % The fit itself is unaffected.
            tc.verifyEqual(calib.dmdToSample_affine, A, 'AbsTol', 1e-9);
        end

        function summaryAlwaysAvailable(tc)
            %summaryAlwaysAvailable The report survives suppressed warnings.
            A = tc.designCameraAffine();
            [dmdPts, camPts] = tc.gridFrom(A);
            chk = tc.quiet(@() fitAffineCalib(dmdPts, camPts, [], ...
                struct('scaleCheck', 'dmd'))).scaleCheck;

            tc.verifyNotEmpty(chk.summary);
            tc.verifySubstring(chk.summary, 'candidate factors');
            tc.verifySubstring(chk.summary, 'camera px per DMD px');
            tc.verifySubstring(chk.summary, 'REPORTED ONLY');
            tc.verifyEqual(numel(chk.hypotheses), 5);
        end

        % ---- configuration --------------------------------------------------

        function cameraUmPerPixelIsHonoured(tc)
            %cameraUmPerPixelIsHonoured Both routes to the units bridge.
            c = 3.0;
            A = tc.designCameraAffine(1, 1, c);       % a fit at 3.0 µm/camera px

            [dmdPts, camPts] = tc.gridFrom(A);
            % Wrong camera pixel size -> the scale looks wrong.
            chkDefault = tc.quiet(@() fitAffineCalib(dmdPts, camPts, [], ...
                struct('scaleCheck', 'dmd'))).scaleCheck;
            tc.verifyEqual(chkDefault.scaleRatio, tc.cameraUmPerPx_ / c, ...
                'RelTol', 1e-6);
            tc.verifyFalse(chkDefault.scaleOk);

            % Told the truth via the option, it is silent.
            optsOpt = struct('scaleCheck', 'dmd', 'cameraUmPerPixel', c);
            chkOpt = tc.verifyWarningFree(@() ...
                fitAffineCalib(dmdPts, camPts, [], optsOpt)).scaleCheck;
            tc.verifyEqual(chkOpt.cameraUmPerPixel, c);
            tc.verifyEqual(chkOpt.scaleRatio, 1, 'AbsTol', 1e-6);

            % Same via a config struct (camera.umPerPixel), which is what a
            % loaded rig config looks like.
            cfg = struct('camera', struct('umPerPixel', c));
            chkCfg = tc.verifyWarningFree(@() fitAffineCalib(dmdPts, camPts, [], ...
                struct('scaleCheck', 'dmd', 'config', cfg))).scaleCheck;
            tc.verifyEqual(chkCfg.scaleRatio, 1, 'AbsTol', 1e-6);

            % A config that also moves the design constants moves the
            % expectation with it — the rig config wins over the document.
            cfg2 = struct('camera', struct('umPerPixel', tc.cameraUmPerPx_), ...
                'dmd', struct('umPerPixelGroove', tc.model_.umPerPixelGroove * 2, ...
                              'umPerPixelDispersion', tc.model_.umPerPixelDispersion * 2));
            B = tc.designCameraAffine(2);
            [d2, c2] = tc.gridFrom(B);
            chkCfg2 = tc.verifyWarningFree(@() fitAffineCalib(d2, c2, [], ...
                struct('scaleCheck', 'dmd', 'config', cfg2))).scaleCheck;
            tc.verifyEqual(chkCfg2.scaleRatio, 1, 'AbsTol', 1e-6);
        end

        function badOptionsRejected(tc)
            %badOptionsRejected Option validation, with the repo's error id.
            A = tc.designCameraAffine();
            [dmdPts, camPts] = tc.gridFrom(A);
            id = 'tfp:calibration:fitAffineCalib:badOption';

            bad = { ...
                struct('scaleCheck', 'sideways'), ...
                struct('scaleCheck', 7), ...
                struct('scaleTolerance', 0.9), ...
                struct('scaleTolerance', -1), ...
                struct('anisotropyTolerance', 0), ...
                struct('clockingToleranceDeg', -3), ...
                struct('cameraUmPerPixel', 0), ...
                struct('cameraUmPerPixel', [1 2]), ...
                struct('config', 5), ...
                struct('context', 3)};
            for k = 1:numel(bad)
                tc.verifyError(@() fitAffineCalib(dmdPts, camPts, [], bad{k}), id, ...
                    sprintf('Bad option case %d should have been rejected.', k));
            end
            tc.verifyError(@() fitAffineCalib(dmdPts, camPts, [], 'nope'), id);

            % A caller tag is prefixed to the warning so the operator knows
            % which calibration routine complained.
            [d2, c2] = tc.gridFrom(tc.designCameraAffine(1.05));
            msg = tc.captureWarning(@() fitAffineCalib(d2, c2, [], ...
                struct('scaleCheck', 'dmd', 'scaleTolerance', 1.001, ...
                       'anisotropyTolerance', 1, 'context', '[myCaller]')));
            tc.verifySubstring(msg, '[myCaller] fitAffineCalib:');
            tc.verifySubstring(msg, 'NONE of the listed factors fits');
        end

        % ---- end to end ------------------------------------------------------

        function warningReachesAlignDMDtoCamera(tc)
            %warningReachesAlignDMDtoCamera The diagnostic surfaces on a real run.
            %   alignDMDtoCamera calls the 3-arg form, so this exercises the
            %   default 'auto' mode against a mock rig whose truth affine has
            %   the design anisotropy and clocking but a periscope-reversed
            %   scale. That is the case T-BU-M1 is about.
            dmdCfg.nRows = 200;
            dmdCfg.nCols = 320;
            dmdCfg.loadLatencyMsPerPattern = 0;
            dmd = tfp.hardware.MockDMD();
            dmd.initialize(dmdCfg);

            truth = tc.designCameraAffine(tc.model_.periscopeReversalFactor);
            truth(1:2, 3) = [60; 150];

            camCfg = struct('nRows', 384, 'nCols', 512, 'dmd', dmd, ...
                'truthAffine', truth, 'noiseLevel', 0.02, 'spotSigmaPx', 4);
            cam = tfp.hardware.MockSubstageCamera();
            cam.initialize(camCfg);

            opts = struct('nGridPoints', 3, 'gridSpacing', 40, ...
                'exposureS', 0, 'showFigure', false);

            msg = tc.captureWarning(@() tfp.calibration.alignDMDtoCamera(dmd, cam, opts));
            tc.verifySubstring(msg, 'fitAffineCalib');
            tc.verifySubstring(msg, 'T-BU-M1');
            tc.verifySubstring(msg, 'MORE THAN ONE explanation fits');
        end

    end

    methods (Access = private)

        function A = designCameraAffine(tc, magnification, anisotropyGain, cameraUm)
            %designCameraAffine Truth affine: DMD px -> substage camera px.
            %   Built from tfp.util.opticalModel (never hardcoded), following
            %   handoff §5: the optical axes are the chip diagonals, the sample
            %   scales are µm per DMD px, and the camera pixel size converts
            %   them to camera px. `magnification` scales both axes (the
            %   periscope-style error), `anisotropyGain` stretches only the
            %   dispersion axis (the grating-style error).
            if nargin < 2 || isempty(magnification),  magnification  = 1;   end
            if nargin < 3 || isempty(anisotropyGain), anisotropyGain = 1;   end
            if nargin < 4 || isempty(cameraUm),       cameraUm = tc.cameraUmPerPx_; end

            % Keep the area scale fixed when only the ratio is being moved, so
            % the two failure modes stay independent in the tests.
            ppd = tc.model_.umPerPixelDispersion * magnification * sqrt(anisotropyGain);
            ppg = tc.model_.umPerPixelGroove     * magnification / sqrt(anisotropyGain);
            k   = 1 / sqrt(2);
            M   = [ppd * k,  ppd * k; ...
                   ppg * k, -ppg * k] / cameraUm;
            A = eye(3);
            A(1:2, 1:2) = M;
            A(1:2, 3)   = [400; 300];
        end

        function [dmdPts, camPts] = gridFrom(~, A)
            %gridFrom A noiseless 5x5 DMD grid and its image under A.
            [cc, rr] = meshgrid((-2:2) * 100 + 640, (-2:2) * 100 + 400);
            dmdPts   = [cc(:), rr(:)];
            hom      = A * [dmdPts, ones(size(dmdPts, 1), 1)]';
            camPts   = hom(1:2, :)';
        end

        function R = rot(~, deg)
            R = [cosd(deg), -sind(deg); sind(deg), cosd(deg)];
        end

        function out = quiet(tc, fcn)
            %quiet Run fcn with the diagnostic warnings off; return its output.
            %   The struct it returns records .warningsIssued regardless, so
            %   suppressing them costs no coverage.
            state   = warning();                       % full state, restored below
            cleanup = onCleanup(@() warning(state));
            warning('off', tc.SCALE_ID);
            warning('off', tc.ANISO_ID);
            warning('off', tc.CLOCK_ID);
            out = fcn();
        end

        function msg = captureWarning(~, fcn)
            %captureWarning Run fcn, return the warning text it emitted.
            %   evalc keeps the (deliberately long) warning out of the test
            %   log; lastwarn gives us the message itself. Same idiom as
            %   tests/test_sampleDmdMapping.m.
            lastwarn('');
            captured = evalc('fcn();'); %#ok<NASGU>
            msg = lastwarn();
        end

        function h = hypothesisNear(tc, chk, factor)
            %hypothesisNear The enumerated hypothesis with this predicted factor.
            idx = find(abs([chk.hypotheses.factor] - factor) < 1e-9, 1);
            tc.assertNotEmpty(idx, sprintf( ...
                'No hypothesis predicting %.4g is enumerated.', factor));
            h = chk.hypotheses(idx);
        end

    end
end
