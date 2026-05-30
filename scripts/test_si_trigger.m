%test_si_trigger  Verify the ScanImage acquisition trigger and frame-clock return.
%
%   Run on the DAQ PC with ScanImage armed for external triggering:
%
%       addpath(fullfile(fileparts(mfilename('fullpath')), '..', 'src'))
%       test_si_trigger
%
%   What this does:
%     1. Fires a 10 ms TTL on port0/line10 (ScanImage acquisition trigger).
%     2. Records port0/line1 (ScanImage frame clock return) for 3 seconds.
%     3. Decodes rising edges and reports frame rate and jitter.
%
%   Before running:
%     - ScanImage must be open on the SI PC and armed for external trigger.
%     - The trigger cable (DAQ PC port0/line10 -> SI PC PFI4) must be connected.
%     - The frame-clock return cable (SI PC -> DAQ PC port0/line1) must be connected.

DEVICE_NAME      = 'Dev1';
SAMPLE_RATE      = 100000;   % Hz
CAPTURE_S        = 3.0;
TRIGGER_LINE     = 'port0/line10';
FRAME_CLOCK_LINE = 'port0/line1';
TRIGGER_DUR_S    = 0.010;    % 10 ms trigger pulse
EXPECTED_RATE_HZ = 30;       % nominal ScanImage frame rate

addpath(fullfile(fileparts(mfilename('fullpath')), '..', 'src'));

fprintf('=== ScanImage trigger test ===\n');
fprintf('Trigger out : %s\nFrame clock : %s\nCapture     : %.1f s\n\n', ...
    TRIGGER_LINE, FRAME_CLOCK_LINE, CAPTURE_S);

% --- Step 1: fire the trigger via its own raw NI session -------------------
% NI-DAQmx allows separate sessions on different lines of the same port.
% The trigger session is separate from the capture session.
fprintf('Firing trigger (%.0f ms on %s)...\n', TRIGGER_DUR_S*1e3, TRIGGER_LINE);
try
    sTrig = daq.createSession('ni');
    sTrig.addDigitalChannel(DEVICE_NAME, TRIGGER_LINE, 'OutputOnly');
    sTrig.outputSingleScan(1);
    pause(TRIGGER_DUR_S);
    sTrig.outputSingleScan(0);
    delete(sTrig);
    fprintf('Trigger fired.\n');
catch ME
    fprintf('[FAIL] Could not fire trigger: %s\n', ME.message);
    return;
end

% --- Step 2: capture frame clock with a DI-only foreground session ---------
% startForeground blocks for CAPTURE_S seconds and returns the DI samples.
% ScanImage is already acquiring from the trigger above.
fprintf('Recording frame clock for %.1f s...\n', CAPTURE_S);
try
    sCapture = daq.createSession('ni');
    sCapture.Rate              = SAMPLE_RATE;
    sCapture.DurationInSeconds = CAPTURE_S;
    % NI-DAQmx requires an AI/AO channel to provide the sample clock for DI.
    % ai0 is unwired — used only as a clock source; its data is discarded.
    sCapture.addAnalogInputChannel(DEVICE_NAME, 0, 'Voltage');
    sCapture.addDigitalChannel(DEVICE_NAME, FRAME_CLOCK_LINE, 'InputOnly');
    raw   = sCapture.startForeground();   % nSamples x 2 [ai0, DI], blocking
    fcRaw = raw(:, 2);                    % DI column
    delete(sCapture);
catch ME
    fprintf('[FAIL] DI capture failed: %s\n', ME.message);
    return;
end

% --- Step 3: decode rising edges ------------------------------------------
fcVec  = double(fcRaw(:, 1));
rising = find(fcVec(2:end) > 0.5 & fcVec(1:end-1) <= 0.5);

if numel(rising) < 2
    fprintf('[FAIL] Only %d frame-clock edges detected in %.1f s.\n', ...
        numel(rising), CAPTURE_S);
    fprintf('       Is ScanImage acquiring? Is the frame-clock cable wired to port0/line1?\n');
    return;
end

intervals_s  = double(diff(rising)) / SAMPLE_RATE;
frameRateHz  = 1 / mean(intervals_s);
jitterUs     = std(intervals_s) * 1e6;

fprintf('\n[PASS] Frame clock decoded:\n');
fprintf('  Edges detected  : %d\n',   numel(rising));
fprintf('  Frame rate      : %.2f Hz  (expected ~%.0f Hz)\n', frameRateHz, EXPECTED_RATE_HZ);
fprintf('  Jitter (1-sigma): %.1f us\n', jitterUs);

relErr = abs(frameRateHz - EXPECTED_RATE_HZ) / EXPECTED_RATE_HZ;
if relErr > 0.10
    fprintf('[WARN] Frame rate deviates >10%% from expected %.0f Hz.\n', EXPECTED_RATE_HZ);
end
if jitterUs > 500
    fprintf('[WARN] Frame jitter %.1f us is high.\n', jitterUs);
end
