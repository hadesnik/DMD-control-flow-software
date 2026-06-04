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
end
