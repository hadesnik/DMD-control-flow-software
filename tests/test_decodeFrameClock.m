classdef test_decodeFrameClock < matlab.unittest.TestCase
    %test_decodeFrameClock Unit tests for tfp.io.decodeFrameClock (T-SYNC-4).
    %
    %   Verifies the rising-edge decoder against the SYNC_FRAME.md §5
    %   contract: regular pulse trains, jittered spacing, missing pulses,
    %   and polarity inversion.

    properties (Constant)
        SAMPLE_RATE = 100000;   % 100 kHz master clock
        FRAME_RATE  = 1000;     % 1 kHz frame clock (period = 100 samples)
        N_FRAMES    = 200;
        PULSE_WIDTH = 1;        % samples; native ScanImage TTL is sub-sample
    end

    methods (Access = private)
        function [vec, edges] = makePulseTrain(testCase, intervals, pulseWidth, totalLen, startOffset)
            % Build a logical pulse train with rising edges at cumulative
            % offsets `startOffset + cumsum([0 intervals(1:end-1)])`.
            %   intervals    - vector of inter-edge gaps in samples
            %   pulseWidth   - high duration in samples per pulse
            %   totalLen     - length of returned vector
            %   startOffset  - sample index of the first rising edge (1-based)
            edges = startOffset + [0, cumsum(intervals(1:end-1))];
            vec = false(totalLen, 1);
            for k = 1:numel(edges)
                hiStart = edges(k);
                hiStop  = min(totalLen, hiStart + pulseWidth - 1);
                if hiStart >= 1 && hiStart <= totalLen
                    vec(hiStart:hiStop) = true;
                end
            end
        end
    end

    methods (Test)

        function regular_pulseTrain_recoversRateAndEdges(testCase)
            period = testCase.SAMPLE_RATE / testCase.FRAME_RATE;   % 100
            intervals = period * ones(1, testCase.N_FRAMES);
            totalLen  = testCase.N_FRAMES * period + 50;
            [vec, edges] = testCase.makePulseTrain(intervals, ...
                testCase.PULSE_WIDTH, totalLen, 10);

            [starts, rateHz] = tfp.io.decodeFrameClock(vec, testCase.SAMPLE_RATE);

            testCase.verifyClass(starts, 'uint64');
            testCase.verifySize(starts, [testCase.N_FRAMES, 1]);
            testCase.verifyEqual(double(starts(:)'), edges, ...
                'every rising edge sample index must be recovered exactly');
            testCase.verifyEqual(rateHz, testCase.FRAME_RATE, 'AbsTol', 1e-9);
        end

        function widePulses_oneEdgePerPulse(testCase)
            % A 5-sample-wide high should produce one rising edge, not five.
            period = 100;
            intervals = period * ones(1, 20);
            [vec, edges] = testCase.makePulseTrain(intervals, 5, 100*22, 7);

            starts = tfp.io.decodeFrameClock(vec, testCase.SAMPLE_RATE);

            testCase.verifyEqual(numel(starts), 20);
            testCase.verifyEqual(double(starts(:)'), edges);
        end

        function jitteredPulses_medianStillRecoversRate(testCase)
            period = 100;
            rng(42);
            jitter = randi([-3, 3], 1, testCase.N_FRAMES);   % ±3 samples
            intervals = period + jitter;
            totalLen = sum(intervals) + 50;
            [vec, edges] = testCase.makePulseTrain(intervals, ...
                testCase.PULSE_WIDTH, totalLen, 5);

            [starts, rateHz] = tfp.io.decodeFrameClock(vec, testCase.SAMPLE_RATE);

            testCase.verifyEqual(numel(starts), testCase.N_FRAMES, ...
                'jitter must not change edge count');
            testCase.verifyEqual(double(starts(:)'), edges);
            % Median of small symmetric jitter around 100 should be ~100.
            testCase.verifyEqual(rateHz, testCase.FRAME_RATE, 'AbsTol', 50);
        end

        function missingPulses_medianStillRecoversRate(testCase)
            % Drop 10% of pulses by doubling their preceding interval.
            period = 100;
            n = testCase.N_FRAMES;
            intervals = period * ones(1, n);
            rng(7);
            dropIdx = randperm(n-1, round(0.1*n));
            intervals(dropIdx) = 2 * period;   % gap doubles where a pulse is missing
            totalLen = sum(intervals) + 50;
            [vec, ~] = testCase.makePulseTrain(intervals, ...
                testCase.PULSE_WIDTH, totalLen, 5);

            [starts, rateHz] = tfp.io.decodeFrameClock(vec, testCase.SAMPLE_RATE);

            % Only the non-dropped edges remain; the doubled gaps are
            % outliers that median should reject.
            testCase.verifyEqual(numel(starts), n, ...
                'edge count equals the constructed edge count');
            testCase.verifyEqual(rateHz, testCase.FRAME_RATE, 'AbsTol', 1e-9, ...
                'median interval must equal one period despite missing pulses');
        end

        function invertedPolarity_recoveredByFallingAndAuto(testCase)
            % Idle-high signal with brief low dips: 'falling' aligns to the
            % onset of each low pulse, and 'auto' must pick that polarity
            % because the line is predominantly high.
            period = 100;
            intervals = period * ones(1, 30);
            [vecHi, ~] = testCase.makePulseTrain(intervals, 1, 100*32, 10);
            vecInv = ~vecHi;   % idle high, dip low for one sample per pulse

            [startsFalling, rateFalling] = tfp.io.decodeFrameClock( ...
                vecInv, testCase.SAMPLE_RATE, 'Polarity', 'falling');
            testCase.verifyEqual(numel(startsFalling), 30);
            testCase.verifyEqual(rateFalling, testCase.FRAME_RATE, 'AbsTol', 1e-9);

            [startsAuto, rateAuto] = tfp.io.decodeFrameClock( ...
                vecInv, testCase.SAMPLE_RATE, 'Polarity', 'auto');
            testCase.verifyEqual(startsAuto, startsFalling, ...
                'auto must pick falling when line is predominantly high');
            testCase.verifyEqual(rateAuto, rateFalling, 'AbsTol', 1e-9);
        end

        function polarityAuto_picksRisingForLowDuty(testCase)
            % Standard low-idle / short-high pulses: 'auto' must agree with
            % 'rising'.
            period = 100;
            intervals = period * ones(1, 30);
            [vec, ~] = testCase.makePulseTrain(intervals, 1, 100*32, 10);

            startsRising = tfp.io.decodeFrameClock(vec, testCase.SAMPLE_RATE);
            startsAuto   = tfp.io.decodeFrameClock(vec, testCase.SAMPLE_RATE, ...
                'Polarity', 'auto');

            testCase.verifyEqual(startsAuto, startsRising);
        end

        function logicalAndNumericInputs_treatedTheSame(testCase)
            period = 100;
            intervals = period * ones(1, 20);
            [vec, ~] = testCase.makePulseTrain(intervals, 1, 100*22, 3);

            sLogical = tfp.io.decodeFrameClock(vec, testCase.SAMPLE_RATE);
            sDouble  = tfp.io.decodeFrameClock(double(vec), testCase.SAMPLE_RATE);
            sUint8   = tfp.io.decodeFrameClock(uint8(vec), testCase.SAMPLE_RATE);

            testCase.verifyEqual(sLogical, sDouble);
            testCase.verifyEqual(sLogical, sUint8);
        end

        function noEdges_returnsEmptyAndNaN(testCase)
            vec = false(5000, 1);
            [starts, rateHz] = tfp.io.decodeFrameClock(vec, testCase.SAMPLE_RATE);

            testCase.verifyClass(starts, 'uint64');
            testCase.verifyEqual(size(starts), [0, 1]);
            testCase.verifyTrue(isnan(rateHz));
        end

        function singleEdge_returnsOneIndexAndNaN(testCase)
            vec = false(1000, 1);
            vec(500) = true;
            [starts, rateHz] = tfp.io.decodeFrameClock(vec, testCase.SAMPLE_RATE);

            testCase.verifyEqual(starts, uint64(500));
            testCase.verifyTrue(isnan(rateHz), ...
                'frameRateHz must be NaN when fewer than two edges are seen');
        end

        function edgeAtFirstSample_isDetected(testCase)
            % Signal that is already high at sample 1: rising edge at 1.
            vec = false(200, 1);
            vec(1:3)   = true;     % first edge at sample 1
            vec(101:103) = true;   % second edge at sample 101
            starts = tfp.io.decodeFrameClock(vec, testCase.SAMPLE_RATE);

            testCase.verifyEqual(double(starts(:)'), [1, 101]);
        end

        function rowVectorInput_acceptedAndReturnsColumn(testCase)
            period = 100;
            intervals = period * ones(1, 10);
            [vec, edges] = testCase.makePulseTrain(intervals, 1, 100*12, 5);
            rowVec = vec(:)';

            starts = tfp.io.decodeFrameClock(rowVec, testCase.SAMPLE_RATE);

            testCase.verifySize(starts, [10, 1]);
            testCase.verifyEqual(double(starts(:)'), edges);
        end

        function badSampleRate_throws(testCase)
            vec = false(100, 1);
            testCase.verifyError( ...
                @() tfp.io.decodeFrameClock(vec, 0), ...
                'MATLAB:validators:mustBePositive');
            testCase.verifyError( ...
                @() tfp.io.decodeFrameClock(vec, -1), ...
                'MATLAB:validators:mustBePositive');
        end

        function badPolarity_throws(testCase)
            vec = false(100, 1);
            testCase.verifyError( ...
                @() tfp.io.decodeFrameClock(vec, 1000, 'Polarity', 'sideways'), ...
                'MATLAB:validators:mustBeMember');
        end

        function nonVectorInput_throws(testCase)
            mat = false(10, 10);
            testCase.verifyError( ...
                @() tfp.io.decodeFrameClock(mat, testCase.SAMPLE_RATE), ...
                'tfp:io:decodeFrameClock:badShape');
        end

    end
end
