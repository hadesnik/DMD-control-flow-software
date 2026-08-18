function zstage = makeZStage(config, opts)
%makeZStage Factory for the axial ground-truth ruler.
%
%   zstage = tfp.hardware.makeZStage(config)
%   zstage = tfp.hardware.makeZStage(config, opts)
%
%   Keyed on config.zstage.backend:
%     'mock'   — tfp.hardware.MockZStage
%     'mp285'  — tfp.hardware.MP285ZStage (MP-285 switched to the DAQ PC
%                via the manual serial switch box)
%     'relay'  — tfp.hardware.RelayZStage (MP-285 stays on the imaging PC;
%                requires scripts/imaging_pc_setup/si_motor_helper.m
%                running there; connect() is called here — pass
%                opts.connectOptions = struct('mockTransport', true) for
%                socket-free tests)
%     'manual' — tfp.hardware.ManualZStage (operator turns the knob)

if nargin < 2 || isempty(opts)
    opts = struct();
end
zCfg    = tfp.util.configField(config, 'zstage', struct());
backend = lower(char(tfp.util.configField(zCfg, 'backend', 'mock')));

switch backend
    case 'mock'
        zstage = tfp.hardware.MockZStage();
        zstage.initialize(zCfg);
    case 'mp285'
        zstage = tfp.hardware.MP285ZStage(zCfg);
    case 'relay'
        zstage = tfp.hardware.RelayZStage(zCfg);
        zstage.connect(tfp.util.configField(opts, 'connectOptions', struct()));
    case 'manual'
        zstage = tfp.hardware.ManualZStage();
        zstage.initialize(zCfg);
    otherwise
        error('tfp:hardware:makeZStage:badBackend', ...
            'Unknown zstage.backend "%s". Valid: mock, mp285, relay, manual.', ...
            backend);
end
end
