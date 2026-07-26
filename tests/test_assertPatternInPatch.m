classdef test_assertPatternInPatch < matlab.unittest.TestCase
    %test_assertPatternInPatch Patch-containment guard (TASK-BU T-BU-1c).
    %
    %   docs/dmd_control_handoff.md §4: "Write nothing outside the patch —
    %   mirrors outside it must be OFF." These tests pin the two severity
    %   levels (design patch 278 px vs the 329 px hard clip limit), the fact
    %   that the radius is measured from the configured ILLUMINATION centroid
    %   rather than the array centre, and the content of the operator-facing
    %   error messages.

    methods (Test)

        % --- Passing cases ------------------------------------------------

        function centralSpotOnFullChipPasses(tc)
            % A soma-sized spot at the patch centre is the normal case.
            p = spot(800, 1280, 640, 400, 10);
            tc.verifyWarningFree(@() tfp.util.assertPatternInPatch(p));
        end

        function allOffPatternPasses(tc)
            p = false(800, 1280);
            info = tfp.util.assertPatternInPatch(p);
            tc.verifyEqual(info.worstRadiusPx, 0);
            tc.verifyEqual(info.worstPatternIdx, 0);
            tc.verifyEqual(info.nOverPatch, 0);
        end

        function pixelExactlyOnThePatchEdgePasses(tc)
            % Boundary inclusive, matching tfp.patterns.singleSpot's <= radius.
            m = tfp.util.opticalModel();
            p = false(800, 1280);
            p(m.patchCenterPx(2), m.patchCenterPx(1) + m.patchRadiusPx) = true;
            info = tfp.util.assertPatternInPatch(p);
            tc.verifyEqual(info.worstRadiusPx, m.patchRadiusPx, 'AbsTol', 1e-9);
            tc.verifyEqual(info.nOverPatch, 0);
        end

        function numericPatternIsReadAsNonzeroMeansOn(tc)
            p = double(spot(800, 1280, 640, 400, 10));
            tc.verifyWarningFree(@() tfp.util.assertPatternInPatch(p));
        end

        function acceptsAModelStructAsConfig(tc)
            % opticalModel's own output round-trips as a config.
            m = tfp.util.opticalModel();
            p = spot(800, 1280, 640, 400, 10);
            tc.verifyWarningFree(@() tfp.util.assertPatternInPatch(p, m));
        end

        function infoReportsTheWorstMirrorOnAPassingStack(tc)
            p = false(800, 1280, 3);
            p(:, :, 1) = spot(800, 1280, 640, 400, 5);
            p(:, :, 2) = spot(800, 1280, 700, 400, 5);   % worst: 65 px out
            p(:, :, 3) = spot(800, 1280, 650, 400, 5);
            info = tfp.util.assertPatternInPatch(p);
            tc.verifyEqual(info.nPatterns, 3);
            tc.verifyEqual(info.worstPatternIdx, 2);
            tc.verifyEqual(info.worstRadiusPx, 65, 'AbsTol', 1e-9);
            tc.verifyEqual(info.worstPixelColRow, [705 400]);
            tc.verifyEqual(info.patchRadiusPx, 278);
            tc.verifyEqual(info.patchMaxRadiusPx, 329);
            tc.verifyEqual(info.patchCenterPx, [640 400]);
        end

        % --- Severity level 1: outside the design patch --------------------

        function pixelJustOutsideTheDesignPatchThrows(tc)
            m = tfp.util.opticalModel();
            p = false(800, 1280);
            p(m.patchCenterPx(2), m.patchCenterPx(1) + m.patchRadiusPx + 1) = true;
            tc.verifyError(@() tfp.util.assertPatternInPatch(p), ...
                'tfp:util:assertPatternInPatch:outsidePatch');
        end

        function spotWhoseEdgeLeavesThePatchThrows(tc)
            % The centre is inside but the rim is not — the guard must test
            % every ON mirror, not just the target coordinate.
            m = tfp.util.opticalModel();
            p = spot(800, 1280, m.patchCenterPx(1) + m.patchRadiusPx - 3, ...
                     m.patchCenterPx(2), 10);
            tc.verifyError(@() tfp.util.assertPatternInPatch(p), ...
                'tfp:util:assertPatternInPatch:outsidePatch');
        end

        % --- Severity level 2: beyond the hard clip limit ------------------

        function pixelBeyondTheHardLimitGetsTheHarderIdentifier(tc)
            m = tfp.util.opticalModel();
            p = false(800, 1280);
            p(m.patchCenterPx(2), m.patchCenterPx(1) + m.patchMaxRadiusPx + 1) = true;
            tc.verifyError(@() tfp.util.assertPatternInPatch(p), ...
                'tfp:util:assertPatternInPatch:outsideHardLimit');
        end

        function pixelExactlyOnTheHardLimitIsOnlyASoftFailure(tc)
            % r == patchMaxRadiusPx does not yet clip La, but it is well
            % outside the design patch, so the softer identifier applies.
            m = tfp.util.opticalModel();
            p = false(800, 1280);
            p(m.patchCenterPx(2), m.patchCenterPx(1) + m.patchMaxRadiusPx) = true;
            tc.verifyError(@() tfp.util.assertPatternInPatch(p), ...
                'tfp:util:assertPatternInPatch:outsidePatch');
        end

        function hardLimitWinsWhenBothLevelsAreViolated(tc)
            m = tfp.util.opticalModel();
            p = false(800, 1280);
            p(m.patchCenterPx(2), m.patchCenterPx(1) + m.patchRadiusPx + 5) = true;
            p(m.patchCenterPx(2), m.patchCenterPx(1) + m.patchMaxRadiusPx + 5) = true;
            tc.verifyError(@() tfp.util.assertPatternInPatch(p), ...
                'tfp:util:assertPatternInPatch:outsideHardLimit');
        end

        % --- The centre is the illumination centroid, NOT the array centre --

        function radiusIsMeasuredFromTheConfiguredOffCentrePatch(tc)
            % 40 x 60 array: the array centre is ~(col 30, row 20). Put the
            % illumination centroid somewhere else entirely.
            cfg = struct('patchCenterPx', [20 15], 'patchRadiusPx', 5, ...
                'patchMaxRadiusPx', 30);

            atPatchCentre = false(40, 60);
            atPatchCentre(15, 20) = true;
            tc.verifyWarningFree( ...
                @() tfp.util.assertPatternInPatch(atPatchCentre, cfg));

            % A pixel at the ARRAY centre is 11.18 px from the patch centroid.
            atArrayCentre = false(40, 60);
            atArrayCentre(20, 30) = true;
            err = catchError(tc, @() tfp.util.assertPatternInPatch(atArrayCentre, cfg), ...
                'tfp:util:assertPatternInPatch:outsidePatch');
            tc.verifySubstring(err.message, '11.2 px');
            tc.verifySubstring(err.message, '(col=20, row=15)');
        end

        function offCentreRadiusIsExactUnderAWidePatch(tc)
            % Same off-centre geometry, thresholds wide enough to pass, so the
            % measured radius can be read straight out of info.
            cfg = struct('patchCenterPx', [20 15], 'patchRadiusPx', 200, ...
                'patchMaxRadiusPx', 200);
            p = false(40, 60);
            p(20, 30) = true;
            info = tfp.util.assertPatternInPatch(p, cfg);
            tc.verifyEqual(info.worstRadiusPx, hypot(10, 5), 'AbsTol', 1e-9, ...
                'Radius must be measured from patchCenterPx, not size(p)/2.');
            tc.verifyEqual(info.worstPixelColRow, [30 20]);
        end

        function offCentrePatchAlsoDrivesTheHardLimit(tc)
            cfg = struct('patchCenterPx', [20 15], 'patchRadiusPx', 5, ...
                'patchMaxRadiusPx', 8);
            p = false(40, 60);
            p(20, 30) = true;   % 11.18 px out: past both thresholds
            tc.verifyError(@() tfp.util.assertPatternInPatch(p, cfg), ...
                'tfp:util:assertPatternInPatch:outsideHardLimit');
        end

        % --- Stacks ---------------------------------------------------------

        function stackPassesWhenEverySliceIsContained(tc)
            p = false(800, 1280, 4);
            for n = 1:4
                p(:, :, n) = spot(800, 1280, 640 + 20 * n, 400, 8);
            end
            tc.verifyWarningFree(@() tfp.util.assertPatternInPatch(p));
        end

        function errorNamesTheOffendingSliceIndexAndWorstRadius(tc)
            m = tfp.util.opticalModel();
            p = false(800, 1280, 4);
            p(:, :, 1) = spot(800, 1280, 640, 400, 8);
            p(:, :, 2) = spot(800, 1280, 660, 400, 8);
            p(:, :, 4) = spot(800, 1280, 640, 400, 8);
            % Slice 3 is the sole offender, 298 px out.
            p(m.patchCenterPx(2), m.patchCenterPx(1) + m.patchRadiusPx + 20, 3) = true;

            err = catchError(tc, @() tfp.util.assertPatternInPatch(p), ...
                'tfp:util:assertPatternInPatch:outsidePatch');
            tc.verifySubstring(err.message, 'pattern 3 of 4');
            tc.verifySubstring(err.message, '298.0 px');
            tc.verifySubstring(err.message, '1 of 4 patterns offend');
        end

        function everyOffendingSliceIsCounted(tc)
            m = tfp.util.opticalModel();
            p = false(800, 1280, 3);
            p(:, :, 1) = spot(800, 1280, 640, 400, 8);          % clean
            p(m.patchCenterPx(2), m.patchCenterPx(1) + m.patchRadiusPx + 10, 2) = true;
            p(m.patchCenterPx(2), m.patchCenterPx(1) + m.patchRadiusPx + 20, 3) = true;

            err = catchError(tc, @() tfp.util.assertPatternInPatch(p), ...
                'tfp:util:assertPatternInPatch:outsidePatch');
            tc.verifySubstring(err.message, '2 of 3 patterns offend');
            tc.verifySubstring(err.message, 'pattern 3 of 3');
        end

        function hardLimitErrorCountsOnlyTheHardOffenders(tc)
            m = tfp.util.opticalModel();
            p = false(800, 1280, 3);
            p(m.patchCenterPx(2), m.patchCenterPx(1) + m.patchRadiusPx + 10, 1) = true;
            p(m.patchCenterPx(2), m.patchCenterPx(1) + m.patchMaxRadiusPx + 10, 2) = true;
            p(:, :, 3) = spot(800, 1280, 640, 400, 8);
            err = catchError(tc, @() tfp.util.assertPatternInPatch(p), ...
                'tfp:util:assertPatternInPatch:outsideHardLimit');
            tc.verifySubstring(err.message, '1 of 3 patterns exceed it');
            tc.verifySubstring(err.message, 'pattern 2 of 3');
        end

        % --- Error message content ------------------------------------------

        function messagesTellTheOperatorWhatToDo(tc)
            m = tfp.util.opticalModel();
            soft = false(800, 1280);
            soft(m.patchCenterPx(2), m.patchCenterPx(1) + m.patchRadiusPx + 1) = true;
            errSoft = catchError(tc, @() tfp.util.assertPatternInPatch(soft), ...
                'tfp:util:assertPatternInPatch:outsidePatch');
            tc.verifySubstring(errSoft.message, 'Re-pick a more central target');
            tc.verifySubstring(errSoft.message, 'unpredictable dose');
            tc.verifySubstring(errSoft.message, '6.00 mm dia');

            hard = false(800, 1280);
            hard(m.patchCenterPx(2), m.patchCenterPx(1) + m.patchMaxRadiusPx + 1) = true;
            errHard = catchError(tc, @() tfp.util.assertPatternInPatch(hard), ...
                'tfp:util:assertPatternInPatch:outsideHardLimit');
            tc.verifySubstring(errHard.message, 'lens La and the grating ruling');
            tc.verifySubstring(errHard.message, 'Re-pick a more central target');
            tc.verifySubstring(errHard.message, '7.11 mm dia');
        end

        function contextTagIsPrefixedToTheMessage(tc)
            m = tfp.util.opticalModel();
            p = false(800, 1280);
            p(m.patchCenterPx(2), m.patchCenterPx(1) + m.patchRadiusPx + 1) = true;
            err = catchError(tc, @() tfp.util.assertPatternInPatch(p, [], ...
                struct('context', 'MockDMD.loadPatternSequence')), ...
                'tfp:util:assertPatternInPatch:outsidePatch');
            tc.verifySubstring(err.message, '[MockDMD.loadPatternSequence]');
        end

        % --- Geometry comes from the config, not from hardcoded numbers -----

        function configPatchRadiusOverrideChangesTheVerdict(tc)
            p = spot(800, 1280, 640, 400, 40);
            tc.verifyWarningFree(@() tfp.util.assertPatternInPatch(p));
            tc.verifyError( ...
                @() tfp.util.assertPatternInPatch(p, struct('patchRadiusPx', 20)), ...
                'tfp:util:assertPatternInPatch:outsidePatch');
        end

        function legacyRoiHalfWidthPxAliasIsHonoured(tc)
            % Existing rig configs carry roiHalfWidthPx; opticalModel maps it.
            p = spot(800, 1280, 640, 400, 40);
            tc.verifyError( ...
                @() tfp.util.assertPatternInPatch(p, struct('roiHalfWidthPx', 20)), ...
                'tfp:util:assertPatternInPatch:outsidePatch');
        end

        function fullConfigWithDmdSubstructWorks(tc)
            cfg.dmd.patchRadiusPx = 20;
            p = spot(800, 1280, 640, 400, 40);
            tc.verifyError(@() tfp.util.assertPatternInPatch(p, cfg), ...
                'tfp:util:assertPatternInPatch:outsidePatch');
        end

        % --- The fast path must agree with brute force ----------------------

        function reportedRadiusMatchesBruteForceMeshgrid(tc)
            % Guards the separable dy2+dx2 lookup and the bounding-box skip
            % against a naive reference, on an off-centre patch.
            rng(7);
            p = rand(50, 70, 3) > 0.85;
            cfg = struct('patchCenterPx', [23 17], 'patchRadiusPx', 200, ...
                'patchMaxRadiusPx', 200);
            info = tfp.util.assertPatternInPatch(p, cfg);

            [cols, rows] = meshgrid(1:70, 1:50);
            r = hypot(cols - 23, rows - 17);
            expected    = 0;
            expectedIdx = 0;
            for n = 1:3
                v = max(r(p(:, :, n)));
                if ~isempty(v) && v > expected
                    expected    = v;
                    expectedIdx = n;
                end
            end
            tc.verifyEqual(info.worstRadiusPx, expected, 'AbsTol', 1e-9);
            tc.verifyEqual(info.worstPatternIdx, expectedIdx);
        end

        % --- Input validation -----------------------------------------------

        function malformedPatternIsRejected(tc)
            tc.verifyError(@() tfp.util.assertPatternInPatch('nope'), ...
                'tfp:util:assertPatternInPatch:badPattern');
            tc.verifyError(@() tfp.util.assertPatternInPatch([]), ...
                'tfp:util:assertPatternInPatch:badPattern');
            tc.verifyError(@() tfp.util.assertPatternInPatch(false(4, 4, 2, 2)), ...
                'tfp:util:assertPatternInPatch:badPattern');
        end

        function malformedOptionsAreRejected(tc)
            p = false(40, 60);
            tc.verifyError(@() tfp.util.assertPatternInPatch(p, [], 42), ...
                'tfp:util:assertPatternInPatch:badOptions');
            tc.verifyError( ...
                @() tfp.util.assertPatternInPatch(p, [], struct('context', 7)), ...
                'tfp:util:assertPatternInPatch:badOptions');
        end

        function badConfigPropagatesTheOpticalModelError(tc)
            % Config validation stays in the single source of truth.
            p = false(40, 60);
            tc.verifyError(@() tfp.util.assertPatternInPatch(p, 42), ...
                'tfp:util:opticalModel:badConfig');
        end

    end
end

% =========================================================================

function mask = spot(nRows, nCols, col, row, radiusPx)
%spot Local circular-mask helper (independent of tfp.patterns.singleSpot).
[cols, rows] = meshgrid(1:nCols, 1:nRows);
mask = (cols - col).^2 + (rows - row).^2 <= radiusPx^2;
end

function err = catchError(tc, fcn, expectedId)
%catchError Run fcn, require it to throw expectedId, return the exception.
%   Lets a test assert on the operator-facing message text as well as the id.
err = MException('tfp:test:noError', '(no error was thrown)');
try
    fcn();
catch ME
    err = ME;
end
tc.verifyEqual(err.identifier, expectedId);
end
