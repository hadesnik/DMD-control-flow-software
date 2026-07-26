classdef test_sampleDmdMapping < matlab.unittest.TestCase
    %test_sampleDmdMapping Anisotropic sample<->DMD offset mapping (TASK-BU T-BU-1a).
    %
    %   Pins tfp.patterns.sampleToDmdOffset / tfp.patterns.dmdToSampleOffset
    %   against §5 of docs/dmd_control_handoff.md. The chip is clocked 45
    %   degrees, so the optical axes are its diagonals, and the sample scale is
    %   anisotropic (1.4162 um/px dispersion vs 1.1250 um/px groove). The two
    %   properties the rest of the codebase leans on are tested explicitly:
    %   an exact round trip, and the circle -> 1.2588x ellipse relationship
    %   (with its inverse, the pre-compensated DMD ellipse that lands as a
    %   round sample spot).

    properties (Constant)
        % Design constants quoted by the handoff doc. Duplicated here on
        % purpose: the tests pin the document, the code reads
        % tfp.util.opticalModel.
        PPD   = 1.4162      % um per DMD px, dispersion axis
        PPG   = 1.1250      % um per DMD px, groove axis
        ANISO = 1.2588      % PPD / PPG

        % Units-guard constants (T-BU-2e), same convention: pinned here,
        % read from config/opticalModel by the code.
        CAM_UM_PER_PX = 1.56    % configs/real.yaml camera.umPerPixel
        PERISCOPE     = (200/150)^2  % 1.778, handoff §9 / T-BU-M1
        WARN_TOL      = sqrt(1.56)   % the guard's threshold, ~1.249
    end

    methods (Test)

        % --- Forward map: DMD px -> sample um ---------------------------

        function forwardMatchesHandoffFormula(tc)
            % d_disp = (dc+dr)/sqrt(2); d_groove = (dc-dr)/sqrt(2);
            % x = d_disp*PPD; y = d_groove*PPG.
            dmdPx = [1 0; 0 1; 3 -2; 0 0; -7 -11];
            dDisp   = (dmdPx(:,1) + dmdPx(:,2)) / sqrt(2);
            dGroove = (dmdPx(:,1) - dmdPx(:,2)) / sqrt(2);
            expected = [dDisp * tc.PPD, dGroove * tc.PPG];

            actual = tfp.patterns.dmdToSampleOffset(dmdPx);
            tc.verifyEqual(actual, expected, 'AbsTol', 1e-9);
        end

        function forwardUsesOpticalModelConstants(tc)
            % A one-pixel step along the (1,1) diagonal is one dispersion
            % pixel: PPD um along x and nothing along y.
            m = tfp.util.opticalModel();
            step = tfp.patterns.dmdToSampleOffset([1 1] / sqrt(2));
            tc.verifyEqual(step, [m.umPerPixelDispersion, 0], 'AbsTol', 1e-9);
            % ... and along (1,-1) it is one groove pixel.
            step = tfp.patterns.dmdToSampleOffset([1 -1] / sqrt(2));
            tc.verifyEqual(step, [0, m.umPerPixelGroove], 'AbsTol', 1e-9);
        end

        % --- Inverse map: sample um -> DMD px ----------------------------

        function inverseMatchesHandoffClosedForm(tc)
            % dc = (x/PPD + y/PPG)/sqrt(2); dr = (x/PPD - y/PPG)/sqrt(2).
            sampleUm = [1 0; 0 1; 12.7 -6.35; 0 0; -30 45];
            u = sampleUm(:,1) / tc.PPD;
            v = sampleUm(:,2) / tc.PPG;
            expected = [(u + v) / sqrt(2), (u - v) / sqrt(2)];

            actual = tfp.patterns.sampleToDmdOffset(sampleUm);
            tc.verifyEqual(actual, expected, 'AbsTol', 1e-9);
        end

        function inverseIsFourTimesTheOldScalarGuess(tc)
            % Sanity check on the bug this task fixes: the old isotropic
            % 0.270 um/px puts a 10 um step at ~37 px. The real map puts it at
            % ~7-9 px, i.e. ~4x fewer pixels.
            stepPx = tfp.patterns.sampleToDmdOffset([10 0]);
            tc.verifyLessThan(hypot(stepPx(1), stepPx(2)), 12);
            tc.verifyGreaterThan(hypot(stepPx(1), stepPx(2)), 6);
        end

        % --- Round trip --------------------------------------------------

        function roundTripSampleToDmdToSampleIsExact(tc)
            rng(20260726, 'twister');
            sampleUm = 200 * (rand(50, 2) - 0.5);
            back = tfp.patterns.dmdToSampleOffset( ...
                tfp.patterns.sampleToDmdOffset(sampleUm));
            % "Exact to floating point": residual is at round-off level, not
            % at a tolerance chosen to hide a modelling error.
            tc.verifyEqual(back, sampleUm, 'AbsTol', 1e-11, 'RelTol', 1e-12);
        end

        function roundTripDmdToSampleToDmdIsExact(tc)
            rng(20260726, 'twister');
            dmdPx = 300 * (rand(50, 2) - 0.5);
            back = tfp.patterns.sampleToDmdOffset( ...
                tfp.patterns.dmdToSampleOffset(dmdPx));
            tc.verifyEqual(back, dmdPx, 'AbsTol', 1e-11, 'RelTol', 1e-12);
        end

        function roundTripHoldsForAFittedAffineToo(tc)
            % An arbitrary (rotated, sheared, anisotropic) fitted linear part.
            A = [1.31 0.42; -0.87 0.96];
            dmdPx = [0 0; 5 -3; -11 7; 120 45];
            back = tfp.patterns.sampleToDmdOffset( ...
                tfp.patterns.dmdToSampleOffset(dmdPx, A), A);
            tc.verifyEqual(back, dmdPx, 'AbsTol', 1e-10, 'RelTol', 1e-11);
        end

        % --- Shape conventions (match multiSpot / ppsfPattern) -----------

        function shapesFollowNby2Convention(tc)
            tc.verifySize(tfp.patterns.dmdToSampleOffset([1 2]), [1 2]);
            tc.verifySize(tfp.patterns.sampleToDmdOffset([1 2]), [1 2]);
            tc.verifySize(tfp.patterns.dmdToSampleOffset(rand(7, 2)), [7 2]);
            tc.verifySize(tfp.patterns.sampleToDmdOffset(rand(7, 2)), [7 2]);
        end

        function emptyOffsetListRoundTripsAsEmpty(tc)
            % ppsfPattern-style callers can hand over a zero-row target list.
            tc.verifySize(tfp.patterns.sampleToDmdOffset(zeros(0, 2)), [0 2]);
            tc.verifySize(tfp.patterns.dmdToSampleOffset(zeros(0, 2)), [0 2]);
        end

        % --- mapSpec: design constants, model struct, config struct ------

        function modelStructAndDefaultsAgree(tc)
            m = tfp.util.opticalModel();
            dmdPx = [4 -9; 17 3];
            tc.verifyEqual(tfp.patterns.dmdToSampleOffset(dmdPx, m), ...
                tfp.patterns.dmdToSampleOffset(dmdPx), 'AbsTol', 1e-12);
            tc.verifyEqual(tfp.patterns.sampleToDmdOffset(dmdPx, m), ...
                tfp.patterns.sampleToDmdOffset(dmdPx), 'AbsTol', 1e-12);
        end

        function configStructScalesTheMap(tc)
            % A rig config whose fitted scales differ from design intent.
            cfg = struct('dmd', struct('umPerPixelDispersion', 2 * tc.PPD, ...
                                       'umPerPixelGroove',     2 * tc.PPG));
            dmdPx = [3 5];
            tc.verifyEqual(tfp.patterns.dmdToSampleOffset(dmdPx, cfg), ...
                2 * tfp.patterns.dmdToSampleOffset(dmdPx), 'AbsTol', 1e-9);
        end

        % --- mapSpec: a fitted affine wins over the design constants -----

        function fittedTwoByTwoOverridesDesignConstants(tc)
            A = [2 0; 0 3];    % DMD px -> sample um, no clocking
            tc.verifyEqual(tfp.patterns.dmdToSampleOffset([1 0], A), [2 0], ...
                'AbsTol', 1e-12);
            tc.verifyEqual(tfp.patterns.dmdToSampleOffset([0 1], A), [0 3], ...
                'AbsTol', 1e-12);
            tc.verifyEqual(tfp.patterns.sampleToDmdOffset([2 3], A), [1 1], ...
                'AbsTol', 1e-12);
        end

        function fittedThreeByThreeIgnoresTranslation(tc)
            % These are OFFSETS, so the affine's translation must drop out.
            A2 = [2 0; 0 3];
            A3 = [A2, [500; -400]; 0 0 1];
            dmdPx = [7 -2];
            tc.verifyEqual(tfp.patterns.dmdToSampleOffset(dmdPx, A3), ...
                tfp.patterns.dmdToSampleOffset(dmdPx, A2), 'AbsTol', 1e-12);
            sampleUm = [14 -6];
            tc.verifyEqual(tfp.patterns.sampleToDmdOffset(sampleUm, A3), ...
                tfp.patterns.sampleToDmdOffset(sampleUm, A2), 'AbsTol', 1e-12);
        end

        function calibrationStructFieldIsHonoured(tc)
            % Post-calibration call site: same code, struct instead of matrix.
            calib = struct('dmdToSampleLinear', [2 0; 0 3]);
            tc.verifyEqual(tfp.patterns.dmdToSampleOffset([1 1], calib), ...
                [2 3], 'AbsTol', 1e-12);
            tc.verifyEqual(tfp.patterns.sampleToDmdOffset([2 3], calib), ...
                [1 1], 'AbsTol', 1e-12);
        end

        % --- dispersionAxisSign (%VERIFY on the bench) -------------------

        function dispersionSignFlipsOnlyTheDispersionComponent(tc)
            cfgPlus  = struct('dmd', struct('dispersionAxisSign',  1));
            cfgMinus = struct('dmd', struct('dispersionAxisSign', -1));
            dmdPx = [6 -13];

            plus  = tfp.patterns.dmdToSampleOffset(dmdPx, cfgPlus);
            minus = tfp.patterns.dmdToSampleOffset(dmdPx, cfgMinus);
            tc.verifyEqual(minus, [-plus(1), plus(2)], 'AbsTol', 1e-12, ...
                'Only the dispersion axis carries the unresolved sign.');

            % Default is +1 (documented %VERIFY default).
            tc.verifyEqual(tfp.patterns.dmdToSampleOffset(dmdPx), plus, ...
                'AbsTol', 1e-12);

            % ... and the inverse follows, so the round trip still closes.
            back = tfp.patterns.sampleToDmdOffset(minus, cfgMinus);
            tc.verifyEqual(back, dmdPx, 'AbsTol', 1e-11);
        end

        % --- THE property the rest of the codebase depends on ------------

        function circleInDmdPixelsIsAnEllipseAtTheSample(tc)
            % A circle drawn in DMD pixels lands elongated 1.2588x along the
            % dispersion axis (handoff §5, and the reason T-BU-1b exists).
            R = 20;
            theta = linspace(0, 2*pi, 721)';
            dmdCircle = R * [cos(theta), sin(theta)];
            s = tfp.patterns.dmdToSampleOffset(dmdCircle);

            % Semi-axes: dispersion along sample x, groove along sample y.
            aDisp   = max(abs(s(:,1)));
            bGroove = max(abs(s(:,2)));
            tc.verifyEqual(aDisp,   R * tc.PPD, 'RelTol', 1e-9);
            tc.verifyEqual(bGroove, R * tc.PPG, 'RelTol', 1e-9);
            tc.verifyEqual(aDisp / bGroove, tc.ANISO, 'AbsTol', 1e-3, ...
                'Sample spot must be 1.2588x longer along the dispersion axis.');

            % Every mapped point lies on that ellipse (not merely its extremes).
            residual = (s(:,1) / aDisp).^2 + (s(:,2) / bGroove).^2 - 1;
            tc.verifyLessThan(max(abs(residual)), 1e-12);

            % It is NOT round: a 20 px circle is 8.5 um wider one way.
            tc.verifyGreaterThan(2 * (aDisp - bGroove), 8);
        end

        function roundSampleSpotPreCompensatesToADmdEllipse(tc)
            % The inverse: ask for a round spot at the sample and you get an
            % ellipse on the DMD, compressed by 1.2588x along the (1,1)
            % diagonal (the dispersion axis).
            Rum = 6.35;                 % 12.7 um soma-sized spot
            phi = linspace(0, 2*pi, 721)';
            sampleCircle = Rum * [cos(phi), sin(phi)];
            d = tfp.patterns.sampleToDmdOffset(sampleCircle);

            % Project the DMD ellipse onto the chip diagonals.
            dDisp   = (d(:,1) + d(:,2)) / sqrt(2);
            dGroove = (d(:,1) - d(:,2)) / sqrt(2);
            semiDisp   = max(abs(dDisp));
            semiGroove = max(abs(dGroove));

            tc.verifyEqual(semiDisp,   Rum / tc.PPD, 'RelTol', 1e-9);
            tc.verifyEqual(semiGroove, Rum / tc.PPG, 'RelTol', 1e-9);
            tc.verifyEqual(semiGroove / semiDisp, tc.ANISO, 'AbsTol', 1e-3, ...
                'DMD ellipse must be compressed 1.2588x along the (1,1) diagonal.');

            % The TASKS.md soma table: 12.7 um -> 5.7 x 4.5 px semi-axes.
            tc.verifyEqual(semiGroove, 5.7, 'AbsTol', 0.1);
            tc.verifyEqual(semiDisp,   4.5, 'AbsTol', 0.1);

            % And it maps back to a genuinely ROUND sample spot.
            back = tfp.patterns.dmdToSampleOffset(d);
            tc.verifyEqual(hypot(back(:,1), back(:,2)), ...
                repmat(Rum, size(back, 1), 1), 'AbsTol', 1e-11);
        end

        % --- Errors ------------------------------------------------------

        function badOffsetShapeErrors(tc)
            tc.verifyError(@() tfp.patterns.sampleToDmdOffset(zeros(3, 3)), ...
                'tfp:patterns:sampleToDmdOffset:badOffsets');
            tc.verifyError(@() tfp.patterns.dmdToSampleOffset(zeros(2, 2, 2)), ...
                'tfp:patterns:dmdToSampleOffset:badOffsets');
            tc.verifyError(@() tfp.patterns.dmdToSampleOffset('nope'), ...
                'tfp:patterns:dmdToSampleOffset:badOffsets');
        end

        function nonFiniteOffsetErrors(tc)
            tc.verifyError(@() tfp.patterns.sampleToDmdOffset([1 NaN]), ...
                'tfp:patterns:sampleToDmdOffset:badOffsets');
            tc.verifyError(@() tfp.patterns.dmdToSampleOffset([Inf 0]), ...
                'tfp:patterns:dmdToSampleOffset:badOffsets');
        end

        function badMapSpecErrors(tc)
            tc.verifyError(@() tfp.patterns.dmdToSampleOffset([1 0], ones(2, 3)), ...
                'tfp:patterns:dmdToSampleOffset:badMap');
            tc.verifyError(@() tfp.patterns.sampleToDmdOffset([1 0], {1}), ...
                'tfp:patterns:sampleToDmdOffset:badMap');
        end

        function singularFittedMapErrors(tc)
            % A degenerate fit collapses the plane onto a line; catching it
            % here beats returning Inf pixel coordinates to the DMD.
            tc.verifyError(@() tfp.patterns.sampleToDmdOffset([1 0], [1 1; 1 1]), ...
                'tfp:patterns:sampleToDmdOffset:singularMap');
            tc.verifyError(@() tfp.patterns.dmdToSampleOffset([1 0], zeros(2)), ...
                'tfp:patterns:dmdToSampleOffset:singularMap');
        end

        function badConfigPropagatesOpticalModelError(tc)
            % Validation stays in the single source of truth.
            cfg = struct('dmd', struct('dispersionAxisSign', 0));
            tc.verifyError(@() tfp.patterns.dmdToSampleOffset([1 0], cfg), ...
                'tfp:util:opticalModel:badSign');
        end

        % =================================================================
        % Units guard (T-BU-2e). calibration.dmdToSample_affine maps DMD px
        % -> substage CAMERA px despite its name, so a caller can hand a
        % camera-valued matrix to these um-valued functions and mis-place
        % every target by ~1/1.56 per axis with no other symptom. Layer 1 is
        % an explicit units tag (authoritative); layer 2 is a plausibility
        % check on the map's overall scale, which only ever warns.
        % =================================================================

        % --- Layer 1: the explicit tag -----------------------------------

        function cameraTaggedMapErrorsInBothDirections(tc)
            A = tc.designMap() / tc.CAM_UM_PER_PX;   % the actual hazard
            tc.verifyError(@() tfp.patterns.sampleToDmdOffset([10 0], A, ...
                'mapUnits', 'camera_px'), ...
                'tfp:patterns:sampleToDmdOffset:wrongUnits');
            tc.verifyError(@() tfp.patterns.dmdToSampleOffset([10 0], A, ...
                'mapUnits', 'camera_px'), ...
                'tfp:patterns:dmdToSampleOffset:wrongUnits');
        end

        function cameraTagSpellingsAreAccepted(tc)
            A = tc.designMap() / tc.CAM_UM_PER_PX;
            for spelling = {'camera_px', 'cameraPx', 'CAMERA', 'cam_px'}
                tc.verifyError(@() tfp.patterns.dmdToSampleOffset([1 0], A, ...
                    'mapUnits', spelling{1}), ...
                    'tfp:patterns:dmdToSampleOffset:wrongUnits', ...
                    sprintf('Spelling "%s" must be recognised.', spelling{1}));
            end
        end

        function cameraTagOnTheStructIsHonoured(tc)
            % Most realistic route: the tag travels with the saved matrix.
            A = tc.designMap() / tc.CAM_UM_PER_PX;
            viaMapUnits = struct('dmdToSampleLinear', A, 'mapUnits', 'camera_px');
            viaUnits    = struct('dmdToSampleLinear', A, 'units',    'camera_px');
            tc.verifyError(@() tfp.patterns.dmdToSampleOffset([1 0], viaMapUnits), ...
                'tfp:patterns:dmdToSampleOffset:wrongUnits');
            tc.verifyError(@() tfp.patterns.sampleToDmdOffset([1 0], viaUnits), ...
                'tfp:patterns:sampleToDmdOffset:wrongUnits');
        end

        function cameraTagWithoutAFittedMapStillErrors(tc)
            % Tagging camera units while relying on the design constants is
            % incoherent; say so rather than quietly using the design map.
            tc.verifyError(@() tfp.patterns.dmdToSampleOffset([1 0], [], ...
                'mapUnits', 'camera_px'), ...
                'tfp:patterns:dmdToSampleOffset:wrongUnits');
        end

        function wrongUnitsMessageSaysHowToConvert(tc)
            % NB: verifyError's outputs are the OUTPUTS OF THE CALLED FUNCTION,
            % not the caught MException — a function that throws yields
            % `missing`, so `err.message` on it is an error, not a failure.
            % Catch explicitly when the message text itself is under test.
            A = tc.designMap() / tc.CAM_UM_PER_PX;
            caught = MException.empty;
            try
                tfp.patterns.sampleToDmdOffset([1 0], A, 'mapUnits', 'camera_px');
            catch err
                caught = err;
            end
            tc.assertNotEmpty(caught, ...
                'A camera-valued map tagged camera_px must be rejected.');
            tc.verifyEqual(caught.identifier, ...
                'tfp:patterns:sampleToDmdOffset:wrongUnits');
            % The message must tell the operator how to recover, not just say no.
            tc.verifySubstring(caught.message, 'camera.umPerPixel');
            tc.verifySubstring(caught.message, 'dmdToSample_affine');
        end

        function umTagIsTrustedAndSilencesTheBackstop(tc)
            % An explicit tag is the caller's assertion, and the sanctioned
            % way to silence the plausibility warning. The VALUE must be
            % identical to the same call without the tag.
            A = tc.designMap() / tc.CAM_UM_PER_PX;
            got = tc.verifyWarningFree(@() ...
                tfp.patterns.dmdToSampleOffset([3 -4], A, 'mapUnits', 'um'));
            tc.verifyEqual(got, (A * [3; -4])', 'AbsTol', 1e-12);

            got = tc.verifyWarningFree(@() ...
                tfp.patterns.sampleToDmdOffset([3 -4], A, 'mapUnits', 'sample_um'));
            tc.verifyEqual(got, (A \ [3; -4])', 'AbsTol', 1e-12);
        end

        function optionsMayArriveAsAStruct(tc)
            A = tc.designMap() / tc.CAM_UM_PER_PX;
            tc.verifyWarningFree(@() tfp.patterns.dmdToSampleOffset([1 0], A, ...
                struct('mapUnits', 'um')));
            tc.verifyError(@() tfp.patterns.dmdToSampleOffset([1 0], A, ...
                struct('mapUnits', 'camera_px')), ...
                'tfp:patterns:dmdToSampleOffset:wrongUnits');
        end

        function badUnitsTagErrors(tc)
            tc.verifyError(@() tfp.patterns.dmdToSampleOffset([1 0], [], ...
                'mapUnits', 'furlongs'), ...
                'tfp:patterns:dmdToSampleOffset:badUnits');
            tc.verifyError(@() tfp.patterns.sampleToDmdOffset([1 0], [], ...
                'mapUnits', 42), ...
                'tfp:patterns:sampleToDmdOffset:badUnits');
        end

        function badOptionErrors(tc)
            tc.verifyError(@() tfp.patterns.dmdToSampleOffset([1 0], [], ...
                'nosuchoption', 1), 'tfp:patterns:dmdToSampleOffset:badOption');
            tc.verifyError(@() tfp.patterns.dmdToSampleOffset([1 0], [], ...
                'mapUnits'), 'tfp:patterns:dmdToSampleOffset:badOption');
            tc.verifyError(@() tfp.patterns.sampleToDmdOffset([1 0], [], ...
                'cameraUmPerPixel', -1), ...
                'tfp:patterns:sampleToDmdOffset:badOption');
            tc.verifyError(@() tfp.patterns.sampleToDmdOffset([1 0], [], ...
                7, 'um'), 'tfp:patterns:sampleToDmdOffset:badOption');
        end

        % --- Layer 2: the untagged plausibility backstop ------------------

        function untaggedCameraValuedMapWarns(tc)
            % The whole point: no tag, no error, but a loud warning instead
            % of silently scaling every target by 1/1.56 per axis.
            A = tc.designMap() / tc.CAM_UM_PER_PX;
            tc.verifyWarning(@() tfp.patterns.dmdToSampleOffset([1 0], A), ...
                'tfp:patterns:dmdToSampleOffset:suspiciousMapScale');
            tc.verifyWarning(@() tfp.patterns.sampleToDmdOffset([1 0], A), ...
                'tfp:patterns:sampleToDmdOffset:suspiciousMapScale');
            % ... and through the struct form, which is how a saved
            % calibration would arrive.
            tc.verifyWarning(@() tfp.patterns.dmdToSampleOffset([1 0], ...
                struct('dmdToSampleLinear', A)), ...
                'tfp:patterns:dmdToSampleOffset:suspiciousMapScale');
        end

        function cameraCaseReportsBothHypothesesAndDoesNotPickOne(tc)
            % THE honesty test. 1/1.56 = 0.641 (camera pixel) and 1/1.778 =
            % 0.563 (reversed periscope) are 14% apart, so a scale-only
            % observation cannot choose between them. The message must name
            % both, mark both as fitting, and explicitly decline to diagnose.
            A = tc.designMap() / tc.CAM_UM_PER_PX;
            msg = tc.captureWarning(@() tfp.patterns.dmdToSampleOffset([1 0], A));

            tc.verifySubstring(msg, '0.641');            % the observed ratio
            tc.verifySubstring(msg, 'CAMERA-valued');
            tc.verifySubstring(msg, 'periscope');
            tc.verifySubstring(msg, 'MORE THAN ONE');
            tc.verifySubstring(msg, 'does not claim the map is camera-valued');
            % Both candidates are marked, not just the camera one.
            tc.verifyEqual(numel(strfind(msg, '<== FITS')), 2, ...
                'Camera and reversed-periscope hypotheses must both be flagged.');
        end

        function periscopeSizedMismatchIsNotCalledACameraMap(tc)
            % A map 1.778x the design scale is the periscope hypothesis, and
            % the camera hypothesis must NOT be marked as fitting.
            A = tc.designMap() * tc.PERISCOPE;
            msg = tc.captureWarning(@() tfp.patterns.sampleToDmdOffset([1 0], A));
            tc.verifyEqual(numel(strfind(msg, '<== FITS')), 1);
            tc.verifySubstring(msg, 'Only one listed explanation fits');
            tc.verifySubstring(msg, 'lead, not a diagnosis');
        end

        function wildlyWrongScaleSaysNothingFits(tc)
            A = tc.designMap() * 20;
            msg = tc.captureWarning(@() tfp.patterns.dmdToSampleOffset([1 0], A));
            tc.verifySubstring(msg, 'NONE of the listed explanations fits');
            tc.verifyEmpty(strfind(msg, '<== FITS')); %#ok<STRIFCND>
        end

        function honestFitsStayQuiet(tc)
            % Handoff §9 expects a fitted affine to differ from design by a
            % few percent, and to carry rotation/shear. None of that may trip
            % the guard, or the warning becomes noise and gets ignored.
            th = deg2rad(7);
            R  = [cos(th) -sin(th); sin(th) cos(th)];
            tc.verifyWarningFree(@() ...
                tfp.patterns.dmdToSampleOffset([1 0], 1.05 * R * tc.designMap()));
            tc.verifyWarningFree(@() ...
                tfp.patterns.sampleToDmdOffset([1 0], 0.96 * tc.designMap()));
            % The arbitrary fitted affine used by the round-trip test above
            % is also within the band, so that test stays warning-free.
            tc.verifyWarningFree(@() ...
                tfp.patterns.dmdToSampleOffset([1 0], [1.31 0.42; -0.87 0.96]));
        end

        function thresholdIsTheGeometricMidpointToTheCameraHypothesis(tc)
            % Pins the chosen threshold: sqrt(1.56) ~ 1.249, i.e. the point
            % at which the camera hypothesis becomes as good an explanation
            % as the design one. Just inside is quiet, just outside warns.
            inside  = tc.designMap() * tc.WARN_TOL * 0.99;
            outside = tc.designMap() * tc.WARN_TOL * 1.01;
            tc.verifyWarningFree(@() tfp.patterns.dmdToSampleOffset([1 0], inside));
            tc.verifyWarning(@() tfp.patterns.dmdToSampleOffset([1 0], outside), ...
                'tfp:patterns:dmdToSampleOffset:suspiciousMapScale');
            % Symmetric on the small side (this is the camera direction).
            tc.verifyWarningFree(@() ...
                tfp.patterns.dmdToSampleOffset([1 0], tc.designMap() / tc.WARN_TOL * 1.01));
        end

        function cameraPixelSizeComesFromTheCallerNotAConstant(tc)
            % A rig with a different camera pixel must move the hypothesis.
            % Both routes: the option and the caller's own config.
            A = tc.designMap() / 3;
            msg = tc.captureWarning(@() tfp.patterns.dmdToSampleOffset([1 0], A, ...
                'cameraUmPerPixel', 3));
            tc.verifySubstring(msg, '3 um camera pixel');

            cfg = struct('dmdToSampleLinear', A, 'camera', struct('umPerPixel', 3));
            msg = tc.captureWarning(@() tfp.patterns.dmdToSampleOffset([1 0], cfg));
            tc.verifySubstring(msg, '3 um camera pixel');
        end

        function expectedScalesFollowTheCallersConfig(tc)
            % A rig whose config states 2x design scales must not be warned
            % about a fitted map that agrees with its own config.
            cfg = struct('dmd', struct('umPerPixelDispersion', 2 * tc.PPD, ...
                                       'umPerPixelGroove',     2 * tc.PPG), ...
                         'dmdToSampleLinear', 2 * tc.designMap());
            tc.verifyWarningFree(@() tfp.patterns.dmdToSampleOffset([1 0], cfg));
        end

        % --- The guard must not disturb the existing contract ------------

        function designPathsNeverWarn(tc)
            % [] / model struct / config struct are um-valued by construction.
            m   = tfp.util.opticalModel();
            cfg = struct('dmd', struct('umPerPixelDispersion', 5 * tc.PPD, ...
                                       'umPerPixelGroove',     5 * tc.PPG));
            tc.verifyWarningFree(@() tfp.patterns.dmdToSampleOffset([1 0]));
            tc.verifyWarningFree(@() tfp.patterns.dmdToSampleOffset([1 0], m));
            tc.verifyWarningFree(@() tfp.patterns.sampleToDmdOffset([1 0], m));
            tc.verifyWarningFree(@() tfp.patterns.dmdToSampleOffset([1 0], cfg));
        end

        function warningDoesNotChangeTheResult(tc)
            % A diagnostic must never alter the arithmetic.
            A  = tc.designMap() / tc.CAM_UM_PER_PX;
            id = 'tfp:patterns:dmdToSampleOffset:suspiciousMapScale';
            st = warning('off', id);
            restore = onCleanup(@() warning(st));
            px = [7 -3; 0 11];
            tc.verifyEqual(tfp.patterns.dmdToSampleOffset(px, A), (A * px')', ...
                'AbsTol', 1e-12);
            tc.verifyEqual(tfp.patterns.dmdToSampleOffset(px, A, 'mapUnits', 'um'), ...
                (A * px')', 'AbsTol', 1e-12);
        end

        function roundTripStillExactWithATaggedMap(tc)
            A = tc.designMap() / tc.CAM_UM_PER_PX;
            dmdPx = [0 0; 5 -3; -11 7; 120 45];
            back = tfp.patterns.sampleToDmdOffset( ...
                tfp.patterns.dmdToSampleOffset(dmdPx, A, 'mapUnits', 'um'), ...
                A, 'mapUnits', 'um');
            tc.verifyEqual(back, dmdPx, 'AbsTol', 1e-10, 'RelTol', 1e-11);
        end

        function sharedHelperBlockIsIdenticalInBothFiles(tc)
            % The two files carry a deliberately duplicated helper block. If
            % it drifts, the two directions of the map stop agreeing about
            % what a legal input is — catch that here rather than on the rig.
            fwd = tc.sharedHelperBlock('tfp.patterns.dmdToSampleOffset');
            inv = tc.sharedHelperBlock('tfp.patterns.sampleToDmdOffset');
            tc.verifyNotEmpty(fwd);
            tc.verifyEqual(inv, fwd, ...
                ['The duplicated helper block in sampleToDmdOffset.m and ' ...
                 'dmdToSampleOffset.m has drifted; re-sync it.']);
        end

    end

    methods (Access = private)

        function M = designMap(tc)
            %designMap The design DMD px -> sample um linear map (handoff §5).
            %   Singular values are exactly PPD and PPG, which is what the
            %   plausibility guard compares against.
            k = 1 / sqrt(2);
            M = [tc.PPD * k,  tc.PPD * k; ...
                 tc.PPG * k, -tc.PPG * k];
        end

        function msg = captureWarning(~, fcn)
            %captureWarning Run fcn, return the warning text it emitted.
            %   evalc keeps the (deliberately long) warning out of the test
            %   log; lastwarn gives us the message itself.
            lastwarn('');
            captured = evalc('fcn();'); %#ok<NASGU>
            msg = lastwarn();
        end

        function block = sharedHelperBlock(~, funcName)
            %sharedHelperBlock Text of a file from its duplication banner on.
            txt = fileread(which(funcName));
            marker = strfind(txt, '% =========');
            block = txt(marker(1):end);
        end

    end
end
