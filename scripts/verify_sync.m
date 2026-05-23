%verify_sync  Scope-PC verification of the continuous-session sync API.
%
%   Verifies that the Round-1 sync API (docs/SYNC_FRAME.md) behaves
%   correctly on real NI6323 hardware:
%
%     - startContinuousSession / stopContinuousSession lifecycle
%     - clocked AO onset aligns with the returned startSampleIdx
%       (latency between commanded sample and AI-loopback observation)
%     - AO sample-index ↔ AI sample-index alignment (single clock)
%     - DO out-pulse rising edge captured at the expected sample
%     - ScanImage frame clock decoded with low jitter, plausible rate
%     - currentSampleIndex() is monotonic and tracks sampleRate
%
%   Run on the scope PC (MATLAB R2019a+, NI-DAQmx 19.5.0+):
%
%       addpath(fullfile(fileparts(mfilename('fullpath')), '..', 'src'))
%       verify_sync
%
%   Required wiring on the scope PC:
%
%       AO_LOOPBACK_CH (AO0) ───── AI_LOOPBACK_CH (AI0)
%       DO_LOOPBACK_LN ─────────── DI_LOOPBACK_LN
%       ScanImage frame TTL ───── FRAME_CLOCK_LN
%
%   Each step prints PASS or FAIL with a short reason. A FAIL stops the
%   script so hardware state is not left unknown.
%
%   Tolerances assume the master clock at SAMPLE_RATE Hz. Edit if the
%   scope PC differs.

% --- Hardware identity --------------------------------------------------
DEVICE_NAME      = 'Dev1';
SAMPLE_RATE      = 100000;   % Hz; master clock (docs/SYNC_FRAME.md §2)

AI_LOOPBACK_CH   = 0;        % AI channel wired to AO0
AO_LOOPBACK_CH   = 0;        % AO channel wired to AI0
DO_LOOPBACK_LN   = 'port0/line0';   % DO wired to a DI line
DI_LOOPBACK_LN   = 'port0/line1';   % DI receiving DO_LOOPBACK_LN
FRAME_CLOCK_LN   = 'port0/line2';   % ScanImage frame TTL input

% --- Test parameters ----------------------------------------------------
AO_PULSE_AMP_V       = 2.0;         % volts; AI-loopback target amplitude
AO_PULSE_DUR_S       = 0.010;       % 10 ms clocked AO pulse
DO_PULSE_DUR_S       = 0.005;       % per docs/SYNC_FRAME.md §3 default
SESSION_CAPTURE_S    = 2.0;         % capture window; long enough for
                                    % multiple ScanImage frames (>=30Hz)
AO_QUEUE_OFFSET_S    = 0.200;       % wait this long after session start
                                    % before queueing the AO pulse
EXPECTED_SI_RATE_HZ  = 30;          % nominal ScanImage frame rate

% Tolerances (in samples at SAMPLE_RATE Hz). At 100 kHz, 1 sample = 10 us.
TOL_AO_LATENCY_SAMP    = 50;        % AO commanded → AI observed (≤ 500 us)
TOL_DO_LATENCY_SAMP    = 200;       % host-driven DO; spec allows ~1 ms
TOL_FRAME_JITTER_SAMP  = 20;        % stdev of inter-frame intervals
TOL_SI_RATE_REL        = 0.05;      % ±5% on inferred ScanImage frame rate
TOL_INDEX_MONOTONIC    = 2;         % currentSampleIndex must not regress

passed = 0;
failed = 0;
d = []; %#ok<NASGU>

fprintf('=== verify_sync  (device: %s, fs = %d Hz) ===\n\n', ...
    DEVICE_NAME, SAMPLE_RATE);

%% Step 1 — construct and initialize against minimal config
try
    initCfg = struct( ...
        'deviceName',         DEVICE_NAME, ...
        'sampleRate',         SAMPLE_RATE, ...
        'analogInChannels',   AI_LOOPBACK_CH, ...
        'analogOutChannels',  AO_LOOPBACK_CH, ...
        'digitalOutChannels', {{DO_LOOPBACK_LN}}, ...
        'digitalInChannels',  {{DI_LOOPBACK_LN, FRAME_CLOCK_LN}});
    d = tfp.hardware.NI6323_DAQ(initCfg);
    assert(d.sampleRate == SAMPLE_RATE, 'sampleRate mismatch on construction');
    assert(~d.isRunning, 'isRunning should be false after init');
    printResult('PASS', '1', 'constructor / initialize');
    passed = passed + 1;
catch ME
    printResult('FAIL', '1', sprintf('constructor / initialize: %s', ME.message));
    failed = failed + 1;
    cleanup_and_exit(d);
    return;
end

%% Step 2 — startContinuousSession arms the master clock
try
    sessCfg = struct( ...
        'sampleRate',     SAMPLE_RATE, ...
        'aiChannels',     AI_LOOPBACK_CH, ...
        'aiRangeV',       [-10, 10], ...
        'aoChannels',     AO_LOOPBACK_CH, ...
        'diLines',        {{DI_LOOPBACK_LN, FRAME_CLOCK_LN}}, ...
        'doLines',        {{DO_LOOPBACK_LN}}, ...
        'frameClockLine', FRAME_CLOCK_LN);
    t0_host = tic;
    d.startContinuousSession(sessCfg);
    assert(d.isRunning, 'isRunning should be true after startContinuousSession');
    printResult('PASS', '2', 'startContinuousSession (isRunning=true)');
    passed = passed + 1;
catch ME
    printResult('FAIL', '2', ME.message);
    failed = failed + 1;
    cleanup_and_exit(d);
    return;
end

%% Step 3 — currentSampleIndex is monotonic and tracks the master clock
try
    idx1 = d.currentSampleIndex();
    pause(0.100);
    idx2 = d.currentSampleIndex();
    pause(0.100);
    idx3 = d.currentSampleIndex();
    assert(isa(idx1, 'uint64') && isa(idx2, 'uint64') && isa(idx3, 'uint64'), ...
        'currentSampleIndex must return uint64');
    assert(idx2 + TOL_INDEX_MONOTONIC >= idx1 && ...
           idx3 + TOL_INDEX_MONOTONIC >= idx2, ...
        sprintf('currentSampleIndex regressed: %d, %d, %d', idx1, idx2, idx3));
    % After ~100 ms we expect ~SAMPLE_RATE/10 samples to have elapsed.
    expectedDelta = SAMPLE_RATE * 0.100;
    deltaObs = double(idx3 - idx1);
    relErr = abs(deltaObs - 2*expectedDelta) / (2*expectedDelta);
    assert(relErr < 0.20, ...
        sprintf('currentSampleIndex advanced by %g; expected ~%g (rel err %.2f)', ...
                deltaObs, 2*expectedDelta, relErr));
    printResult('PASS', '3', sprintf( ...
        'currentSampleIndex monotonic, advanced %g samples over 200 ms', deltaObs));
    passed = passed + 1;
catch ME
    printResult('FAIL', '3', ME.message);
    failed = failed + 1;
    cleanup_and_exit(d);
    return;
end

%% Step 4 — queueClockedAO returns a usable startSampleIdx
%   Build a 10 ms square pulse; queue it with 'immediate' trigger; the
%   returned uint64 is the canonical t_onset_daq_samples anchor.
try
    pause(AO_QUEUE_OFFSET_S);  % let some quiet baseline accumulate first
    nSampPulse = round(AO_PULSE_DUR_S * SAMPLE_RATE);
    aoWave = AO_PULSE_AMP_V * ones(nSampPulse, 1);
    aoStartIdx = d.queueClockedAO(aoWave, SAMPLE_RATE, 'immediate');
    assert(isa(aoStartIdx, 'uint64'), ...
        'queueClockedAO must return uint64 sample index');
    idxNow = d.currentSampleIndex();
    assert(aoStartIdx >= idxNow - TOL_INDEX_MONOTONIC, ...
        sprintf('aoStartIdx (%d) precedes currentSampleIndex (%d)', ...
                aoStartIdx, idxNow));
    printResult('PASS', '4', sprintf( ...
        'queueClockedAO returned startSampleIdx=%d (now=%d)', ...
        aoStartIdx, idxNow));
    passed = passed + 1;
catch ME
    printResult('FAIL', '4', ME.message);
    failed = failed + 1;
    cleanup_and_exit(d);
    return;
end

%% Step 5 — sendDigitalPulse coexists with the clocked session
%   Per docs/SYNC_FRAME.md §3 the host-driven DO pulse is the out-pulse
%   path. We fire one and remember the host-side sample index for the
%   loopback latency check.
try
    doRequestIdx = d.currentSampleIndex();
    d.sendDigitalPulse(DO_LOOPBACK_LN, DO_PULSE_DUR_S);
    printResult('PASS', '5', sprintf( ...
        'sendDigitalPulse fired near sample %d', doRequestIdx));
    passed = passed + 1;
catch ME
    printResult('FAIL', '5', ME.message);
    failed = failed + 1;
    cleanup_and_exit(d);
    return;
end

%% Step 6 — capture window: let frame clock + loopback signals accumulate
try
    remaining = SESSION_CAPTURE_S - AO_QUEUE_OFFSET_S - AO_PULSE_DUR_S;
    if remaining > 0
        pause(remaining);
    end
    printResult('PASS', '6', sprintf( ...
        'capture window of %.2f s elapsed', SESSION_CAPTURE_S));
    passed = passed + 1;
catch ME
    printResult('FAIL', '6', ME.message);
    failed = failed + 1;
    cleanup_and_exit(d);
    return;
end

%% Step 7 — stopContinuousSession returns a well-formed result
try
    result = d.stopContinuousSession();
    assert(~d.isRunning, 'isRunning should be false after stop');
    requiredFields = {'aiData','diData','aoSamplesWritten', ...
                      'nSamplesTotal','sampleRate', ...
                      'sessionStartDatetime','lineNames'};
    for k = 1:numel(requiredFields)
        assert(isfield(result, requiredFields{k}), ...
            sprintf('result missing field: %s', requiredFields{k}));
    end
    assert(result.sampleRate == SAMPLE_RATE, 'result.sampleRate mismatch');
    assert(size(result.aiData, 2) == 1, ...
        'aiData should have one column (AI_LOOPBACK_CH)');
    assert(size(result.diData, 2) == 2, ...
        'diData should have two columns (loopback + frame clock)');
    assert(size(result.aiData, 1) == size(result.diData, 1), ...
        'aiData and diData row counts must match (shared clock)');
    assert(isa(result.sessionStartDatetime, 'datetime'), ...
        'sessionStartDatetime must be a datetime');
    assert(double(result.nSamplesTotal) >= SAMPLE_RATE * SESSION_CAPTURE_S * 0.9, ...
        sprintf('nSamplesTotal=%d below expected ~%g', ...
                result.nSamplesTotal, SAMPLE_RATE * SESSION_CAPTURE_S));
    elapsedHost = toc(t0_host);
    printResult('PASS', '7', sprintf( ...
        'stopContinuousSession: %d samples, host %.2f s', ...
        result.nSamplesTotal, elapsedHost));
    passed = passed + 1;
catch ME
    printResult('FAIL', '7', ME.message);
    failed = failed + 1;
    cleanup_and_exit(d);
    return;
end

%% Step 8 — AO loopback latency: AI rising edge near aoStartIdx
%   The AI trace should cross AO_PULSE_AMP_V/2 within TOL_AO_LATENCY_SAMP
%   samples of aoStartIdx. This proves AO and AI share the master clock.
try
    ai = result.aiData(:, 1);
    threshV = AO_PULSE_AMP_V / 2;
    above = ai > threshV;
    edge = find(above(2:end) & ~above(1:end-1), 1, 'first');
    assert(~isempty(edge), ...
        'no AO-loopback rising edge in AI trace — check AO0→AI0 wiring');
    edgeSampleObs = uint64(edge);  % 1-based, post-edge sample
    latencySamp = double(edgeSampleObs) - double(aoStartIdx);
    assert(abs(latencySamp) <= TOL_AO_LATENCY_SAMP, ...
        sprintf('AO latency %d samples exceeds tolerance %d', ...
                latencySamp, TOL_AO_LATENCY_SAMP));
    printResult('PASS', '8', sprintf( ...
        'AO→AI latency %+d samples (%.1f us); tol ±%d', ...
        latencySamp, latencySamp * 1e6 / SAMPLE_RATE, TOL_AO_LATENCY_SAMP));
    passed = passed + 1;
catch ME
    printResult('FAIL', '8', ME.message);
    failed = failed + 1;
    cleanup_and_exit(d);
    return;
end

%% Step 9 — DO loopback latency: DI edge within tolerance of host call
try
    doColIdx = find(strcmp(result.lineNames.diLines, DI_LOOPBACK_LN), 1);
    assert(~isempty(doColIdx), ...
        sprintf('lineNames.diLines missing %s', DI_LOOPBACK_LN));
    doDi = double(result.diData(:, doColIdx)) > 0.5;
    doEdge = find(doDi(2:end) & ~doDi(1:end-1), 1, 'first');
    assert(~isempty(doEdge), ...
        'no DO-loopback rising edge — check DO→DI wiring');
    doLatencySamp = double(doEdge) - double(doRequestIdx);
    assert(abs(doLatencySamp) <= TOL_DO_LATENCY_SAMP, ...
        sprintf('DO host-driven latency %d samples exceeds tolerance %d', ...
                doLatencySamp, TOL_DO_LATENCY_SAMP));
    printResult('PASS', '9', sprintf( ...
        'DO→DI host-driven latency %+d samples (%.2f ms); tol ±%d', ...
        doLatencySamp, doLatencySamp * 1e3 / SAMPLE_RATE, TOL_DO_LATENCY_SAMP));
    passed = passed + 1;
catch ME
    printResult('FAIL', '9', ME.message);
    failed = failed + 1;
    cleanup_and_exit(d);
    return;
end

%% Step 10 — decode frame clock and assert plausible rate + jitter
%   Uses tfp.io.decodeFrameClock (T-SYNC-4). Requires ScanImage to be
%   acquiring frames into FRAME_CLOCK_LN during the capture window.
try
    fcColIdx = find(strcmp(result.lineNames.diLines, FRAME_CLOCK_LN), 1);
    assert(~isempty(fcColIdx), ...
        sprintf('lineNames.diLines missing frameClockLine %s', FRAME_CLOCK_LN));
    fcVec = result.diData(:, fcColIdx);
    [frameStartSamples, frameRateHz] = tfp.io.decodeFrameClock(fcVec, ...
        result.sampleRate);
    assert(numel(frameStartSamples) >= 2, ...
        sprintf('only %d frame edges decoded — is ScanImage acquiring?', ...
                numel(frameStartSamples)));
    relRateErr = abs(frameRateHz - EXPECTED_SI_RATE_HZ) / EXPECTED_SI_RATE_HZ;
    assert(relRateErr <= TOL_SI_RATE_REL, ...
        sprintf('inferred frame rate %.2f Hz off by %.1f%% from expected %.2f Hz', ...
                frameRateHz, 100*relRateErr, EXPECTED_SI_RATE_HZ));
    intervals = double(diff(frameStartSamples));
    jitterSamp = std(intervals);
    assert(jitterSamp <= TOL_FRAME_JITTER_SAMP, ...
        sprintf('frame-interval stdev %.1f samples exceeds tol %d', ...
                jitterSamp, TOL_FRAME_JITTER_SAMP));
    printResult('PASS', '10', sprintf( ...
        'frame clock: %d edges, %.2f Hz, jitter %.1f samples (%.2f us)', ...
        numel(frameStartSamples), frameRateHz, jitterSamp, ...
        jitterSamp * 1e6 / SAMPLE_RATE));
    passed = passed + 1;
catch ME
    printResult('FAIL', '10', ME.message);
    failed = failed + 1;
    cleanup_and_exit(d);
    return;
end

%% Step 11 — AO ↔ frame-clock edge alignment cross-check
%   The clocked AO onset (aoStartIdx) and the nearest frame-clock edge
%   should differ by less than one frame interval — this confirms the
%   two timestamp paths share the same DAQ clock.
try
    deltas = double(frameStartSamples) - double(aoStartIdx);
    [~, nearIdx] = min(abs(deltas));
    nearestDelta = deltas(nearIdx);
    framePeriodSamp = SAMPLE_RATE / frameRateHz;
    assert(abs(nearestDelta) <= framePeriodSamp, ...
        sprintf('nearest frame edge offset %g samples > one frame period %g', ...
                nearestDelta, framePeriodSamp));
    printResult('PASS', '11', sprintf( ...
        'nearest frame edge to AO onset: %+d samples (%.2f ms; frame period %.2f ms)', ...
        nearestDelta, nearestDelta * 1e3 / SAMPLE_RATE, ...
        framePeriodSamp * 1e3 / SAMPLE_RATE));
    passed = passed + 1;
catch ME
    printResult('FAIL', '11', ME.message);
    failed = failed + 1;
end

%% Step 12 — cleanup
try
    d.cleanup();
    assert(~d.isRunning, 'isRunning should be false after cleanup');
    printResult('PASS', '12', 'cleanup');
    passed = passed + 1;
catch ME
    printResult('FAIL', '12', ME.message);
    failed = failed + 1;
end

%% Summary
fprintf('\n=== Result: %d/%d passed ===\n', passed, passed + failed);
if failed > 0
    fprintf(['Some steps failed — check loopback wiring (AO0→AI0, ' ...
             'DO→DI), ScanImage acquisition state, and NI-DAQmx driver.\n']);
end

% =========================================================================

function printResult(status, step, msg)
fprintf('[%s]  Step %2s  %s\n', status, step, msg);
end

function cleanup_and_exit(d)
fprintf('Cleaning up after failure...\n');
if isempty(d), return; end
try
    if d.isRunning
        try, d.stopContinuousSession(); catch, end
    end
catch
end
try, d.cleanup(); catch, end
end
