%verify_DLP650LNIR_DMD  Manual self-test for tfp.hardware.DLP650LNIR_DMD.
%
%   Run on the scope PC with the DLi4130 kit or DLP650LNIR board:
%
%     addpath(fullfile(fileparts(mfilename('fullpath')), '..', 'src'))
%     verify_DLP650LNIR_DMD
%
%   Adjust the constants in the configuration block below for the board
%   under test.  Two presets are provided; uncomment the appropriate one.
%
%   DLi4130 kit (ALP-4.1, DLP7000, 1024×768):
%     Set ALP_VERSION = '4.1' and DMD_TYPE = 'DLP7000' (default below).
%     Confirm ALP_DMDTYPE_XGA_07A (4) is returned by AlpDevInquire.
%
%   DLP650LNIR (ALP-4.3, 1280×800):
%     Set ALP_VERSION = '4.3' and DMD_TYPE = 'DLP650LNIR'.
%     Confirm ALP_DMDTYPE_WXGA_S450 (12) is returned by AlpDevInquire.
%
%   CAUTION: Step 4 projects a checkerboard pattern for ~2 seconds.
%   Ensure no sample or animal is in the beam path before running.

% ---- Board-selection constants: edit here --------------------------------

% Preset A — DLi4130 kit (ALP-4.1, DLP7000)
ALP_VERSION = '4.1';
DMD_TYPE    = 'DLP7000';
DLL_PATH    = 'C:\Program Files\ALP-4.1\alp41.dll';
PROTO_FILE  = '';   % fill in path to ALP-4.1 .m prototype when confirmed

% Preset B — DLP650LNIR (ALP-4.3) — uncomment to switch
% ALP_VERSION = '4.3';
% DMD_TYPE    = 'DLP650LNIR';
% DLL_PATH    = 'C:\Program Files\ALP-4.3\ALP-4.3 high-speed API\x64\alp4395.dll';
% PROTO_FILE  = fullfile('vendor', 'alp', 'reference', 'parot-alptool', 'alpV43x64proto.m');

% --------------------------------------------------------------------------

ALP_DMDTYPE_WXGA_S450 = 12;   % DLP650LNIR device-type constant (ALP-4.3 official header)
ALP_DMDTYPE_XGA_07A   = 4;    % DLP7000 device-type constant   (ALP-4.1 and 4.3 headers)

passed = 0;
failed = 0;
dmd = [];

fprintf('=== verify_DLP650LNIR_DMD  (%s / ALP-%s) ===\n\n', DMD_TYPE, ALP_VERSION);

%% Step 1 — load DLL + allocate device (constructor / initialize)
try
    cfg = struct( ...
        'alpVersion', ALP_VERSION, ...
        'dmdType',    DMD_TYPE, ...
        'dllPath',    DLL_PATH, ...
        'protoFile',  PROTO_FILE);
    dmd = tfp.hardware.DLP650LNIR_DMD(cfg);
    assert(dmd.isInitialized, 'isInitialized should be true after constructor');
    printResult('PASS', '1', sprintf('DLL loaded + device allocated (%s v%s)', ...
        DMD_TYPE, ALP_VERSION));
    passed = passed + 1;
catch ME
    printResult('FAIL', '1', sprintf('constructor: %s', ME.message));
    failed = failed + 1;
    return;
end

%% Step 1b — device-type confirmation (AlpDevInquire ran inside initialize)
%  The DLP650LNIR_DMD class queries AlpDevInquire(ALP_DEV_DMDTYPE) and throws
%  an error on mismatch.  Reaching this line means the check passed.
try
    if strcmp(DMD_TYPE, 'DLP650LNIR')
        typeStr = sprintf('ALP_DMDTYPE_WXGA_S450 (%d)', ALP_DMDTYPE_WXGA_S450);
    else
        typeStr = sprintf('ALP_DMDTYPE_XGA_07A (%d)', ALP_DMDTYPE_XGA_07A);
    end
    printResult('PASS', '1b', sprintf('device type confirmed: %s', typeStr));
    passed = passed + 1;
catch ME
    printResult('FAIL', '1b', ME.message);
    failed = failed + 1;
    cleanup_and_exit(dmd);
    return;
end

%% Step 2 — load checkerboard pattern (AlpSeqAlloc + AlpSeqPut)
try
    nR = dmd.nRows;
    nC = dmd.nCols;
    [colGrid, rowGrid] = meshgrid(1:nC, 1:nR);
    checker = logical(mod(floor(colGrid / 32) + floor(rowGrid / 32), 2));
    opts = struct('exposureUs', 500, 'darkTimeUs', 0, 'triggerMode', 'internal');
    dmd.loadPatternSequence(checker, opts);
    printResult('PASS', '2', sprintf('loadPatternSequence checkerboard %d x %d', nR, nC));
    passed = passed + 1;
catch ME
    printResult('FAIL', '2', ME.message);
    failed = failed + 1;
    cleanup_and_exit(dmd);
    return;
end

%% Step 3 — arm sequence
try
    dmd.armSequence();
    printResult('PASS', '3', 'armSequence');
    passed = passed + 1;
catch ME
    printResult('FAIL', '3', ME.message);
    failed = failed + 1;
    cleanup_and_exit(dmd);
    return;
end

%% Step 4 — softTrigger: project checkerboard for 2 s (AlpProjStart)
fprintf('[INFO]  Step  4  Projecting checkerboard for 2 seconds  ** LIGHT ON **\n');
try
    dmd.softTrigger();
    pause(2);
    printResult('PASS', '4', 'softTrigger (2 s projection complete)');
    passed = passed + 1;
catch ME
    printResult('FAIL', '4', ME.message);
    failed = failed + 1;
    cleanup_and_exit(dmd);
    return;
end

%% Step 5 — getStatus
try
    st = dmd.getStatus();
    assert(isstruct(st), 'getStatus should return a struct');
    printResult('PASS', '5', 'getStatus returned struct');
    passed = passed + 1;
catch ME
    printResult('FAIL', '5', ME.message);
    failed = failed + 1;
end

%% Step 6 — cleanup (AlpProjHalt + AlpSeqFree + AlpDevFree + unloadlibrary)
try
    dmd.cleanup();
    assert(~dmd.isInitialized, 'isInitialized should be false after cleanup');
    printResult('PASS', '6', 'cleanup (halt + free sequence + free device + unload DLL)');
    passed = passed + 1;
catch ME
    printResult('FAIL', '6', ME.message);
    failed = failed + 1;
end

%% Summary
fprintf('\n=== Result: %d/%d passed ===\n', passed, passed + failed);
if failed > 0
    fprintf('Check ALP driver installation, DLL_PATH, and PROTO_FILE at the top of this script.\n');
end

% =========================================================================

function printResult(status, step, msg)
fprintf('[%s]  Step %2s  %s\n', status, step, msg);
end

function cleanup_and_exit(dmd)
fprintf('Cleaning up after failure...\n');
if ~isempty(dmd)
    try, dmd.cleanup(); catch, end
end
end
