function mod = makeModulator(config, opts)
%makeModulator Factory for the pupil phase modulator (SLM or TI PLM).
%
%   mod = tfp.hardware.makeModulator(config)
%   mod = tfp.hardware.makeModulator(config, opts)
%
%   Keyed on config.slm.backend:
%     'mock'    — tfp.hardware.MockSLM   (Meadowlark-shaped simulator)
%     'remote'  — tfp.hardware.MeadowlarkSLM proxy to the SLM-PC server
%                 (connect() is called here; pass opts.connectOptions =
%                 struct('mockTransport', true) for socket-free tests)
%     'mockplm' — tfp.hardware.MockPLM   (legacy TI-PLM simulator)
%     'dlpc900' — tfp.hardware.DLPC900_PLM (TI PLM; the future swap —
%                 selecting it here is the whole "swap for the PLM" story)
%
%   opts.ttlPulseFcn — injected TTL callable for sequence-capable devices
%                      (e.g. @() daq.sendDigitalPulse('port0/line8', 2e-4)).
%   opts.connectOptions — passed to MeadowlarkSLM.connect.
%
%   Returns [] when config.slm is absent or config.slm.enabled is false —
%   callers treat an empty modulator as "2D mode".
%
%   Replaces the per-experiment makePlm helpers whose 'real' branch threw
%   "Phase 4".

if nargin < 2 || isempty(opts)
    opts = struct();
end

slmCfg = tfp.util.configField(config, 'slm', struct());
if isempty(fieldnames(slmCfg)) || ...
        ~logical(tfp.util.configField(slmCfg, 'enabled', false))
    mod = [];
    return
end

backend = lower(char(tfp.util.configField(slmCfg, 'backend', 'mock')));
switch backend
    case 'mock'
        mod = tfp.hardware.MockSLM();
        mod.initialize(slmCfg);
    case 'remote'
        mod = tfp.hardware.MeadowlarkSLM(slmCfg);
        mod.connect(tfp.util.configField(opts, 'connectOptions', struct()));
    case 'mockplm'
        mod = tfp.hardware.MockPLM();
        plmCfg = tfp.util.configField(config, 'plm', struct());
        mod.initialize(plmCfg);
    case 'dlpc900'
        plmCfg = tfp.util.configField(config, 'plm', struct());
        mod = tfp.hardware.DLPC900_PLM(plmCfg);
    otherwise
        error('tfp:hardware:makeModulator:badBackend', ...
            ['Unknown slm.backend "%s". Valid: mock, remote, mockplm, ' ...
             'dlpc900.'], backend);
end

if isfield(opts, 'ttlPulseFcn') && ~isempty(opts.ttlPulseFcn) && ...
        ismethod(mod, 'setTtlPulseFcn')
    mod.setTtlPulseFcn(opts.ttlPulseFcn);
end
end
