function sys = buildDefocusSys(config)
%buildDefocusSys Build the sys struct for SLM defocus masks from config.
%
%   sys = tfp.optics.buildDefocusSys(config)
%
%   Merges, in increasing precedence:
%     1. the objective registry entry named by config.objective.name
%        (default 'nikon10x045'),
%     2. explicit overrides in config.objective (fObjUm, NA, nImm),
%     3. SLM device geometry + optics from config.slm
%        (nRows, nCols, pitch_um, nStates, lambda_nm, m_relay,
%         wrap_phase_rad).
%
%   config.slm.m_relay (SLM plane -> objective BFP pupil relay
%   magnification) is REQUIRED and has no registry default: the optics
%   handoff does not yet carry a machine-readable key for it
%   (slm_bfp_relay_mag requested for the f7=300 regeneration). %VERIFY the
%   configured value against the optics model before trusting commanded
%   defocus magnitudes — though the z-calibration
%   (tfp.calibration.calibrateSlmDefocus) fits the effective scale and is
%   the safety net either way.
%
%   Wrap convention defaults to 2*pi (LC device with on-device LUT); the
%   TI PLM's (N-1)/N piston wrap comes from its own path in
%   tfp.hardware.PLM.computeDefocusPattern.

if ~isstruct(config)
    error('tfp:optics:buildDefocusSys:badConfig', 'config must be a struct.');
end
objCfg = tfp.util.configField(config, 'objective', struct());
slmCfg = tfp.util.configField(config, 'slm',       struct());

objName = char(tfp.util.configField(objCfg, 'name', 'nikon10x045'));
reg     = tfp.optics.objectives(objName);

mRelay = double(tfp.util.configField(slmCfg, 'm_relay', 0));
if ~isscalar(mRelay) || ~isfinite(mRelay) || mRelay <= 0
    error('tfp:optics:buildDefocusSys:missingMRelay', ...
        ['config.slm.m_relay (SLM -> objective-BFP pupil relay ' ...
         'magnification) is required and must be > 0. There is no ' ...
         'handoff constant for it yet — measure or derive it from the ' ...
         'optics model (f6/periscope/tube chain) and put it in the rig ' ...
         'config. The z-calibration will fit the effective scale.']);
end

nStates = double(tfp.util.configField(slmCfg, 'nStates', 256));

sys = struct( ...
    'nRows',        double(tfp.util.configField(slmCfg, 'nRows',     1024)), ...
    'nCols',        double(tfp.util.configField(slmCfg, 'nCols',     1024)), ...
    'pitchXUm',     double(tfp.util.configField(slmCfg, 'pitch_um',  17.0)), ...
    'pitchYUm',     double(tfp.util.configField(slmCfg, 'pitch_um',  17.0)), ...
    'nStates',      nStates, ...
    'lambdaNm',     double(tfp.util.configField(slmCfg, 'lambda_nm', 1038)), ...
    'mRelay',       mRelay, ...
    'nImm',         double(tfp.util.configField(objCfg, 'nImm',   reg.nImm)), ...
    'fObjUm',       double(tfp.util.configField(objCfg, 'fObjUm', reg.fObjUm)), ...
    'NA',           double(tfp.util.configField(objCfg, 'NA',     reg.NA)), ...
    'wrapPhaseRad', double(tfp.util.configField(slmCfg, 'wrap_phase_rad', 2*pi)));
sys.objectiveName  = objName;
sys.objectiveLabel = reg.label;
end
