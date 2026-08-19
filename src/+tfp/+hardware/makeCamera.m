function camera = makeCamera(config, opts)
%makeCamera Factory for the substage widefield camera.
%
%   camera = tfp.hardware.makeCamera(config)
%   camera = tfp.hardware.makeCamera(config, opts)
%
%   Keyed on config.camera.backend:
%     'mock'    — tfp.hardware.MockSubstageCamera
%     'basler'  — tfp.hardware.BaslerSubstageCamera (acA2500-14um over the
%                 gentl adaptor; Windows + pylon GenTL Producer only)
%     'generic' — tfp.hardware.SubstageCamera_generic (an Image Acquisition
%                 Toolbox recipe skeleton; every method throws)
%
%   Completes the set alongside tfp.hardware.makeZStage and
%   tfp.hardware.makeModulator. Until now there was no camera factory, so
%   `camera.class` in configs/real.yaml was read by nothing and every caller
%   hand-constructed the Basler — which is why configs/dli4130.yaml, having no
%   camera section at all, silently could not run a calibration.
%
%   BACK-COMPAT: when config.camera.backend is absent, the legacy
%   config.camera.class string is parsed instead, so an unedited real.yaml
%   keeps working.
%
%   opts:
%     .initialize  call initialize(config.camera) before returning (default true)
%     .cameraConfig  struct merged over config.camera (mock tests use this to
%                  inject a .dmd handle and .truthAffine, which cannot come
%                  from YAML)
%
%   Throws tfp:hardware:makeCamera:badBackend.

if nargin < 2 || isempty(opts), opts = struct(); end

camCfg  = tfp.util.configField(config, 'camera', struct());
backend = tfp.util.configField(camCfg, 'backend', '');

if isempty(backend)
    backend = backendFromClass(tfp.util.configField(camCfg, 'class', ''));
end
backend = lower(char(backend));

extra = tfp.util.configField(opts, 'cameraConfig', struct());
f = fieldnames(extra);
for k = 1:numel(f)
    camCfg.(f{k}) = extra.(f{k});
end

switch backend
    case 'mock'
        camera = tfp.hardware.MockSubstageCamera();
    case 'basler'
        camera = tfp.hardware.BaslerSubstageCamera();
    case 'generic'
        camera = tfp.hardware.SubstageCamera_generic();
    otherwise
        error('tfp:hardware:makeCamera:badBackend', ...
            ['Unknown camera.backend "%s". Valid: mock, basler, generic. ' ...
             'Set camera.backend in the config (camera.class is the legacy ' ...
             'spelling and is still parsed).'], backend);
end

if logical(tfp.util.configField(opts, 'initialize', true))
    camera.initialize(camCfg);
end
end

% ---------------------------------------------------------------------------
function backend = backendFromClass(classStr)
%backendFromClass Map the legacy camera.class string onto a backend name.
classStr = lower(char(classStr));
if isempty(classStr)
    backend = 'mock';          % no camera section at all: safe default
elseif contains(classStr, 'basler')
    backend = 'basler';
elseif contains(classStr, 'mock')
    backend = 'mock';
elseif contains(classStr, 'generic')
    backend = 'generic';
else
    backend = classStr;        % let the switch reject it by name
end
end
