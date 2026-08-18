classdef test_assertPatternInPatch < matlab.unittest.TestCase
    %test_assertPatternInPatch The illuminated-patch containment rule.
    %   docs/optics_handoff.md §4: "write nothing outside the patch — mirrors
    %   outside it must be OFF". Every buildability gate (lens apertures,
    %   grating ruling, SLM fill) was checked AT the design patch diameter and
    %   nothing larger is verified, so a mirror outside the patch throws light
    %   into field angles the train was never analysed for. These tests pin
    %   the predicate and the two severities it is used at: hard error when
    %   called directly, warning on the DMD load path (which must stay
    %   permissive, because measuring the real footprint requires exceeding
    %   the design edge).

    properties (Constant)
        W = 1280
        H = 800
    end

    methods (Access = private)
        function m = discAt(testCase, cx, cy, r)
            %discAt Filled disc of radius r centred on (cx, cy).
            [X, Y] = meshgrid(1:testCase.W, 1:testCase.H);
            m = hypot(X - cx, Y - cy) <= r;
        end
        function o = opts(~, varargin)
            o = struct('patchDiameterPx', 400, varargin{:});
        end
    end

    methods (Test)

        function a_pattern_inside_the_patch_passes(testCase)
            % r = 50 well inside the 200 px patch radius.
            m = testCase.discAt((testCase.W+1)/2, (testCase.H+1)/2, 50);
            info = tfp.util.assertPatternInPatch(m, testCase.opts());
            testCase.verifyEqual(info.nOutside, 0);
            testCase.verifyEqual(info.patchRadiusPx, 200);
        end

        function a_pattern_crossing_the_edge_throws(testCase)
            % r = 250 against a 200 px patch radius: an annulus lies outside.
            m = testCase.discAt((testCase.W+1)/2, (testCase.H+1)/2, 250);
            testCase.verifyError( ...
                @() tfp.util.assertPatternInPatch(m, testCase.opts()), ...
                'tfp:util:assertPatternInPatch:outsidePatch');
        end

        function warn_mode_warns_and_still_returns_info(testCase)
            % The DMD load path uses this: visible, but not blocking.
            m = testCase.discAt((testCase.W+1)/2, (testCase.H+1)/2, 250);
            o = testCase.opts('mode', 'warn');
            testCase.verifyWarning( ...
                @() tfp.util.assertPatternInPatch(m, o), ...
                'tfp:util:assertPatternInPatch:outsidePatch');
            ws = warning('off', 'tfp:util:assertPatternInPatch:outsidePatch');
            restore = onCleanup(@() warning(ws));
            info = tfp.util.assertPatternInPatch(m, o);
            testCase.verifyGreaterThan(info.nOutside, 0);
            testCase.verifyGreaterThan(info.maxRadiusPx, 200);
        end

        function the_patch_is_a_disc_not_a_square(testCase)
            % A square inscribed by side = patch diameter pokes out at the
            % corners by sqrt(2) — the handoff's stated reason for a disc, and
            % precisely along the chip diagonals, which are the optical axes.
            r = 200;
            m = false(testCase.H, testCase.W);
            cx = round((testCase.W+1)/2); cy = round((testCase.H+1)/2);
            m(cy-r:cy+r, cx-r:cx+r) = true;   % square of half-side = patch radius
            testCase.verifyError( ...
                @() tfp.util.assertPatternInPatch(m, testCase.opts()), ...
                'tfp:util:assertPatternInPatch:outsidePatch');
        end

        function an_offset_centre_is_honoured(testCase)
            % The patch is centred on the ILLUMINATION, not necessarily the
            % chip. A disc that fails about the chip centre passes about its
            % own centre.
            % Offset 180 + radius 50 = 230 px from the chip centre, clear of
            % the 200 px patch radius. (150 + 50 would land EXACTLY on the
            % edge, and the test is r > R, so it would legitimately pass.)
            cx = (testCase.W+1)/2 + 180;
            cy = (testCase.H+1)/2;
            m  = testCase.discAt(cx, cy, 50);
            testCase.verifyError( ...
                @() tfp.util.assertPatternInPatch(m, testCase.opts()), ...
                'tfp:util:assertPatternInPatch:outsidePatch');
            info = tfp.util.assertPatternInPatch(m, ...
                testCase.opts('center', [cx cy]));
            testCase.verifyEqual(info.nOutside, 0);
        end

        function the_worst_frame_in_a_stack_is_reported(testCase)
            good = testCase.discAt((testCase.W+1)/2, (testCase.H+1)/2, 50);
            bad  = testCase.discAt((testCase.W+1)/2, (testCase.H+1)/2, 250);
            stack = cat(3, good, bad, good);
            o = testCase.opts('mode', 'warn');
            ws = warning('off', 'tfp:util:assertPatternInPatch:outsidePatch');
            restore = onCleanup(@() warning(ws));
            info = tfp.util.assertPatternInPatch(stack, o);
            testCase.verifyEqual(info.nFrames, 3);
            testCase.verifyEqual(info.nOutside([1 3]), [0 0]);
            testCase.verifyGreaterThan(info.nOutside(2), 0);
        end

        function the_default_diameter_comes_from_the_handoff(testCase)
            % No patchDiameterPx given: the constant must be read at runtime,
            % so a regenerated handoff propagates without a code edit.
            c = tfp.util.readHandoffConstants();
            m = testCase.discAt((testCase.W+1)/2, (testCase.H+1)/2, 10);
            info = tfp.util.assertPatternInPatch(m);
            testCase.verifyEqual(info.patchRadiusPx, ...
                double(c.patch_diameter_px)/2, 'AbsTol', 1e-9);
        end

        function an_empty_pattern_is_vacuously_contained(testCase)
            m = false(testCase.H, testCase.W);
            info = tfp.util.assertPatternInPatch(m, testCase.opts());
            testCase.verifyEqual(info.nOutside, 0);
            testCase.verifyEqual(info.maxRadiusPx, 0);
        end

    end
end
