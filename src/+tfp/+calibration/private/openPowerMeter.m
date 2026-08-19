function [meter, owned] = openPowerMeter(options, callerId)
%openPowerMeter Open a Thorlabs PM100D, or adopt an injected stand-in.
%
%   [meter, owned] = openPowerMeter(options, callerId)
%
%   THE SEAM. Until now tfp.calibration.powerMeterSweep hard-wired TLPM() at
%   its line 88, which made the entire sweep untestable — powerMeterSweep_mock
%   had to RE-IMPLEMENT the maths rather than exercise the real code path, so
%   the thing under test was never the thing that runs at the bench. Routing
%   the meter through here lets a synthetic meter drive the real function.
%
%   options:
%     .meter         any object exposing measPower() -> watts. When supplied,
%                    it is adopted as-is and owned is false (the caller who
%                    injected it owns its lifetime).
%     .wavelengthNm  spectral correction applied to a real PM100D (default 1038,
%                    the CARBIDE's measured value on certificate s/n C264570)
%
%   callerId is the calling function's name, used in error identifiers so the
%   existing tfp:calibration:powerMeterSweep:noDriver / :noDevice identifiers
%   are preserved for that caller.
%
%   Returns owned = true only when this function constructed the device, in
%   which case the caller must close it.

if nargin < 2 || isempty(callerId), callerId = 'openPowerMeter'; end
if nargin < 1 || isempty(options),  options  = struct();          end

injected = tfp.util.configField(options, 'meter', []);
if ~isempty(injected)
    if ~ismethod(injected, 'measPower') && ~isprop(injected, 'measPower')
        error(sprintf('tfp:calibration:%s:badMeter', callerId), ...
            'options.meter must expose measPower(); got %s.', class(injected));
    end
    meter = injected;
    owned = false;
    return
end

wavelengthNm = tfp.util.configField(options, 'wavelengthNm', 1038);

% TLPM is a MATLAB class provided by the Thorlabs Optical Power Monitor
% installer. findRsrc() returns a device count; getRsrcName(0) returns the USB
% resource string for the first device. Verified against the TLPM MATLAB
% wrapper shipped with Optical Power Monitor v3.x; if a future version changes
% the API, check Thorlabs\TLPM\Examples\MATLAB\ for the updated sequence.
try
    meter = TLPM();
catch
    error(sprintf('tfp:calibration:%s:noDriver', callerId), ...
        ['Thorlabs TLPM driver not found. Install from ' ...
         'https://www.thorlabs.com/software_pages/ViewSoftwarePage.cfm?Code=PM100D']);
end

deviceCount = meter.findRsrc();
if deviceCount < 1
    error(sprintf('tfp:calibration:%s:noDevice', callerId), ...
        ['No PM100D found. Check the USB connection and the Thorlabs ' ...
         'Optical Power Monitor software.']);
end
resourceName = meter.getRsrcName(0);
meter.init(resourceName, true, true);
meter.setWavelength(wavelengthNm);
owned = true;
end
