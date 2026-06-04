function config = loadOrUseConfig(configOrPath, callerId)
%loadOrUseConfig Return a config struct from a struct or a YAML path.
%
%   config = tfp.util.loadOrUseConfig(configOrPath, callerId)
%
%   configOrPath is either a pre-built config struct (returned as-is, the test
%   path) or a char/string path to a YAML config (parsed via tfp.io.loadConfig).
%   callerId namespaces the error identifier as
%   tfp:experiments:<callerId>:badConfig.  Shared by the experiment scripts.

if isstruct(configOrPath)
    config = configOrPath;
elseif ischar(configOrPath) || (isstring(configOrPath) && isscalar(configOrPath))
    config = tfp.io.loadConfig(char(configOrPath));
else
    error(sprintf('tfp:experiments:%s:badConfig', callerId), ...
        'configOrPath must be a char/string path or a config struct.');
end
end
