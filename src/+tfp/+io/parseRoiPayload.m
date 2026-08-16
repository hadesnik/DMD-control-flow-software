function rois = parseRoiPayload(data)
%parseRoiPayload Parse an ROI payload from the imaging PC (socket-free core).
%
%   rois = tfp.io.parseRoiPayload(data)
%
%   Factored out of receiveROIsFromScanImage so the wire-format logic is
%   testable without sockets. Accepts:
%     Nx2 double [x y]                — legacy 2D payload
%     Nx4 double [x y planeIdx zUm]   — 3D payload (si_send_rois with the
%                                       ETL plane tag; zUm may be NaN when
%                                       the imaging PC has no ETL
%                                       calibration)
%     struct with .centroids          — backward compatibility
%
%   Returns a struct:
%     .centroids  Nx2 double [x y] scan-field coords
%     .planeIdx   Nx1 double (NaN for 2D payloads)
%     .zUm        Nx1 double (NaN when unknown)
%     .is3D       logical
%
%   Errors under tfp:io:parseRoiPayload:*.

if isstruct(data) && isfield(data, 'centroids')
    data = data.centroids;
end
if ~isnumeric(data)
    error('tfp:io:parseRoiPayload:badPayload', ...
        'Expected an Nx2 or Nx4 double (or struct with .centroids); got %s.', ...
        class(data));
end
data = double(data);
if ndims(data) ~= 2 || ~any(size(data, 2) == [2, 4])
    error('tfp:io:parseRoiPayload:badShape', ...
        'ROI payload must be Nx2 or Nx4; got size [%s].', num2str(size(data)));
end
if size(data, 1) < 1
    error('tfp:io:parseRoiPayload:noROIs', ...
        'ROI payload has zero rows — no ROIs received.');
end

n = size(data, 1);
rois.centroids = data(:, 1:2);
if size(data, 2) == 4
    planeIdx = data(:, 3);
    bad = isfinite(planeIdx) & (planeIdx < 1 | planeIdx ~= round(planeIdx));
    if any(bad)
        error('tfp:io:parseRoiPayload:badPlaneIdx', ...
            '%d ROI rows carry a non-positive-integer planeIdx.', nnz(bad));
    end
    rois.planeIdx = planeIdx;
    rois.zUm      = data(:, 4);
    rois.is3D     = true;
else
    rois.planeIdx = nan(n, 1);
    rois.zUm      = nan(n, 1);
    rois.is3D     = false;
end
end
