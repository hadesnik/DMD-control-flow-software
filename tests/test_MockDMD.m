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
                p(:, :, k) = tfp.patterns.singleSpot(dmd, [640 + k*10, 400], 5);
            end
        end

        function opts = defaultOptions(~)
            opts.exposureUs = 1000;
            opts.darkTimeUs = 100;
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
    end
end
