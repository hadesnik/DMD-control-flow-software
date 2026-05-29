function centroids = receiveROIsFromScanImage(options)
%receiveROIsFromScanImage Wait for ROI centroids from the ScanImage imaging PC.
%
%   centroids = receiveROIsFromScanImage()
%   centroids = receiveROIsFromScanImage(options)
%
%   Acts as an msocket server on the scope (DAQ) PC. The imaging PC connects
%   and sends a struct with field .centroids (Nx2 double, scan-field coords).
%   Port 3045 is used (separate from stim metadata on 3043 and F-stream on 3044).
%
%   Inputs (all optional via options struct):
%     .port          - msocket listening port           (default 3045)
%     .msocketPath   - path to msocket\ directory on this PC (default '')
%     .timeoutS      - seconds to wait for connection   (default 60)
%
%   Output:
%     centroids      - Nx2 double, [x y] scan-field coordinates per ROI,
%                      in whatever units crossRegisterScanImage used when
%                      the calibration was run (typically normalised scan-field
%                      units matching ScanImage's coordinate convention).
%
%   On the ScanImage / imaging PC, the operator runs:
%     msconnect('<daqPcIp>', 3045);
%     mssend(struct('centroids', roi_Nx2));   % Nx2 scan-field coords
%     msdisconnect();
%
%   The .centroids array should contain the centroid [x y] of each ROI in
%   scan-field units as reported by ScanImage's ROI manager.  In ScanImage
%   these are the (fastAxis, slowAxis) positions in degrees or normalised
%   units depending on the scanner configuration — use whichever matches the
%   units used during the crossRegisterScanImage calibration run.
%
%   See also tfp.hardware.ScanImageBridge, tfp.calibration.composeCalibration.

if nargin < 1 || isempty(options)
    options = struct();
end

port        = configField(options, 'port',        3045);
msocketPath = configField(options, 'msocketPath', '');
timeoutS    = configField(options, 'timeoutS',    60);

if ~isempty(msocketPath) && isfolder(msocketPath)
    addpath(msocketPath);
end

fprintf('[receiveROIsFromScanImage] Listening on port %d (timeout %.0f s)...\n', ...
    port, timeoutS);
fprintf('  On the ScanImage PC:\n');
fprintf('  On the ScanImage PC, run si_send_rois (it does msconnect/mssend/msclose).\n\n');

% Lab msocket uses explicit handles: srvsock = mslisten(port);
% sock = msaccept(srvsock, timeout); data = msrecv(sock). (Confirmed against
% SImsocketPrep.m and the verified 3044 dry-run — there is no implicit-handle
% form, and msdisconnect does not exist in this msocket build.)
try
    srvsock = mslisten(port);
    sock    = msaccept(srvsock, timeoutS);
    msclose(srvsock);
catch ME
    error('tfp:io:receiveROIsFromScanImage:listenFailed', ...
        'msocket listen/accept on port %d failed: %s', port, ME.message);
end

try
    data = msrecv(sock);
    msclose(sock);
catch ME
    try, msclose(sock); catch, end %#ok<TRYNC>
    error('tfp:io:receiveROIsFromScanImage:recvFailed', ...
        'msrecv failed: %s', ME.message);
end

if ~isstruct(data) || ~isfield(data, 'centroids')
    error('tfp:io:receiveROIsFromScanImage:badPayload', ...
        'Expected struct with .centroids field; received %s.', class(data));
end

centroids = double(data.centroids);
if ~isnumeric(centroids) || ndims(centroids) ~= 2 || size(centroids, 2) ~= 2
    error('tfp:io:receiveROIsFromScanImage:badCentroids', ...
        '.centroids must be Nx2 numeric; got size [%s].', num2str(size(centroids)));
end
if size(centroids, 1) < 1
    error('tfp:io:receiveROIsFromScanImage:noROIs', ...
        '.centroids has zero rows — no ROIs received.');
end

fprintf('[receiveROIsFromScanImage] Received %d ROIs.\n', size(centroids, 1));
end

% -------------------------------------------------------------------------
function value = configField(s, name, default)
if isfield(s, name)
    value = s.(name);
else
    value = default;
end
end
