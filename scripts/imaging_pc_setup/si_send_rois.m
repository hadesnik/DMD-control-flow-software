% si_send_rois  Extract ROI centroids from ScanImage and send to scope PC.
%
% Run this in the ScanImage MATLAB console on the IMAGING PC after you have
% drawn ROIs over the target cells in the ScanImage ROI manager.
%
% WORKFLOW:
%   1. In ScanImage: run a Focus scan to see the GCaMP field.
%   2. Draw ROIs over identified cells using the ROI Manager (ROIs tab →
%      "New ROI" or right-click on the image).  Each ROI should cover one
%      cell body.  The ROI centroid is used — shape does not matter much.
%   3. On the scope PC: start the experiment script (run_ensemble_activation).
%      It will block waiting for this script to connect on port 3045.
%   4. Run THIS script in the ScanImage MATLAB console.  It extracts the
%      centroids, prints them for visual confirmation, then sends them.
%
% The scope PC receives the centroids via tfp.io.receiveROIsFromScanImage
% and converts them to DMD coordinates using the composed calibration affine.
%
% EDIT THE CONFIG SECTION below before running.
%
% %VERIFY — ROI property names depend on ScanImage version:
%   Run in the ScanImage console to inspect your ROI objects:
%     rg = hSI.hRoiManager.roiGroups(1);
%     r  = rg.rois(1);
%     properties(r)          % list all properties
%     r.centerXY             % should give [x y] in scan-field units
%   If centerXY is missing, check: r.scanfields(1).centerXY
%   See also: https://docs.scanimage.org (ROI API section for your version)

% =========================================================================
% CONFIG — edit before running
% =========================================================================

%FILL: path to msocket on this imaging PC
addpath(genpath('C:\Users\adesniklab\Documents\MATLAB\msocket'));

SCOPE_PC_IP = '128.32.177.203';  % IP of the DAQ / scope PC
ROI_PORT    = 3045;               % must match receiveROIsFromScanImage default

% =========================================================================
% Extract ROI centroids from ScanImage ROI manager
% =========================================================================

% %VERIFY: hSI must be in the workspace (it is when running inside ScanImage).
if ~exist('hSI', 'var')
    error('si_send_rois:noSI', ...
        'hSI not found. Run this script inside the ScanImage MATLAB console.');
end

roiGroups = hSI.hRoiManager.roiGroups;  %#ok<NODEF>
if isempty(roiGroups)
    error('si_send_rois:noROIGroup', ...
        'No ROI groups found. Create ROIs in the ScanImage ROI manager first.');
end

% Use the first (and typically only) ROI group.
rois = roiGroups(1).rois;
nROIs = numel(rois);

if nROIs == 0
    error('si_send_rois:noROIs', ...
        'ROI group is empty. Draw ROIs over target cells in the ROI manager.');
end

% Extract centroid [x y] in scan-field coordinates from each ROI.
% %VERIFY: centerXY is the standard property in ScanImage 2020+.
%   If this errors, inspect with: properties(rois(1))
%   Fallback: rois(1).scanfields(1).centerXY
centroids = zeros(nROIs, 2);
for k = 1:nROIs
    try
        centroids(k, :) = rois(k).centerXY;
    catch
        try
            centroids(k, :) = rois(k).scanfields(1).centerXY;
        catch ME
            error('si_send_rois:badROIProp', ...
                'Cannot read centerXY from ROI %d. Inspect with properties(rois(%d)).\n%s', ...
                k, k, ME.message);
        end
    end
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
    mssend(sock, struct('centroids', centroids));
    msdisconnect(sock);
catch ME
    error('si_send_rois:sendFailed', ...
        'msocket send failed: %s\nCheck that scope PC is listening on port %d.', ...
        ME.message, ROI_PORT);
end

fprintf('Sent %d ROI centroids to scope PC. Experiment will now proceed.\n', nROIs);
