% si_send_rois  Extract ROI centroids from ScanImage and send to scope PC.
%
% Run this in the ScanImage MATLAB console on the IMAGING PC after you have
% drawn ROIs over the target cells in the ScanImage ROI manager.
%
% WORKFLOW:
%   1. In ScanImage: run a Focus scan to see the GCaMP field.
%   2. Enable ROI Integration and draw an integration ROI over each target
%      cell (View → Integration Controls → Edit Integration Fields). These are
%      the SAME ROIs used for live F streaming (si_frame_callback / port 3044),
%      so you draw your cells once and they serve both targeting and monitoring.
%   3. On the scope PC: start the experiment script (run_ensemble_activation).
%      It will block waiting for this script to connect on port 3045.
%   4. Run THIS script in the ScanImage MATLAB console (idle is fine — centroids
%      are geometry and need no active scan). It extracts the centroids, prints
%      them for visual confirmation, then sends them.
%
% The scope PC receives the centroids via tfp.io.receiveROIsFromScanImage
% and converts them to DMD coordinates using the composed calibration affine.
%
% Source: hSI.hIntegrationRoiManager.roiGroup.rois — each roi's
% scanfields(1).centerXY is [x y] in scan-field reference coords. Confirmed
% against SI2018b on the rig (2026-05-29); the Roi object itself has no
% centerXY, so the value comes from its scanfield (an IntegrationField).

% =========================================================================
% CONFIG — edit imaging_pc_config.m / imaging_pc_config_local.m, not here
% =========================================================================

cfg         = imaging_pc_config();   % msocket path, scope-PC IP, ports
SCOPE_PC_IP = cfg.scopePcIp;          % IP of the DAQ / scope PC
ROI_PORT    = cfg.roiPort;            % must match receiveROIsFromScanImage default

% =========================================================================
% Extract ROI centroids from ScanImage ROI manager
% =========================================================================

% %VERIFY: hSI must be in the workspace (it is when running inside ScanImage).
if ~exist('hSI', 'var')
    error('si_send_rois:noSI', ...
        'hSI not found. Run this script inside the ScanImage MATLAB console.');
end

% Integration ROIs live on hIntegrationRoiManager.roiGroup (singular).
rois  = hSI.hIntegrationRoiManager.roiGroup.rois;
nROIs = numel(rois);
if nROIs == 0
    error('si_send_rois:noROIs', ...
        ['No integration ROIs found. Enable ROI Integration and draw an ' ...
         'integration ROI over each target cell first.']);
end

% Extract centroid [x y] in scan-field coords from each ROI's scanfield.
centroids = zeros(nROIs, 2);
for k = 1:nROIs
    centroids(k, :) = rois(k).scanfields(1).centerXY;
end

fprintf('Extracted %d ROI centroids (scan-field coords):\n', nROIs);
fprintf('  %5s  %10s  %10s\n', 'ROI', 'x', 'y');
for k = 1:nROIs
    fprintf('  %5d  %10.4f  %10.4f\n', k, centroids(k,1), centroids(k,2));
end

% =========================================================================
% Send to scope PC
% =========================================================================

fprintf('\nConnecting to scope PC (%s:%d)...\n', SCOPE_PC_IP, ROI_PORT);
fprintf('(Scope PC must already be running run_ensemble_activation)\n');

try
    sock = msconnect(SCOPE_PC_IP, ROI_PORT);
    % Send a bare Nx2 double, NOT a struct: this msocket build does not
    % round-trip structs reliably on this path (a struct payload arrived as a
    % plain double on the scope PC). receiveROIsFromScanImage accepts the matrix.
    mssend(sock, centroids);
    msclose(sock);
catch ME
    error('si_send_rois:sendFailed', ...
        'msocket send failed: %s\nCheck that scope PC is listening on port %d.', ...
        ME.message, ROI_PORT);
end

fprintf('Sent %d ROI centroids to scope PC. Experiment will now proceed.\n', nROIs);
