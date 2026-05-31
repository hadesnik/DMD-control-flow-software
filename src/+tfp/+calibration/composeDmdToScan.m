function calib = composeDmdToScan(scanCalib, dmdCalib)
%composeDmdToScan  Compose scanToCam + dmdToSample affines into dmdToScan.
%   Use this after running crossRegisterScanImage without dmdCalib (Step B
%   before DMD alignment), then later completing alignDMDtoCamera (Step A).
%
%   calib = composeDmdToScan(scanCalib, dmdCalib)
%
%   scanCalib  - output of crossRegisterScanImage (contains scanToCam_affine)
%   dmdCalib   - output of alignDMDtoCamera (contains dmdToSample_affine)
%
%   Returns scanCalib with dmdToScan_affine and dmdToSample_affine updated.

if ~isfield(scanCalib, 'scanToCam_affine')
    error('tfp:calibration:composeDmdToScan:missingField', ...
        'scanCalib must contain scanToCam_affine (output of crossRegisterScanImage).');
end
if ~isfield(dmdCalib, 'dmdToSample_affine')
    error('tfp:calibration:composeDmdToScan:missingField', ...
        'dmdCalib must contain dmdToSample_affine (output of alignDMDtoCamera).');
end

scanToCam = scanCalib.scanToCam_affine;
dmdToCam  = dmdCalib.dmdToSample_affine;
dmdToScan = inv(scanToCam) * dmdToCam;  %#ok<MINV> small 3x3, explicit ok

calib = scanCalib;
calib.dmdToSample_affine = dmdCalib.dmdToSample_affine;
calib.dmdToScan_affine   = dmdToScan;
calib.timestamp          = datetime('now');
if isfield(calib, 'notes') && ~isempty(calib.notes)
    calib.notes = [calib.notes '; dmdToScan composed after alignDMDtoCamera'];
else
    calib.notes = 'dmdToScan composed after alignDMDtoCamera';
end

fprintf('[composeDmdToScan] dmdToScan_affine composed. Run verify step.\n');
end
