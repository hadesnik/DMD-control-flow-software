function targets = validateSLMTargets(targets, slmParams, callerId)
%validateSLMTargets Validate, filter, and cap SLM photostimulation targets.
%
%   targets = tfp.util.validateSLMTargets(targets, slmParams, callerId)
%
%   Enforces geometric and density constraints on a set of SLM target
%   coordinates expressed in SLM sample-plane µm.  The function:
%     1. Checks that the input is a numeric N×2 or N×3 matrix (N ≥ 1).
%     2. Coerces 2-D input to N×3 by appending a z=0 column.
%     3. Drops targets whose lateral distance from the optical axis exceeds
%        addressableRadiusUm (default: Inf — no drop).
%     4. Greedy-rejects the later member of any pair whose lateral spacing is
%        less than minSpacingUm (default: 0 — no drop): iterates in row order,
%        retaining each target unless it is too close to an already-accepted one.
%     5. Caps the accepted set to the first maxCells targets (default: 20).
%
%   Inputs:
%     targets   - N×2 or N×3 numeric, [x y] or [x y z] in SLM µm.
%     slmParams - struct; fields read via local configField (missing → default):
%                   maxCells            (default 20)
%                   addressableRadiusUm (default Inf)
%                   minSpacingUm        (default 0)
%     callerId  - char, e.g. 'slmDispatch'; used to namespace error ids as
%                 tfp:experiments:<callerId>:badTargets / :noTargetsInField.
%
%   Output:
%     targets - M×3 double, accepted targets in SLM µm (M ≤ min(N, maxCells)).
%
%   Errors:
%     tfp:experiments:<callerId>:badTargets    - input is not N×2 or N×3 numeric.
%     tfp:experiments:<callerId>:noTargetsInField - all targets dropped by radius.

% --- Read limits from slmParams via local configField ---
maxCells            = double(configField(slmParams, 'maxCells',            20));
addressableRadiusUm = double(configField(slmParams, 'addressableRadiusUm', Inf));
minSpacingUm        = double(configField(slmParams, 'minSpacingUm',        0));

% --- 1. Shape check ---
if ~isnumeric(targets) || ndims(targets) ~= 2 || ...
        size(targets,1) < 1 || ~any(size(targets,2) == [2 3])
    error(sprintf('tfp:experiments:%s:badTargets', callerId), ...
        ['targets must be N×2 or N×3 numeric (SLM µm); got %dx%d %s.'], ...
        size(targets,1), size(targets,2), class(targets));
end

targets = double(targets);

% --- 2. Coerce to N×3 (append z=0 if 2-D) ---
if size(targets, 2) == 2
    targets = [targets, zeros(size(targets,1), 1)];
end

% --- 3. Drop targets outside addressable radius ---
r = hypot(targets(:,1), targets(:,2));
inField = (r <= addressableRadiusUm);

if ~any(inField)
    error(sprintf('tfp:experiments:%s:noTargetsInField', callerId), ...
        ['No targets lie within addressableRadiusUm = %.1f µm. ' ...
         'The farthest target is %.1f µm from the optical axis. ' ...
         'Either widen addressableRadiusUm in slmParams or pick ' ...
         'targets closer to the SLM field center.'], ...
        addressableRadiusUm, max(r));
end

targets = targets(inField, :);

% --- 4. Greedy spacing rejection ---
if minSpacingUm > 0
    accepted = true(size(targets,1), 1);
    for ii = 1:size(targets,1)
        if ~accepted(ii), continue; end
        for jj = ii+1:size(targets,1)
            if ~accepted(jj), continue; end
            d = hypot(targets(ii,1) - targets(jj,1), ...
                      targets(ii,2) - targets(jj,2));
            if d < minSpacingUm
                accepted(jj) = false;
            end
        end
    end
    targets = targets(accepted, :);
end

% --- 5. Cap to maxCells ---
if size(targets,1) > maxCells
    targets = targets(1:maxCells, :);
end
end

% --- Local helper ---
function value = configField(config, name, default)
if isstruct(config) && isfield(config, name) && ~isempty(config.(name))
    value = config.(name);
else
    value = default;
end
end
