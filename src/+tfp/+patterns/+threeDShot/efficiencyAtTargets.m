function eta = efficiencyAtTargets(targets_xyz, effMap)
%efficiencyAtTargets Query photostimulation efficiency at a set of target locations.
%
%   eta = tfp.patterns.threeDShot.efficiencyAtTargets(targets_xyz, effMap)
%
%   Returns the efficiency weight η ∈ (0,1] at each target location.  For a
%   'uniform' map, all weights are 1.  For a 'grid' map the efficiency is
%   bilinearly interpolated; targets that fall outside the grid or have a
%   grid value ≤ 0 are assigned the minimum positive value found in the grid
%   (rather than NaN or 0, which would cause division problems in the GSW
%   algorithm).
%
%   Inputs:
%     targets_xyz - N×2 or N×3 double.  Only the (x,y) columns are used;
%                   z is ignored.  Coordinates in SLM sample-plane µm.
%     effMap      - struct from loadEfficiencyMap.
%
%   Output:
%     eta - N×1 double, efficiency weights in (0,1].
%
%   Pure: no hardware, no file I/O, no side effects.

N   = size(targets_xyz, 1);
xq  = targets_xyz(:, 1);   % N×1
yq  = targets_xyz(:, 2);   % N×1

switch effMap.type
    case 'uniform'
        eta = ones(N, 1);

    case 'grid'
        % interp2 expects (Xq, Yq) as row vectors by default but accepts
        % column vectors fine.  'linear' with an extrap value of NaN for
        % out-of-range points (we replace those below).
        eta = interp2(effMap.x_um, effMap.y_um, effMap.eff, ...
                      xq, yq, 'linear', NaN);

        % Replace out-of-range or non-positive values with the minimum
        % positive efficiency present in the map.
        eff_vals = effMap.eff(:);
        minEff   = min(eff_vals(eff_vals > 0));
        if isempty(minEff)
            minEff = 1;   % degenerate map — treat as uniform
        end

        bad = isnan(eta) | (eta <= 0);
        eta(bad) = minEff;

    otherwise
        % Unknown type — return uniform rather than error, to allow forward
        % compatibility.
        eta = ones(N, 1);
end
end
