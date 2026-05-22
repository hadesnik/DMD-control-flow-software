%run_ensemble_fill_factor_power  Fill-factor power experiment on the scope PC.
%
%   Receives ROI centroids from the ScanImage imaging PC via msocket, then
%   runs tfp.experiments.exp_ensemble_fill_factor_power against the real
%   DMD and NI-6323. Per-cell laser power is set by the fraction of pixels
%   ON within each cell's DMD disk; the FS-50 AO voltage is held constant.
%
%   Sweep structure:
%     Cond 1 — Uniform: 10 fill levels (10% .. 100%) x 10 repeats = 100 trials,
%              shuffled within the condition.
%     Cond 2 — Differential: 3 decorrelated per-cell distributions (each cell
%              drawn from {0.2, 0.4, 0.6, 0.8, 1.0}) x 10 repeats = 30 trials,
%              also shuffled. Pairwise |Pearson r| forced <= 0.15 across the
%              3 distributions.
%
%   Timing: 500 ms ON / 3000 ms ISI per trial. Total ~ (100 + 30) * 3.5 s
%   ~ 7.6 minutes plus pattern-build + DMD upload.
%
%   Prerequisites:
%     1. Calibration file (.mat) with .dmdToScan_affine (3x3) — produced by
%        tfp.calibration.composeCalibration.
%     2. DMD initialized and pattern memory available (ALP-4.3, DLi4130 or
%        DLP650LNIR).
%     3. NI-6323 (Dev1) connected; ao1 wired to FS-50 power modulation input.
%     4. msocket library on the MATLAB path (or set MSOCKET_PATH below).
%     5. Operator on the imaging PC ready to send ROI centroids via msocket.
%
%   Usage on scope PC:
%       >> addpath(fullfile(pwd, 'src'));
%       >> run scripts/run_ensemble_fill_factor_power
%
%   Adjust the CONFIG section before the first run.

addpath(fullfile(fileparts(mfilename('fullpath')), '..', 'src'));

% =========================================================================
% CONFIG — edit before running
% =========================================================================
CALIB_FILE   = 'configs/calib_composed.mat';   % output of composeCalibration
SESSION_DIR  = fullfile('data', ...
    sprintf('fillfactor_%s', datestr(now, 'yyyymmdd_HHMMSS')));

% DAQ
DAQ_DEVICE   = 'Dev1';
DAQ_RATE     = 10000;
AO_CHANNEL   = 'ao1';     % FS-50 power modulation input

% DMD (ALP-4.1 DLi4130 until DLP650LNIR arrives)
DMD_ROWS     = 768;
DMD_COLS     = 1024;

% Stimulus parameters
DISK_RADIUS_PX = 15;      % diameter ~30 px; raise to 17 for ~900 px / neuron
STIM_DURATION_S = 0.5;    % laser ON per trial
INTER_STIM_S    = 3.0;    % ISI; long enough for GCaMP recovery
POWER_V         = 5.0;    % AO voltage (HELD CONSTANT across trials)
RNG_SEED        = 0;      % reproducibility

% Illuminated DMD region (the pi-Shaper flat-top footprint on the chip).
% Default: 300x300 px centered on the chip — at ~3 DMD px / µm at sample,
% that's the 100 µm pilot FOV. Pass [] to disable the warning + outline.
ILLUMINATED_REGION_SIZE_PX = 300;

% Cond 1 — uniform sweep
UNIFORM_FRACTIONS  = 0.1:0.1:1.0;   % 10% .. 100% in 10% steps
UNIFORM_N_REPEATS  = 10;            % 10 reps per level -> 100 trials

% Cond 2 — differential per-cell distributions
DIFF_N_DISTS         = 3;
DIFF_N_REPEATS       = 10;
DIFF_FILL_SET        = [0.2 0.4 0.6 0.8 1.0];
DIFF_MAX_CORR        = 0.15;
DIFF_MAX_ATTEMPTS    = 20000;

% msocket ROI receiver (imaging PC connects here)
ROI_PORT        = 3045;
MSOCKET_PATH    = '';     % e.g. 'C:\path\to\msocket'; leave '' if on path
ROI_TIMEOUT_S   = 120;    % seconds to wait for imaging PC

% =========================================================================
% Hardware init
% =========================================================================
fprintf('=== Fill-Factor Power Sweep ===\n\n');

dmdCfg.nRows = DMD_ROWS;
dmdCfg.nCols = DMD_COLS;
dmd = tfp.hardware.DLP650LNIR_DMD();
dmd.initialize(dmdCfg);

daqCfg.deviceName          = DAQ_DEVICE;
daqCfg.sampleRate          = DAQ_RATE;
daqCfg.analogOutChannels   = {AO_CHANNEL};
daqCfg.analogInChannels    = {};
daqCfg.digitalOutChannels  = {};
daqCfg.digitalInChannels   = {};
daq = tfp.hardware.NI6323_DAQ(daqCfg);
daq.initialize(daqCfg);

cleanupHw = onCleanup(@() teardown(dmd, daq, AO_CHANNEL));  %#ok<NASGU>

% =========================================================================
% Load calibration
% =========================================================================
if ~isfile(CALIB_FILE)
    error('run_ensemble_fill_factor_power:noCalib', ...
        'Calibration file not found: %s\nRun alignDMDtoCamera + crossRegisterScanImage + composeCalibration first.', ...
        CALIB_FILE);
end
tmp   = load(CALIB_FILE);
calib = tmp.(char(fieldnames(tmp)));
if ~isfield(calib, 'dmdToScan_affine')
    error('run_ensemble_fill_factor_power:badCalib', ...
        '%s does not contain .dmdToScan_affine.', CALIB_FILE);
end
fprintf('Calibration loaded: %s\n', CALIB_FILE);

% =========================================================================
% Receive ROIs from ScanImage PC
% =========================================================================
fprintf('\nWaiting for ROI centroids from imaging PC...\n');
roiOpts.port        = ROI_PORT;
roiOpts.msocketPath = MSOCKET_PATH;
roiOpts.timeoutS    = ROI_TIMEOUT_S;
roiCentroids_scan = tfp.io.receiveROIsFromScanImage(roiOpts);

nROIs = size(roiCentroids_scan, 1);
fprintf('Received %d ROIs.\n', nROIs);

% =========================================================================
% Session directory
% =========================================================================
if ~isfolder(SESSION_DIR)
    mkdir(SESSION_DIR);
end
tfp.io.sessionLog(SESSION_DIR, 'session-start', struct( ...
    'script', 'run_ensemble_fill_factor_power', ...
    'nROIs', nROIs, ...
    'powerV', POWER_V, ...
    'diskRadiusPx', DISK_RADIUS_PX));

% =========================================================================
% Run experiment
% =========================================================================
opts.radiusPx       = DISK_RADIUS_PX;
opts.stimDurationS  = STIM_DURATION_S;
opts.interStimS     = INTER_STIM_S;
opts.aoChannel      = AO_CHANNEL;
opts.powerV         = POWER_V;
opts.rngSeed        = RNG_SEED;
opts.showLiveFigure = true;
opts.sessionDir     = SESSION_DIR;

% Centered illuminated region computed from DMD geometry.
half = ILLUMINATED_REGION_SIZE_PX / 2;
cCenter = floor(dmd.nCols / 2);
rCenter = floor(dmd.nRows / 2);
opts.illuminatedRegion = [cCenter - half, cCenter + half, ...
                          rCenter - half, rCenter + half];
fprintf('Illuminated DMD region: cols [%g..%g], rows [%g..%g] (%dx%d px).\n', ...
    opts.illuminatedRegion, ILLUMINATED_REGION_SIZE_PX, ILLUMINATED_REGION_SIZE_PX);

opts.runUniform           = true;
opts.uniformFillFractions = UNIFORM_FRACTIONS;
opts.uniformNRepeats      = UNIFORM_N_REPEATS;

opts.runDifferential          = true;
opts.differentialNDistributions = DIFF_N_DISTS;
opts.differentialNRepeats     = DIFF_N_REPEATS;
opts.differentialFillSet      = DIFF_FILL_SET;
opts.differentialMaxCorr      = DIFF_MAX_CORR;
opts.differentialMaxAttempts  = DIFF_MAX_ATTEMPTS;

result = tfp.experiments.exp_ensemble_fill_factor_power( ...
    dmd, daq, roiCentroids_scan, calib, opts);

% =========================================================================
% Save summary
% =========================================================================
save(fullfile(SESSION_DIR, 'fillfactor_result.mat'), ...
    'result', 'roiCentroids_scan', 'calib');
tfp.io.sessionLog(SESSION_DIR, 'session-end', struct( ...
    'cond1Trials', result.condition1.nTrials, ...
    'cond2Trials', result.condition2.nTrials, ...
    'cond2MaxAbsCorr', max(abs(result.condition2.pairwiseCorr))));

fprintf('\nSession saved to: %s\n', SESSION_DIR);

% =========================================================================
% Local helpers
% =========================================================================
function teardown(dmd, daq, aoChannel)
try, daq.outputSingleAnalog(aoChannel, 0); catch, end
try, dmd.cleanup();                        catch, end
try, daq.cleanup();                        catch, end
end
