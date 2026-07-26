classdef test_MockDMD < matlab.unittest.TestCase
    %test_MockDMD Phase 1 MockDMD tests.

    methods (Access = private)
        function dmd = makeDmd(~)
            dmd = tfp.hardware.MockDMD();
            config.nRows = 800;
            config.nCols = 1280;
            config.maxPatternRate = 12500;
            config.debugFigure = false;
            config.loadLatencyMsPerPattern = 0;   % fast tests
            dmd.initialize(config);
        end

        function p = makePatterns(~, dmd, n)
            p = false(dmd.nRows, dmd.nCols, n);
            for k = 1:n
                p(:, :, k) = tfp.patterns.singleSpot(dmd, [640 + k*10, 400], 14);
            end
        end

        function opts = defaultOptions(~)
            opts.exposureUs = 1000;
            opts.darkTimeUs = 100;
        end

        % --- T-BU-2a helpers ---------------------------------------------
        function dmd = makeDmdWithPatch(~)
            %makeDmdWithPatch A mock whose config DECLARES the patch geometry,
            %   which is what turns the patch-containment guard on (mock.yaml
            %   declares no optics, so the plain makeDmd() above leaves it off).
            dmd = tfp.hardware.MockDMD();
            config.nRows                   = 800;
            config.nCols                   = 1280;
            config.maxPatternRate          = 12500;
            config.debugFigure             = false;
            config.loadLatencyMsPerPattern = 0;
            config.patchCenterPx           = [640 400];
            config.patchRadiusPx           = 278;
            config.patchMaxRadiusPx        = 329;
            dmd.initialize(config);
        end

        function safety = lastLoadSafety(~, dmd)
            %lastLoadSafety The safety summary logged by the most recent load.
            entries = dmd.getLog();
            iLoad   = find(strcmp({entries.eventType}, 'loadPatternSequence'), 1, 'last');
            safety  = entries(iLoad).payload.safety;
        end
    end

    methods (Test)
        function initialize_setsDimensions(testCase)
            dmd = tfp.hardware.MockDMD();
            config.nRows = 800;
            config.nCols = 1280;
            config.maxPatternRate = 12500;
            config.debugFigure = false;
            config.loadLatencyMsPerPattern = 0;
            dmd.initialize(config);

            testCase.verifyEqual(dmd.nRows, 800);
            testCase.verifyEqual(dmd.nCols, 1280);
            testCase.verifyEqual(dmd.maxPatternRate, 12500);
            testCase.verifyTrue(dmd.isInitialized);
        end

        function loadPatternSequence_validation(testCase)
            dmd  = testCase.makeDmd();
            opts = testCase.defaultOptions();

            % Non-logical rejected.
            badType = zeros(dmd.nRows, dmd.nCols, 2);   % double
            testCase.verifyError(@() dmd.loadPatternSequence(badType, opts), ...
                'tfp:hardware:MockDMD:badPatterns');

            % Wrong shape rejected.
            badShape = false(dmd.nRows - 10, dmd.nCols, 2);
            testCase.verifyError(@() dmd.loadPatternSequence(badShape, opts), ...
                'tfp:hardware:MockDMD:badPatternShape');

            % Options missing a required field rejected.
            badOpts = struct('exposureUs', 1000);   % no darkTimeUs
            goodPatterns = false(dmd.nRows, dmd.nCols, 2);
            testCase.verifyError(@() dmd.loadPatternSequence(goodPatterns, badOpts), ...
                'tfp:hardware:MockDMD:badOptions');

            % Valid input accepted.
            dmd.loadPatternSequence(goodPatterns, opts);
            testCase.verifyEqual(dmd.getStatus().nPatternsLoaded, 2);
        end

        function loadPatternSequence_storesPatterns(testCase)
            dmd      = testCase.makeDmd();
            patterns = testCase.makePatterns(dmd, 3);
            dmd.loadPatternSequence(patterns, testCase.defaultOptions());

            s = dmd.getStatus();
            testCase.verifyEqual(s.nPatternsLoaded, 3);
        end

        function armAndTrigger_advancesIndex(testCase)
            dmd      = testCase.makeDmd();
            patterns = testCase.makePatterns(dmd, 3);
            dmd.loadPatternSequence(patterns, testCase.defaultOptions());
            dmd.armSequence();

            s = dmd.getStatus();
            testCase.verifyEqual(s.state, 'armed');
            testCase.verifyEqual(s.currentPatternIdx, 0);

            dmd.softTrigger();
            s = dmd.getStatus();
            testCase.verifyEqual(s.currentPatternIdx, 1);
            testCase.verifyEqual(s.state, 'running');

            dmd.softTrigger();
            testCase.verifyEqual(dmd.getStatus().currentPatternIdx, 2);

            dmd.softTrigger();
            testCase.verifyEqual(dmd.getStatus().currentPatternIdx, 3);

            % Wrap: after pattern 3, next softTrigger goes to 1.
            dmd.softTrigger();
            testCase.verifyEqual(dmd.getStatus().currentPatternIdx, 1);
        end

        function advanceToPattern_jumpsToIdx(testCase)
            dmd      = testCase.makeDmd();
            patterns = testCase.makePatterns(dmd, 5);
            dmd.loadPatternSequence(patterns, testCase.defaultOptions());
            dmd.armSequence();

            dmd.advanceToPattern(4);
            testCase.verifyEqual(dmd.getStatus().currentPatternIdx, 4);

            % Out-of-range rejected.
            testCase.verifyError(@() dmd.advanceToPattern(99), ...
                'tfp:hardware:MockDMD:badIdx');
            testCase.verifyError(@() dmd.advanceToPattern(0), ...
                'tfp:hardware:MockDMD:badIdx');
        end

        function log_capturesCalls(testCase)
            dmd      = testCase.makeDmd();
            patterns = testCase.makePatterns(dmd, 2);
            dmd.loadPatternSequence(patterns, testCase.defaultOptions());
            dmd.armSequence();
            dmd.softTrigger();

            entries = dmd.getLog();
            eventTypes = {entries.eventType};

            % First entry is 'initialize' (from makeDmd).
            testCase.verifyEqual(eventTypes{1}, 'initialize');
            testCase.verifyTrue(any(strcmp(eventTypes, 'loadPatternSequence')));
            testCase.verifyTrue(any(strcmp(eventTypes, 'armSequence')));
            testCase.verifyTrue(any(strcmp(eventTypes, 'softTrigger')));

            % Ordering: load < arm < trigger.
            iLoad = find(strcmp(eventTypes, 'loadPatternSequence'), 1);
            iArm  = find(strcmp(eventTypes, 'armSequence'), 1);
            iTrig = find(strcmp(eventTypes, 'softTrigger'), 1);
            testCase.verifyLessThan(iLoad, iArm);
            testCase.verifyLessThan(iArm, iTrig);
        end

        function cleanup_clearsState(testCase)
            dmd      = testCase.makeDmd();
            patterns = testCase.makePatterns(dmd, 3);
            dmd.loadPatternSequence(patterns, testCase.defaultOptions());
            dmd.armSequence();

            dmd.cleanup();
            s = dmd.getStatus();
            testCase.verifyEqual(s.state, 'idle');
            testCase.verifyEqual(s.nPatternsLoaded, 0);
            testCase.verifyEqual(s.currentPatternIdx, 0);
        end

        % =================================================================
        % T-BU-2a: both pattern-domain interlocks run on every load.
        % The two guards are conservative in OPPOSITE directions and neither
        % subsumes the other, so the cases below deliberately exercise each
        % one while the other is silent:
        %   * an all-ON frame is sparse-free but perfectly on-patch -> only
        %     the pupil pulse-energy guard can reject it;
        %   * an off-patch single spot is far below the fill gate -> only the
        %     patch-containment guard can reject it.
        % =================================================================

        function patternSafety_defaultAssumesFullScaleVoltage(testCase)
            % The DMD does not own ao3, so until it is told otherwise it must
            % assume the worst case (full-scale voltage), never "unknown =
            % skip the check".
            dmd = testCase.makeDmd();
            s   = dmd.patternSafetyStatus();

            testCase.verifyEqual(s.assumedLaserVoltageV, 5);
            testCase.verifySubstring(lower(s.voltageSource), 'worst case');
            % mock.yaml-style config declares no optics -> no patch to test on.
            testCase.verifyFalse(s.patchCheckEnabled);
            testCase.verifyFalse(s.patchGeometryDeclared);
        end

        function patternSafety_blocksAllOnFrameAtWorstCaseVoltage(testCase)
            % The all-ON alignment frame is exactly the case the pupil
            % interlock exists for: 5 V = 40 W at 100 kHz = 400 uJ/pulse,
            % ~5.9x the 68 uJ air-ionisation limit at the relay pupil.
            dmd   = testCase.makeDmd();
            allOn = true(dmd.nRows, dmd.nCols);

            err = catchError(testCase, ...
                @() dmd.loadPatternSequence(allOn, testCase.defaultOptions()), ...
                'tfp:util:assertPulseEnergySafe:overPupilLimit');
            testCase.verifySubstring(err.message, 'MockDMD.loadPatternSequence');

            % A rejected sequence must not have been loaded.
            s = dmd.getStatus();
            testCase.verifyEqual(s.nPatternsLoaded, 0);
            testCase.verifyEqual(s.state, 'idle');
        end

        function patternSafety_sparsePatternIsExemptAndLogged(testCase)
            dmd      = testCase.makeDmd();
            patterns = testCase.makePatterns(dmd, 2);
            dmd.loadPatternSequence(patterns, testCase.defaultOptions());

            safety = testCase.lastLoadSafety(dmd);
            testCase.verifyTrue(safety.pulseChecked);
            testCase.verifyFalse(safety.pulseInfo.gated);   % fill << 0.2
            testCase.verifyEqual(safety.assumedLaserVoltageV, 5);
            % Patch check skipped for want of geometry — but never silently.
            testCase.verifyFalse(safety.patchChecked);
            testCase.verifyNotEmpty(safety.patchSkipReason);
            testCase.verifySubstring(safety.patchSkipReason, 'enforcePatch');
        end

        function patternSafety_declaredLaserOffAllowsAllOnFrame(testCase)
            % The sanctioned way to project an alignment frame: tell the DMD
            % the laser is shuttered. Explicit, reasoned, and logged.
            dmd = testCase.makeDmd();
            dmd.setAssumedLaserVoltage(0, 'laser shuttered for alignment');

            allOn = true(dmd.nRows, dmd.nCols);
            dmd.loadPatternSequence(allOn, testCase.defaultOptions());

            testCase.verifyEqual(dmd.getStatus().nPatternsLoaded, 1);
            safety = testCase.lastLoadSafety(dmd);
            testCase.verifyEqual(safety.assumedLaserVoltageV, 0);
            testCase.verifySubstring(safety.voltageSource, 'shuttered');
        end

        function patternSafety_perLoadVoltageOverride(testCase)
            dmd   = testCase.makeDmd();
            allOn = true(dmd.nRows, dmd.nCols);
            opts  = testCase.defaultOptions();

            opts.laserVoltageV = 0;                 % caller: laser is off
            dmd.loadPatternSequence(allOn, opts);
            safety = testCase.lastLoadSafety(dmd);
            testCase.verifyEqual(safety.assumedLaserVoltageV, 0);
            testCase.verifySubstring(safety.voltageSource, 'options.laserVoltageV');

            opts.laserVoltageV = 5;                 % caller: full scale
            testCase.verifyError( ...
                @() dmd.loadPatternSequence(allOn, opts), ...
                'tfp:util:assertPulseEnergySafe:overPupilLimit');

            opts.laserVoltageV = -1;                % nonsense is refused
            testCase.verifyError( ...
                @() dmd.loadPatternSequence(allOn, opts), ...
                'tfp:hardware:DMD:badLaserVoltage');
        end

        function patternSafety_setAssumedLaserVoltageValidates(testCase)
            dmd = testCase.makeDmd();
            testCase.verifyError(@() dmd.setAssumedLaserVoltage(-1, 'x'), ...
                'tfp:hardware:DMD:badLaserVoltage');
            testCase.verifyError(@() dmd.setAssumedLaserVoltage([1 2], 'x'), ...
                'tfp:hardware:DMD:badLaserVoltage');
            testCase.verifyError(@() dmd.setAssumedLaserVoltage('off', 'x'), ...
                'tfp:hardware:DMD:badLaserVoltage');
        end

        function patternSafety_patchGuardRunsWhenGeometryDeclared(testCase)
            dmd = testCase.makeDmdWithPatch();
            testCase.verifyTrue(dmd.patternSafetyStatus().patchCheckEnabled);

            onPatch = tfp.patterns.singleSpot(dmd, [640 400], 14);
            dmd.loadPatternSequence(onPatch, testCase.defaultOptions());

            safety = testCase.lastLoadSafety(dmd);
            testCase.verifyTrue(safety.patchChecked);
            testCase.verifyLessThanOrEqual(safety.patchInfo.worstRadiusPx, 278);
            testCase.verifyEqual(safety.patchInfo.nOverPatch, 0);
        end

        function patternSafety_patchGuardRejectsOffPatchSpot(testCase)
            % Single spot, fill ~5e-4 — far below the pupil interlock's 0.2
            % fill gate, so the pulse-energy guard passes it. Only the patch
            % guard can catch this one.
            dmd = testCase.makeDmdWithPatch();
            bad = tfp.patterns.singleSpot(dmd, [950 400], 14);   % 310 px out

            err = catchError(testCase, ...
                @() dmd.loadPatternSequence(bad, testCase.defaultOptions()), ...
                'tfp:util:assertPatternInPatch:outsidePatch');
            testCase.verifySubstring(err.message, '[MockDMD.loadPatternSequence]');
            testCase.verifyEqual(dmd.getStatus().nPatternsLoaded, 0);
        end

        function patternSafety_patchGuardRejectsBeyondHardLimit(testCase)
            dmd = testCase.makeDmdWithPatch();
            bad = tfp.patterns.singleSpot(dmd, [1010 400], 14);  % 370+ px out

            err = catchError(testCase, ...
                @() dmd.loadPatternSequence(bad, testCase.defaultOptions()), ...
                'tfp:util:assertPatternInPatch:outsideHardLimit');
            testCase.verifySubstring(err.message, '[MockDMD.loadPatternSequence]');
        end

        function patternSafety_enforcePatchForcesCheckWithoutGeometry(testCase)
            % dmd.enforcePatch only ever TIGHTENS: it turns the check on
            % against the tfp.util.opticalModel design defaults for a config
            % that never spelled the geometry out.
            dmd = tfp.hardware.MockDMD();
            config.nRows                   = 800;
            config.nCols                   = 1280;
            config.maxPatternRate          = 12500;
            config.debugFigure             = false;
            config.loadLatencyMsPerPattern = 0;
            config.enforcePatch            = true;
            dmd.initialize(config);

            s = dmd.patternSafetyStatus();
            testCase.verifyTrue(s.patchCheckEnabled);
            testCase.verifyFalse(s.patchGeometryDeclared);

            bad = tfp.patterns.singleSpot(dmd, [1010 400], 14);
            testCase.verifyError( ...
                @() dmd.loadPatternSequence(bad, testCase.defaultOptions()), ...
                'tfp:util:assertPatternInPatch:outsideHardLimit');
        end

        function patternSafety_configurePatternSafetyReadsLaserBlock(testCase)
            % makeHardware hands the FULL config over, which is the only way
            % the DMD sees the laser block. The rep rate is decisive here:
            % the SAME all-ON frame that is blocked at 100 kHz passes at
            % 10 MHz, because pulse energy = average power / rep rate.
            dmd = testCase.makeDmd();
            cfg.dmd   = struct('nRows', 800, 'nCols', 1280);
            cfg.laser = struct('modulation_voltage_max', 5, 'rep_rate_hz', 1e7);
            dmd.configurePatternSafety(cfg);

            s = dmd.patternSafetyStatus();
            testCase.verifyEqual(s.assumedLaserVoltageV, 5);
            testCase.verifySubstring(s.voltageSource, 'modulation_voltage_max');

            allOn = true(dmd.nRows, dmd.nCols);
            dmd.loadPatternSequence(allOn, testCase.defaultOptions());

            safety = testCase.lastLoadSafety(dmd);
            testCase.verifyTrue(safety.pulseInfo.gated);        % fill 1.0 >= 0.2
            testCase.verifyEqual(safety.pulseInfo.pulseEnergyUj, 4, 'AbsTol', 1e-9);
        end

        function patternSafety_worstSliceFoundInChunkedStack(testCase)
            % Large stacks are evaluated in chunks to bound peak memory; the
            % offending slice must still be found, and the message must say
            % where it was (global, not chunk-local, indices).
            dmd = testCase.makeDmd();
            n   = 10;
            patterns = false(dmd.nRows, dmd.nCols, n);
            for k = 1:n
                patterns(:, :, k) = tfp.patterns.singleSpot(dmd, [640 400], 14);
            end
            patterns(:, :, 9) = true;   % all-ON frame hidden late in the stack

            err = catchError(testCase, ...
                @() dmd.loadPatternSequence(patterns, testCase.defaultOptions()), ...
                'tfp:util:assertPulseEnergySafe:overPupilLimit');
            testCase.verifySubstring(err.message, 'MockDMD.loadPatternSequence');
            testCase.verifySubstring(err.message, 'of 10');
        end

        function patternSafety_emptyStackIsSkipped(testCase)
            dmd = testCase.makeDmd();
            dmd.loadPatternSequence(false(dmd.nRows, dmd.nCols, 0), ...
                testCase.defaultOptions());

            safety = testCase.lastLoadSafety(dmd);
            testCase.verifyFalse(safety.pulseChecked);
            testCase.verifySubstring(safety.patchSkipReason, 'empty pattern array');
        end
    end
end

% =========================================================================

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
