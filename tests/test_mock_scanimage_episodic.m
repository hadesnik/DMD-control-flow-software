classdef test_mock_scanimage_episodic < matlab.unittest.TestCase
    %test_mock_scanimage_episodic Tests for T-EP-1c episodic API on MockScanImageBridge.
    %   Covers state machine, .mat sidecar contents, trialCounter advance,
    %   frame-drop / spurious-edge injection hooks, and disconnect reset.

    properties
        TmpDir char = ''
    end

    methods (TestMethodSetup)
        function makeTmpDir(testCase)
            % tempname() for the unique suffix, not matlab.lang.internal.uuid:
            % the latter is undocumented and absent in R2019b, which the
            % imaging PC runs. tempname generates the name only — no file is
            % created — so this is a drop-in on every supported release.
            [~, uniqueStem] = fileparts(tempname());
            testCase.TmpDir = fullfile(tempdir(), ...
                sprintf('tfp_mock_episodic_%s', uniqueStem));
            if ~exist(testCase.TmpDir, 'dir')
                mkdir(testCase.TmpDir);
            end
        end
    end

    methods (TestMethodTeardown)
        function rmTmpDir(testCase)
            if ~isempty(testCase.TmpDir) && exist(testCase.TmpDir, 'dir')
                try
                    rmdir(testCase.TmpDir, 's');
                catch
                    % ignore
                end
            end
        end
    end

    methods (Access = private)
        function bridge = makeBridge(testCase)
            config = struct();
            config.mockTiffDir = testCase.TmpDir;
            config.frameRateHz = 30;
            bridge = tfp.hardware.MockScanImageBridge({}, config);
        end
    end

    methods (Test)
        function constructionDefaults(testCase)
            bridge = testCase.makeBridge();
            % Use verifyEpisodicProtocol path: bridge starts idle and
            % session is inactive. We probe this by attempting an action
            % that requires sessionActive_ — getLastTiffPath should throw
            % badState.
            testCase.verifyError(@() bridge.getLastTiffPath(), ...
                'tfp:hardware:ScanImageBridge:badState');
        end

        function beginSessionHappyPath(testCase)
            bridge = testCase.makeBridge();
            opts = struct();
            opts.startAcqNumOverride   = uint32(42);
            opts.logFileStemOverride   = 'test_stem';
            opts.logFileSaveDirOverride = testCase.TmpDir;
            info = bridge.beginSession(opts);

            testCase.verifyEqual(info.startAcqNum, uint32(42));
            testCase.verifyEqual(info.logFileStem, 'test_stem');
            testCase.verifyEqual(info.logFileSaveDir, testCase.TmpDir);
            testCase.verifyEqual(info.acqNumWidth, uint8(5));
            testCase.verifyClass(info.sessionStartDatetime, 'datetime');
        end

        function beginSessionRejectsDoubleCall(testCase)
            bridge = testCase.makeBridge();
            bridge.beginSession(struct());
            testCase.verifyError(@() bridge.beginSession(struct()), ...
                'tfp:hardware:ScanImageBridge:badState');
        end

        function armBeforeBeginSessionAllowedInLegacyMode(testCase)
            % Legacy mode (sessionActive_ false): arm should NOT throw
            % badState — it's the back-compat path.
            bridge = testCase.makeBridge();
            % This should succeed (legacy mode), not throw badState.
            bridge.armForExternalTrigger(10);
            % But getLastTiffPath still requires sessionActive_.
            testCase.verifyError(@() bridge.getLastTiffPath(), ...
                'tfp:hardware:ScanImageBridge:badState');
        end

        function armRejectsBadNFrames(testCase)
            bridge = testCase.makeBridge();
            testCase.verifyError(@() bridge.armForExternalTrigger(0), ...
                'tfp:hardware:ScanImageBridge:badNFrames');
            testCase.verifyError(@() bridge.armForExternalTrigger(-5), ...
                'tfp:hardware:ScanImageBridge:badNFrames');
            testCase.verifyError(@() bridge.armForExternalTrigger(NaN), ...
                'tfp:hardware:ScanImageBridge:badNFrames');
        end

        function fullRoundTrip(testCase)
            bridge = testCase.makeBridge();
            opts = struct('logFileSaveDirOverride', testCase.TmpDir);
            bridge.beginSession(opts);
            bridge.armForExternalTrigger(5);
            bridge.waitForCompletion(5);
            tiffPath = bridge.getLastTiffPath();

            testCase.verifyTrue(exist(tiffPath, 'file') == 2, ...
                sprintf('Sidecar not found at %s', tiffPath));
            testCase.verifyTrue(endsWith(tiffPath, '.mat'));

            S = load(tiffPath, 'meta');
            testCase.verifyTrue(isfield(S, 'meta'));
            meta = S.meta;
            testCase.verifyEqual(meta.numFrames, uint32(5));
            testCase.verifyEqual(meta.numChannels, uint32(1));
            testCase.verifyEqual(numel(meta.frameTimestamps_s), 5);
            testCase.verifyTrue(meta.timestampsAreSynthesised);
            testCase.verifyEqual(meta.scanImageVersion, 'mock');
            testCase.verifyEqual(meta.sourceTiff, tiffPath);
        end

        function trialCounterIncrements(testCase)
            bridge = testCase.makeBridge();
            bridge.beginSession(struct('logFileSaveDirOverride', testCase.TmpDir));

            paths = cell(1, 3);
            for i = 1:3
                bridge.armForExternalTrigger(4);
                bridge.waitForCompletion(5);
                paths{i} = bridge.getLastTiffPath();
            end

            [~, name1] = fileparts(paths{1});
            [~, name2] = fileparts(paths{2});
            [~, name3] = fileparts(paths{3});
            testCase.verifyEqual(name1, 'mock_trial_0001');
            testCase.verifyEqual(name2, 'mock_trial_0002');
            testCase.verifyEqual(name3, 'mock_trial_0003');
            for i = 1:3
                testCase.verifyTrue(exist(paths{i}, 'file') == 2);
            end
        end

        function injectFrameDropRemovesEntry(testCase)
            bridge = testCase.makeBridge();
            bridge.beginSession(struct('logFileSaveDirOverride', testCase.TmpDir));
            bridge.injectFrameDrop(3);
            bridge.armForExternalTrigger(5);
            bridge.waitForCompletion(5);
            tp = bridge.getLastTiffPath();
            S = load(tp, 'meta');
            testCase.verifyEqual(S.meta.numFrames, uint32(4));
        end

        function injectSpuriousEdgeAddsEntry(testCase)
            bridge = testCase.makeBridge();
            bridge.beginSession(struct('logFileSaveDirOverride', testCase.TmpDir));
            bridge.injectSpuriousEdge(2);
            bridge.armForExternalTrigger(5);
            bridge.waitForCompletion(5);
            tp = bridge.getLastTiffPath();
            S = load(tp, 'meta');
            testCase.verifyEqual(S.meta.numFrames, uint32(6));
        end

        function injectionsClearBetweenTrials(testCase)
            bridge = testCase.makeBridge();
            bridge.beginSession(struct('logFileSaveDirOverride', testCase.TmpDir));

            % Inject drop before trial 1.
            bridge.injectFrameDrop(2);
            bridge.armForExternalTrigger(5);
            bridge.waitForCompletion(5);
            tp1 = bridge.getLastTiffPath();
            S1 = load(tp1, 'meta');
            testCase.verifyEqual(S1.meta.numFrames, uint32(4)); % drop applied

            % Trial 2 should have NO injection effect.
            bridge.armForExternalTrigger(5);
            bridge.waitForCompletion(5);
            tp2 = bridge.getLastTiffPath();
            S2 = load(tp2, 'meta');
            testCase.verifyEqual(S2.meta.numFrames, uint32(5)); % no drop
        end

        function disconnectClearsSession(testCase)
            bridge = testCase.makeBridge();
            bridge.beginSession(struct('logFileSaveDirOverride', testCase.TmpDir));
            bridge.armForExternalTrigger(5);
            bridge.waitForCompletion(5);
            bridge.getLastTiffPath();

            bridge.disconnect();

            % After disconnect, beginSession should work again.
            info = bridge.beginSession(struct( ...
                'startAcqNumOverride',    uint32(99), ...
                'logFileSaveDirOverride', testCase.TmpDir));
            testCase.verifyEqual(info.startAcqNum, uint32(99));

            % And trialCounter restarted at 0 → first arm produces trial_0001.
            bridge.armForExternalTrigger(3);
            bridge.waitForCompletion(5);
            tp = bridge.getLastTiffPath();
            [~, name] = fileparts(tp);
            testCase.verifyEqual(name, 'mock_trial_0001');
        end

        function logEntriesInOrder(testCase)
            bridge = testCase.makeBridge();
            bridge.beginSession(struct('logFileSaveDirOverride', testCase.TmpDir));
            bridge.armForExternalTrigger(3);
            bridge.waitForCompletion(5);
            bridge.getLastTiffPath();
            bridge.disconnect();

            entries = bridge.getLog();
            types = {entries.eventType};
            % Verify presence and order of key events.
            expected = {'beginSession', 'armForExternalTrigger', ...
                        'waitForCompletion', 'getLastTiffPath', 'disconnect'};
            % Find each expected entry in order.
            startIdx = 1;
            for i = 1:numel(expected)
                hit = find(strcmp(types(startIdx:end), expected{i}), 1, 'first');
                testCase.verifyNotEmpty(hit, ...
                    sprintf('Missing log entry %s', expected{i}));
                startIdx = startIdx + hit;
            end
        end

        function waitWithoutArmThrowsInSession(testCase)
            bridge = testCase.makeBridge();
            bridge.beginSession(struct('logFileSaveDirOverride', testCase.TmpDir));
            testCase.verifyError(@() bridge.waitForCompletion(5), ...
                'tfp:hardware:ScanImageBridge:badState');
        end

        function getLastTiffPathRequiresCompleted(testCase)
            bridge = testCase.makeBridge();
            bridge.beginSession(struct('logFileSaveDirOverride', testCase.TmpDir));
            bridge.armForExternalTrigger(3);
            % Not yet completed.
            testCase.verifyError(@() bridge.getLastTiffPath(), ...
                'tfp:hardware:ScanImageBridge:badState');
        end
    end
end
