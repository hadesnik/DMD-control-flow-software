function cfg = imaging_pc_config()
%imaging_pc_config  Machine-local connection settings for the imaging-PC scripts.
%
%   cfg = imaging_pc_config() returns a struct of settings used by
%   SIStreamSetup, si_send_rois, and SIStreamTeardown.  It also adds the
%   msocket library to the MATLAB path if it is not already there.
%
%   This is the SINGLE place msocket path / scope-PC IP / ports are defined,
%   so the individual scripts contain no hardcoded machine-specific values.
%
%   Per-machine overrides (PREFERRED — keeps paths out of version control):
%     Drop a file named `imaging_pc_config_local.m` next to this one.  It is
%     gitignored and must return a struct of fields to override, e.g.
%
%         function local = imaging_pc_config_local()
%         local.msocketPath = 'D:\tools\msocket';
%         local.scopePcIp   = '10.0.0.42';
%         end
%
%     See imaging_pc_config_local.m.example for a template.  Any field the
%     local file omits keeps the rig default below.
%
%   Fields returned:
%     .msocketPath  char    folder containing mssend/msrecv (added to path)
%     .scopePcIp    char    IP address of the DAQ / scope PC
%     .controlPort  double  stim-metadata + ROI handshake channel  (3043)
%     .streamPort   double  per-frame F streaming channel          (3044)
%     .roiPort      double  ROI-centroid handoff channel           (3045)

% --- Rig defaults (shared across this rig's imaging PC; safe to commit) ---
cfg.msocketPath = 'C:\Users\scanimage\Documents\MATLAB\msocket';
cfg.scopePcIp   = '128.32.177.203';
cfg.controlPort = 3043;   % control / stim metadata (SImsocketPrep on scope PC)
cfg.streamPort  = 3044;   % live per-frame F streaming (SIStreamSetup)
cfg.roiPort     = 3045;   % ROI centroid handoff (si_send_rois)

% --- Per-machine overrides (imaging_pc_config_local.m; gitignored) ---
if exist('imaging_pc_config_local', 'file') == 2
    local = imaging_pc_config_local();
    fn = fieldnames(local);
    for k = 1:numel(fn)
        cfg.(fn{k}) = local.(fn{k});
    end
end

% --- Make msocket reachable (no-op if already on the path) ---
if ~exist('mssend', 'file')
    if isfolder(cfg.msocketPath)
        addpath(genpath(cfg.msocketPath));
    else
        warning('imaging_pc_config:noMsocket', ...
            ['msocket is not on the MATLAB path and msocketPath does not exist:\n' ...
             '  %s\n' ...
             'Create imaging_pc_config_local.m with the correct cfg.msocketPath.'], ...
            cfg.msocketPath);
    end
end
end
