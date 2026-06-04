function phi = steeringPhase(target_xyz_um, params)
%steeringPhase Analytic per-copy steering phase for one 3D-SHOT target.
%
%   phi = tfp.patterns.threeDShot.steeringPhase(target_xyz_um, params)
%
%   target_xyz_um: 1x2 [x y] or 1x3 [x y z] sample-plane µm (z=0 = focal plane).
%   Returns the SLM phase (Ny x Nx, radians) = lateral blazed grating + axial
%   Fresnel lens that steers one copy of the (physically generated) TF disk to
%   the target. Used as the exact single-target solution and as the GS
%   initialiser for the multi-target replication hologram. Pure math.

x = target_xyz_um(1);
y = target_xyz_um(2);
z = 0;
if numel(target_xyz_um) >= 3
    z = target_xyz_um(3);
end

phi = tfp.patterns.threeDShot.lateralGratingPhase(x, y, params) + ...
      tfp.patterns.threeDShot.axialLensPhase(z, params);
end
