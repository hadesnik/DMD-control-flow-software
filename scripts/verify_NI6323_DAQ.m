%verify_NI6323_DAQ  Manual self-test for tfp.hardware.NI6323_DAQ.
%
%   Run on the scope PC (MATLAB R2019a, NI-DAQmx 19.5.0):
%
%     addpath(fullfile(fileparts(mfilename('fullpath')), '..', 'src'))
%     verify_NI6323_DAQ
%
%   Each step prints PASS or FAIL with a short reason.
%   A FAIL stops the script so the hardware state is not left unknown.
%
%   Adjust DEVICE_NAME and CHANNELS below if the scope PC differs from
%   the defaults.

DEVICE_NAME = 'Dev1';
AI_CH       = 0;          % analog input channel number
AO_CH       = 0;          % analog output channel number
DO_LINE     = 'port0/line0';  % digital output line
SAMPLE_RATE = 10000;      % Hz
N_SAMPLES   = 1000;

passed = 0;
failed = 0;

fprintf('=== verify_NI6323_DAQ  (device: %s) ===\n\n', DEVICE_NAME);

%% Step 1 — constructor and initialize
try
    cfg = struct( ...
        'deviceName',        DEVICE_NAME, ...
        'sampleRate',        SAMPLE_RATE, ...
        'analogInChannels',  AI_CH, ...
        'analogOutChannels', AO_CH, ...
        'digitalOutChannels', {{DO_LINE}});
    d = tfp.hardware.NI6323_DAQ(cfg);
    assert(d.sampleRate == SAMPLE_RATE, 'sampleRate mismatch');
    assert(~d.isRunning, 'isRunning should be false after init');
    printResult('PASS', '1', 'constructor / initialize');
    passed = passed + 1;
catch ME
    printResult('FAIL', '1', sprintf('constructor / initialize: %s', ME.message));
    failed = failed + 1;
    cleanup_and_exit(d);
    return;
end

%% Step 2 — configureAnalogInput
try
    d.configureAnalogInput(AI_CH, [-10, 10]);
    printResult('PASS', '2', 'configureAnalogInput');
    passed = passed + 1;
catch ME
    printResult('FAIL', '2', ME.message);
    failed = failed + 1;
    cleanup_and_exit(d);
    return;
end

%% Step 3 — configureAnalogOutput
try
    d.configureAnalogOutput(AO_CH);
    printResult('PASS', '3', 'configureAnalogOutput');
    passed = passed + 1;
catch ME
    printResult('FAIL', '3', ME.message);
    failed = failed + 1;
    cleanup_and_exit(d);
    return;
end

%% Step 4 — configureDigitalOutput
try
    d.configureDigitalOutput({DO_LINE});
    printResult('PASS', '4', 'configureDigitalOutput');
    passed = passed + 1;
catch ME
    printResult('FAIL', '4', ME.message);
    failed = failed + 1;
    cleanup_and_exit(d);
    return;
end

%% Step 5 — queueAnalogOutput
try
    aoData = zeros(N_SAMPLES, 1);  % flat zero waveform
    d.queueAnalogOutput(aoData);
    printResult('PASS', '5', 'queueAnalogOutput');
    passed = passed + 1;
catch ME
    printResult('FAIL', '5', ME.message);
    failed = failed + 1;
    cleanup_and_exit(d);
    return;
end

%% Step 6 — queueDigitalPulses
try
    d.queueDigitalPulses({DO_LINE}, 0.05, 0.010);
    printResult('PASS', '6', 'queueDigitalPulses');
    passed = passed + 1;
catch ME
    printResult('FAIL', '6', ME.message);
    failed = failed + 1;
    cleanup_and_exit(d);
    return;
end

%% Step 7 — start
try
    d.start();
    assert(d.isRunning, 'isRunning should be true after start()');
    printResult('PASS', '7', 'start (isRunning=true)');
    passed = passed + 1;
catch ME
    printResult('FAIL', '7', ME.message);
    failed = failed + 1;
    cleanup_and_exit(d);
    return;
end

%% Step 8 — readAnalogInput (multi-sample, listener path)
try
    ai = d.readAnalogInput(N_SAMPLES);
    assert(size(ai, 1) == N_SAMPLES, 'row count mismatch');
    assert(size(ai, 2) == 1,         'col count should be 1');
    assert(isnumeric(ai),            'data should be numeric');
    printResult('PASS', '8', sprintf('readAnalogInput(%d) shape %dx%d', ...
        N_SAMPLES, size(ai,1), size(ai,2)));
    passed = passed + 1;
catch ME
    printResult('FAIL', '8', ME.message);
    failed = failed + 1;
    cleanup_and_exit(d);
    return;
end

%% Step 9 — stop
try
    d.stop();
    assert(~d.isRunning, 'isRunning should be false after stop()');
    printResult('PASS', '9', 'stop (isRunning=false)');
    passed = passed + 1;
catch ME
    printResult('FAIL', '9', ME.message);
    failed = failed + 1;
    cleanup_and_exit(d);
    return;
end

%% Step 10 — readAnalogInput single-sample path
try
    d.queueAnalogOutput(zeros(N_SAMPLES, 1));
    d.start();
    ai1 = d.readAnalogInput(1);
    assert(size(ai1, 1) == 1 && size(ai1, 2) == 1, 'shape should be 1×1');
    d.stop();
    printResult('PASS', '10', 'readAnalogInput(1) single-scan path');
    passed = passed + 1;
catch ME
    printResult('FAIL', '10', ME.message);
    failed = failed + 1;
    cleanup_and_exit(d);
    return;
end

%% Step 11 — sendDigitalPulse
try
    d.sendDigitalPulse(DO_LINE, 0.001);  % 1 ms pulse
    printResult('PASS', '11', 'sendDigitalPulse (1 ms)');
    passed = passed + 1;
catch ME
    printResult('FAIL', '11', ME.message);
    failed = failed + 1;
    cleanup_and_exit(d);
    return;
end

%% Step 12 — getLog
try
    lg = d.getLog();
    assert(isstruct(lg),    'log should be a struct array');
    assert(isfield(lg, 'timestamp'), 'log missing timestamp field');
    assert(isfield(lg, 'eventType'), 'log missing eventType field');
    assert(numel(lg) >= 9,  'expected at least 9 log entries');
    printResult('PASS', '12', sprintf('getLog (%d entries)', numel(lg)));
    passed = passed + 1;
catch ME
    printResult('FAIL', '12', ME.message);
    failed = failed + 1;
end

%% Step 13 — cleanup
try
    d.cleanup();
    assert(~d.isRunning,    'isRunning should be false after cleanup');
    printResult('PASS', '13', 'cleanup');
    passed = passed + 1;
catch ME
    printResult('FAIL', '13', ME.message);
    failed = failed + 1;
end

%% Summary
fprintf('\n=== Result: %d/%d passed ===\n', passed, passed + failed);
if failed > 0
    fprintf('Some steps failed — check hardware connections and NI-DAQmx driver.\n');
end

% =========================================================================

function printResult(status, step, msg)
fprintf('[%s]  Step %2s  %s\n', status, step, msg);
end

function cleanup_and_exit(d)
fprintf('Cleaning up after failure...\n');
try, d.cleanup(); catch, end
end
