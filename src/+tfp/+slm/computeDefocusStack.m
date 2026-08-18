function [stack, info] = computeDefocusStack(dzListUm, sys, opts)
%computeDefocusStack Compute an ordered stack of defocus masks.
%
%   [stack, info] = tfp.slm.computeDefocusStack(dzListUm, sys, opts)
%
%   dzListUm: 1xN vector of defocus commands (um). ORDER IS THE CONTRACT:
%             the SLM preloads these masks in this exact order and TTL /
%             software advance steps through them sequentially, so the
%             caller must pass depth-group order (see
%             tfp.trial.TrialSequence.generate3DEnsemble).
%   sys:      struct for tfp.slm.computeDefocusMask (device geometry +
%             optics; see that function).
%   opts:     optional struct:
%               .wfcPath  — path to a wavefront-correction file loaded via
%                           tfp.slm.loadWFC ('' = flat). Overrides sys.wfcMap.
%               .lutVec   — software LUT vector for tfp.slm.applyLUT
%                           ([] = identity; the real wavelength LUT loads
%                           on-device via Blink).
%
%   Returns:
%     stack  uint8(nRows, nCols, N) in dzListUm order
%     info   struct array (1xN) from computeDefocusMask per plane

if nargin < 3 || isempty(opts)
    opts = struct();
end
if ~isnumeric(dzListUm) || ~isvector(dzListUm) || isempty(dzListUm)
    error('tfp:slm:computeDefocusStack:badDzList', ...
        'dzListUm must be a non-empty numeric vector.');
end

wfcPath = tfp.util.configField(opts, 'wfcPath', '');
lutVec  = tfp.util.configField(opts, 'lutVec',  []);
if ~isempty(char(wfcPath))
    sys.wfcMap = tfp.slm.loadWFC(char(wfcPath), sys);
end

nRows = double(sys.nRows);
nCols = double(sys.nCols);
N     = numel(dzListUm);

stack = zeros(nRows, nCols, N, 'uint8');
info  = struct('rPupilUm', {}, 'nPxRadius', {}, 'wrappedWaves', {});
for k = 1:N
    [mask, inf_k] = tfp.slm.computeDefocusMask(dzListUm(k), sys);
    stack(:, :, k) = tfp.slm.applyLUT(mask, lutVec);
    info(k) = inf_k;
end
end
