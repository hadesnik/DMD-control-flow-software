function [dmd, daq] = makeHardware(config, callerId)
%makeHardware Build DMD + DAQ hardware objects per config.hardwareKind.
%
%   [dmd, daq] = tfp.util.makeHardware(config, callerId)
%
%   'mock' -> MockDMD + MockDAQ, both initialized from config.dmd / config.daq.
%   'real' -> DLP650LNIR_DMD + NI6323_DAQ (constructed from the same config;
%   their constructors initialize the hardware).  callerId namespaces the error
%   identifier as tfp:experiments:<callerId>:badKind.  Shared by the experiment
%   scripts.  Experiments that also need a PLM or SLM build those separately.

switch lower(char(config.hardwareKind))
    case 'mock'
        dmd = tfp.hardware.MockDMD();
        daq = tfp.hardware.MockDAQ();
    case 'real'
        dmd = tfp.hardware.DLP650LNIR_DMD(config.dmd);
        daq = tfp.hardware.NI6323_DAQ(config.daq);
    otherwise
        error(sprintf('tfp:experiments:%s:badKind', callerId), ...
            'unknown hardwareKind: %s.', config.hardwareKind);
end
if strcmp(lower(char(config.hardwareKind)), 'mock')
    dmd.initialize(config.dmd);
    daq.initialize(config.daq);
end

% Laser-power safety: apply the FS-50 ao3 power policy from config.laser.
% (Both DAQ backends carry conservative defaults even if this is skipped.)
if isfield(config, 'laser') && ~isempty(config.laser)
    daq.configureLaserSafety(config.laser);
end

% Pattern safety: the DMD-side interlocks (patch containment + pupil pulse
% energy) that run on every loadPatternSequence.  Each backend already
% self-configured from config.dmd inside initialize(); this second call hands
% over the FULL config so the laser block is seen as well — the pupil interlock
% needs the rep rate, the pupil energy limit, and the worst-case ao3 voltage,
% none of which live under config.dmd.  Without it the DMD keeps its
% conservative full-scale voltage assumption, which blocks high-fill patterns
% rather than passing them.  See tfp.hardware.DMD "Pattern safety".
%
% NOTE config.laser.autoConfirmPulseEnergy is deliberately SEPARATE from
% autoConfirmPower and defaults false even in mock configs (TASKS.md T-BU-1d):
% the mock rig's autoConfirmPower:true must not opt past the pupil
% confirmation band.  Do not unify them.
dmd.configurePatternSafety(config);
end
