classdef test_timing_analysis < matlab.unittest.TestCase
    %test_timing_analysis Tests for the DMD switching-timing toolset (scripts/photodiode_timing_tests/).
    %
    %   The shared test harness (runtests.m) adds only src/ to the path and
    %   discovers tests under tests/.  It does NOT add scripts/photodiode_timing_tests/, where
    %   the timing toolset lives.  This test therefore adds both src/ and
    %   scripts/photodiode_timing_tests/ to the path in a TestClassSetup fixture and restores
    %   the original path on teardown, so it is self-contained.
    %
    %   Covered functions (all in scripts/photodiode_timing_tests/):
    %     defaultTimingConfig, makeTimingPatterns, synthTimingTrace,
    %     analyzeTimingTrace, acquireTimingRun, runDMDTimingSweep,
    %     runPLMTimingSweep_stub.
    %
    %   Recovery tolerances are pinned to the synthetic signal model documented
    %   in synthTimingTrace.m / analyzeTimingTrace.m: latency within ~2 sample
    %   periods + jitter, rise/fall within 25%, achieved rate within 3%.

    properties
        OrigPath = '';   % path() snapshot restored on teardown
    end

    methods (TestClassSetup)
        function addTimingPath(testCase)
            %addTimingPath Add src/ and scripts/photodiode_timing_tests/ to the MATLAB path.
            %   Snapshots the path first and restores it on class teardown so
            %   this test leaves the path exactly as it found it.
            testCase.OrigPath = path();

            thisFile = mfilename('fullpath');
            testsDir = fileparts(thisFile);
            repoRoot = fileparts(testsDir);

            srcDir    = fullfile(repoRoot, 'src');
            timingDir = fullfile(repoRoot, 'scripts', 'photodiode_timing_tests');

            addpath(srcDir);
            addpath(timingDir);

            % Restore the original path no matter how the class exits.
            restoreFcn = testCase.OrigPath;
            testCase.addTeardown(@() path(restoreFcn));
        end
    end

    methods (Test)

        % -----------------------------------------------------------------
        % 1. defaultTimingConfig schema + merge + validation
        % -----------------------------------------------------------------
        function testDefaultConfigSchema(testCase)
            cfg = defaultTimingConfig();

            % Top-level scalar fields.
            testCase.verifyTrue(isstruct(cfg));
            testCase.verifyEqual(cfg.hardwareKind, 'mock');
            testCase.verifyTrue(isnumeric(cfg.sampleRateHz) && isscalar(cfg.sampleRateHz));

            % Nested sub-structs that the toolset relies on.
            for f = {'channels', 'trigger', 'sweep', 'pattern', 'dmd', 'synth'}
                testCase.verifyTrue(isfield(cfg, f{1}), ...
                    sprintf('cfg must have field %s', f{1}));
                testCase.verifyTrue(isstruct(cfg.(f{1})), ...
                    sprintf('cfg.%s must be a struct', f{1}));
            end

            % trigger.mode default.
            testCase.verifyEqual(cfg.trigger.mode, 'external');

            % Deep merge keeps unspecified defaults, overrides specified ones.
            cfg2 = defaultTimingConfig(struct('hardwareKind', 'real'));
            testCase.verifyEqual(cfg2.hardwareKind, 'real');
            testCase.verifyEqual(cfg2.trigger.mode, 'external', ...
                'unspecified nested defaults must survive the merge');
            testCase.verifyEqual(cfg2.sampleRateHz, cfg.sampleRateHz, ...
                'unspecified top-level defaults must survive the merge');

            % Invalid hardwareKind errors.
            testCase.verifyError(@() defaultTimingConfig(struct('hardwareKind', 'bogus')), ...
                'tfp:timing:defaultTimingConfig:badHardwareKind');
        end

        % -----------------------------------------------------------------
        % 2. makeTimingPatterns shape + content
        % -----------------------------------------------------------------
        function testMakePatterns(testCase)
            dmd = struct('nRows', 800, 'nCols', 1280);
            cfg = defaultTimingConfig();

            [p, pinfo] = makeTimingPatterns(dmd, cfg);
            testCase.verifyTrue(islogical(p));
            testCase.verifyEqual(size(p), [800 1280 2]);
            testCase.verifyGreaterThan(nnz(p(:, :, 1)), 0, ...
                'pattern A (on-spot) must have active pixels');
            testCase.verifyTrue(isstruct(pinfo));

            % alloff mode: pattern B has no active pixels.
            cfgAllOff = defaultTimingConfig(struct('pattern', struct('offMode', 'alloff')));
            p2 = makeTimingPatterns(dmd, cfgAllOff);
            testCase.verifyEqual(nnz(p2(:, :, 2)), 0, ...
                'alloff mode must blank pattern B entirely');
        end

        % -----------------------------------------------------------------
        % 3. CORE: synth -> analyze ground-truth recovery
        % -----------------------------------------------------------------
        function testSynthAnalyzeRecovery(testCase)
            cfg = defaultTimingConfig(struct( ...
                'sampleRateHz', 1e6, ...
                'synth', struct( ...
                    'latency_s',      20e-6, ...
                    'riseTime_s',     10e-6, ...
                    'fallTime_s',     10e-6, ...
                    'jitterStd_s',    0.5e-6, ...
                    'maxTrackRateHz', 1e9, ...
                    'noiseStd_v',     0.01)));

            raw = synthTimingTrace(cfg, 2000, 80);
            m   = analyzeTimingTrace(raw, cfg);

            % Latency: within ~2 sample periods + the per-transition jitter.
            latTol = 2 / cfg.sampleRateHz + raw.truth.jitterStd_s;
            testCase.verifyLessThanOrEqual( ...
                abs(m.latencyMean_s - raw.truth.latency_s), latTol, ...
                'latencyMean must track truth within 2 samples + jitter');

            % Rise / fall: within 25% of truth.
            testCase.verifyLessThanOrEqual( ...
                abs(m.riseMean_s - raw.truth.riseTime_s), 0.25 * raw.truth.riseTime_s, ...
                'riseMean must be within 25% of truth');
            testCase.verifyLessThanOrEqual( ...
                abs(m.fallMean_s - raw.truth.fallTime_s), 0.25 * raw.truth.fallTime_s, ...
                'fallMean must be within 25% of truth');

            % Achieved rate: within 3% of the true effective rate.
            relRateErr = abs(m.achievedRateHz - raw.truth.effectiveRateHz) / ...
                raw.truth.effectiveRateHz;
            testCase.verifyLessThanOrEqual(relRateErr, 0.03, ...
                'achievedRateHz must be within 3% of the true effective rate');

            % Tracking flags and contrast.
            testCase.verifyTrue(m.trackingOK, 'trackingOK must be true when no frames drop');
            testCase.verifyLessThan(m.droppedFraction, 0.05, ...
                'droppedFraction must be small when tracking');
            testCase.verifyGreaterThan(m.contrastV, 1, ...
                'contrast (2.0 high vs 0.05 low) must exceed 1 V');
        end

        % -----------------------------------------------------------------
        % 4. Dropped-frame detection above maxTrackRateHz
        % -----------------------------------------------------------------
        function testDroppedFrameDetection(testCase)
            cfg = defaultTimingConfig(struct( ...
                'sampleRateHz', 1e6, ...
                'synth', struct('maxTrackRateHz', 4000)));

            raw = synthTimingTrace(cfg, 12000, 120);   % commanded >> maxTrack
            m   = analyzeTimingTrace(raw, cfg);

            testCase.verifyGreaterThan(m.droppedFraction, 0.1, ...
                'dropping must be detected when commanded >> maxTrack');
            testCase.verifyFalse(m.trackingOK, ...
                'trackingOK must be false when frames drop');

            % Effective rate clamps to maxTrackRateHz; coarser tolerance.
            relRateErr = abs(m.achievedRateHz - 4000) / 4000;
            testCase.verifyLessThanOrEqual(relRateErr, 0.15, ...
                'achievedRateHz must be within 15% of the 4 kHz effective rate');
        end

        % -----------------------------------------------------------------
        % 5. acquireTimingRun mock plumbing (DAQ/DMD log sequence)
        % -----------------------------------------------------------------
        function testAcquireMockPlumbing(testCase)
            cfg = defaultTimingConfig(struct('sampleRateHz', 1e6));

            dmd = tfp.hardware.MockDMD();
            dmd.initialize(struct( ...
                'nRows',                   cfg.dmd.nRows, ...
                'nCols',                   cfg.dmd.nCols, ...
                'maxPatternRate',          cfg.dmd.maxPatternRate, ...
                'loadLatencyMsPerPattern', 0));

            daq = tfp.hardware.MockDAQ();
            daq.initialize(struct( ...
                'sampleRate',         cfg.sampleRateHz, ...
                'analogInChannels',   cfg.channels.apdAI, ...
                'analogOutChannels',  cfg.channels.trigAO, ...
                'digitalInChannels',  {{cfg.channels.trigDI}}, ...
                'digitalOutChannels', {{}}));

            cfg.pattern.stack = makeTimingPatterns(dmd, cfg);

            raw = acquireTimingRun(cfg, dmd, daq, 2000);

            % rawCapture shape and content.
            testCase.verifyTrue(isstruct(raw));
            testCase.verifyTrue(iscolumn(raw.apd) && iscolumn(raw.trig));
            testCase.verifyEqual(numel(raw.apd), numel(raw.trig));
            testCase.verifyGreaterThan(numel(raw.apd), 0);
            testCase.verifyEqual(raw.commandedRateHz, 2000);
            testCase.verifyTrue(isstruct(raw.truth), ...
                'mock acquisition overlays a synthetic truth struct');

            % MockDAQ continuous-session call sequence (external mode).
            lg = daq.getLog();
            ev = {lg.eventType};
            testCase.verifyTrue(ismember('startContinuousSession', ev));
            testCase.verifyTrue(ismember('stopContinuousSession', ev));
            testCase.verifyTrue(ismember('queueClockedAO', ev), ...
                'external trigger mode must queue a clocked AO waveform');

            % MockDMD must have been loaded and armed.
            dlg = dmd.getLog();
            dev = {dlg.eventType};
            testCase.verifyTrue(ismember('loadPatternSequence', dev));
            testCase.verifyTrue(ismember('armSequence', dev));
        end

        % -----------------------------------------------------------------
        % 6. runDMDTimingSweep end-to-end on the mock path
        % -----------------------------------------------------------------
        function testRunSweepEndToEndMock(testCase)
            sessName = ['ut_' datestr(now, 'HHMMSSFFF')]; %#ok<TNOW1,DATST>
            tempDir  = fullfile(tempdir, sessName);

            % Clean up the temp session dir regardless of outcome.
            testCase.addTeardown(@() removeIfExists(tempDir));

            ov = struct( ...
                'hardwareKind', 'mock', ...
                'makePlots',    false, ...
                'sampleRateHz', 1e6, ...
                'sweep',        struct('ratesHz', [1000 4000], ...
                                       'transitionsPerRate', 60), ...
                'paths',        struct('dataDir', tempDir));

            result = runDMDTimingSweep(ov, sessName);

            testCase.verifyTrue(isstruct(result));
            testCase.verifyEqual(numel(result.metrics), 2, ...
                'one metrics entry per swept rate');
            testCase.verifyTrue(isfield(result, 'maxReliableRateHz'));

            % Every documented metrics field must be present.
            expectedFields = { ...
                'commandedRateHz', 'nTriggerEdges', 'nOpticalTransitions', ...
                'highLevelV', 'lowLevelV', 'contrastV', ...
                'latency_s', 'latencyMean_s', 'latencyMedian_s', 'latencyStd_s', ...
                'riseTime_s', 'fallTime_s', 'riseMean_s', 'fallMean_s', ...
                'achievedRateHz', 'intervalStd_s', 'jitter_s', 'dutyCycle', ...
                'trackingOK', 'droppedFraction', 'edges', 'notes'};
            m1 = result.metrics(1);
            for k = 1:numel(expectedFields)
                testCase.verifyTrue(isfield(m1, expectedFields{k}), ...
                    sprintf('metrics must have field %s', expectedFields{k}));
            end

            % Saved result file must exist.
            outFile = fullfile(result.sessionDir, 'timing_result.mat');
            testCase.verifyTrue(isfile(outFile), ...
                'runDMDTimingSweep must save timing_result.mat in the session dir');
        end

        % -----------------------------------------------------------------
        % 7. PLM sweep stub is unimplemented
        % -----------------------------------------------------------------
        function testPlmStubErrors(testCase)
            testCase.verifyError(@() runPLMTimingSweep_stub([], 'x'), ...
                'tfp:timing:runPLMTimingSweep:notImplemented');
        end

    end
end


% =========================================================================
% Local helper -- remove a directory tree if it exists (teardown-safe)
% =========================================================================
function removeIfExists(d)
%removeIfExists Recursively delete directory D if present; never errors.
if exist(d, 'dir')
    try
        rmdir(d, 's');
    catch
        % Best-effort cleanup; a leftover temp dir must not fail the test.
    end
end
end
