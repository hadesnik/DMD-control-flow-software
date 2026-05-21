%run_ensemble_activation  Run ensemble photostimulation on scope PC with real hardware.
%
%   Receives ROI centroids from the ScanImage imaging PC via msocket, converts
%   them to DMD coordinates using the composed calibration affine, then runs:
%
%     Sequential condition: each ROI alone, 500 ms on / 500 ms off, in order.
%     Ensemble  condition:  all ROIs simultaneously, 500 ms on.
%
%   Prerequisites:
%     1. Calibration file (.mat) produced by tfp.calibration.composeCalibration.
%        Must contain .dmdToScan_affine (3x3).
%     2. DMD initialised and pattern memory available (ALP-4.3, DLi4130 or
%        DLP650LNIR).
%     3. NI-6323 (Dev1) connected; ao1 wired to FS-50 power modulation input.
%     4. msocket library on the MATLAB path (or set MSOCKET_PATH below).
%     5. Operator on the imaging PC ready to send ROI centroids via msocket.
%
%   Usage:
%     cd to repo root on scope PC, then:
%       >> addpath(fullfile(pwd, 'src'));
%       >> run scripts/run_ensemble_activation
%
%   Adjust the CONFIG section below before the first run.

addpath(fullfile(fileparts(mfilename('fullpath')), '..', 'src'));

% =========================================================================
% CONFIG — edit these before running
% =========================================================================

CALIB_FILE   = 'configs/calib_composed.mat';  % output of composeCalibration
SESSION_DIR  = fullfile('data', ...
    sprintf('ensemble_%s', datestr(now, 'yyyymmdd_HHMMSS')));

% DAQ
DAQ_DEVICE   = 'Dev1';
DAQ_RATE     = 10000;
AO_CHANNEL   = 'ao1';      % FS-50 power modulation input

% DMD (ALP-4.1 DLi4130 until DLP650LNIR arrives)
DMD_ROWS     = 768;
DMD_COLS     = 1024;

% Stimulus parameters
SPOT_RADIUS_PX  = 8;     % DMD pixels (~16 µm for DLi4130 at ~2 µm/px)
STIM_DURATION_S = 0.5;   % 500 ms laser ON per pulse
INTER_STIM_S    = 0.5;   % 500 ms gap between sequential pulses
POWER_V         = 5.0;   % AO voltage for full laser power

% msocket ROI receiver (imaging PC connects here)
ROI_PORT        = 3045;
MSOCKET_PATH    = '';     % e.g. 'C:\path\to\msocket'; leave '' if already on path
ROI_TIMEOUT_S   = 120;   % seconds to wait for imaging PC to connect

% =========================================================================
% Hardware init
% =========================================================================
fprintf('=== Ensemble Activation ===\n\n');

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

cleanupHw = onCleanup(@() teardown(dmd, daq, AO_CHANNEL));

% =========================================================================
% Load calibration
% =========================================================================
if ~isfile(CALIB_FILE)
    error('run_ensemble_activation:noCalib', ...
        'Calibration file not found: %s\nRun alignDMDtoCamera + crossRegisterScanImage + composeCalibration first.', ...
        CALIB_FILE);
end
tmp   = load(CALIB_FILE);
calib = tmp.(char(fieldnames(tmp)));    % accept any variable name in the .mat

if ~isfield(calib, 'dmdToScan_affine')
    error('run_ensemble_activation:badCalib', ...
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
    'script', 'run_ensemble_activation', ...
    'nROIs', nROIs, 'powerV', POWER_V));

% =========================================================================
% Run experiment
% =========================================================================
opts.spotRadiusPx   = SPOT_RADIUS_PX;
opts.stimDurationS  = STIM_DURATION_S;
opts.interStimS     = INTER_STIM_S;
opts.aoChannel      = AO_CHANNEL;
opts.powerV         = POWER_V;
opts.showLiveFigure = true;
opts.sessionDir     = SESSION_DIR;

result = tfp.experiments.exp_ensemble_activation( ...
    dmd, daq, roiCentroids_scan, calib, opts);

% =========================================================================
% Save summary
% =========================================================================
save(fullfile(SESSION_DIR, 'ensemble_result.mat'), 'result', 'roiCentroids_scan', 'calib');
tfp.io.sessionLog(SESSION_DIR, 'session-end', struct( ...
    'nSequentialTrials', result.nSequentialTrials, ...
    'nEnsembleTrials',   result.nEnsembleTrials));

fprintf('\nSession saved to: %s\n', SESSION_DIR);

% =========================================================================
% Local helpers
% =========================================================================
function teardown(dmd, daq, aoChannel)
try, daq.outputSingleAnalog(aoChannel, 0); catch, end
try, dmd.cleanup();                        catch, end
try, daq.cleanup();                        catch, end
end
