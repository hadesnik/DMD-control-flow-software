function cfg = slm_pc_config()
%slm_pc_config  Machine-local connection settings for the SLM-PC server script.
%
%   cfg = slm_pc_config() returns a struct of settings used by slm_pc_server.m.
%   It also adds the msocket library to the MATLAB path if the path exists and
%   msocket is not already loaded.
%
%   This is the SINGLE place where SLM-PC network config, hardware backend,
%   calibration file paths, and CGH parameters are defined, so slm_pc_server.m
%   contains no hardcoded machine-specific values.
%
%   Per-machine overrides (PREFERRED — keeps rig-specific paths out of version
%   control):
%     Drop a file named `slm_pc_config_local.m` next to this one.  It is
%     gitignored and must return a struct of fields to override, e.g.
%
%         function local = slm_pc_config_local()
%         local.msocketPath = 'D:\tools\msocket';
%         local.backend     = 'meadowlark';
%         end
%
%     See slm_pc_config_local.m.example (if present) for a template.  Any field
%     the local file omits keeps the rig default below.
%
%   Fields returned:
%     .msocketPath          char    folder containing mslisten/msaccept/etc.
%     .slmPort              double  SLM server listen port                 (3046)
%     .backend              char    'mock' | 'meadowlark'
%     .slmScanCalib_file    char    path to .mat with scanToSlm_affine     ('')
%     .efficiencyMap_file   char    path to .mat with eff/x_um/y_um        ('')
%     .slmConfig            struct  CGH + SLM device config (see below)
%
%   slmConfig sub-fields:
%     .dims                 [nCols nRows]                     [1024 1024]
%     .pitch_um             SLM pixel pitch (µm)                       17
%     .lambda_nm            design wavelength (nm)                    1030
%     .f_ft_um              effective focal length SLM→sample (µm)   16800  %VERIFY
%     .mag                  SLM-plane → BFP magnification               1.0  %VERIFY
%     .n                    immersion refractive index                 1.33
%     .lutFile              path to phase LUT file                       ''
%     .gsIters              weighted-GS iteration count                  20
%     .gsWeighted           use weighted GS (logical)                  true
%     .gsSeed               RNG seed (reserved; GS uses superposition)     0
%     .maxCells             cap on number of hologram targets             20
%     .addressableRadiusUm  max radial distance from optical axis (µm)  150  %VERIFY
%     .minSpacingUm         minimum allowed inter-target spacing (µm)    15  %VERIFY

% --- Rig defaults (shared across this rig's SLM PC; safe to commit) -------

% msocket library folder on the SLM PC. Override in slm_pc_config_local.m.
cfg.msocketPath = 'C:\Users\scanimage\Documents\MATLAB\msocket'; % %VERIFY

% Network
cfg.slmPort = 3046;   % must match RemoteSLM default

% Hardware backend: 'mock' for bench testing; 'meadowlark' for real SLM.
cfg.backend = 'mock';   % %VERIFY — set to 'meadowlark' on the SLM PC

% Calibration files (empty → identity/uniform fallbacks in parsers)
cfg.slmScanCalib_file  = '';   % %VERIFY — set to calibration .mat path
cfg.efficiencyMap_file = '';   % %VERIFY — set to efficiency map .mat path

% CGH + device config (drives both defaultParams() and SLM initialize())
cfg.slmConfig.dims               = [1024, 1024];  % [nCols, nRows]
cfg.slmConfig.pitch_um           = 17;            % µm — Meadowlark 1024 pitch
cfg.slmConfig.lambda_nm          = 1030;          % nm — NKT/CARBIDE NIR
cfg.slmConfig.f_ft_um            = 16800;         % µm — effective focal length %VERIFY
cfg.slmConfig.mag                = 1.0;           % SLM-plane → BFP mag        %VERIFY
cfg.slmConfig.n                  = 1.33;          % water immersion
cfg.slmConfig.lutFile            = '';            % phase LUT file path         %VERIFY
cfg.slmConfig.gsIters            = 20;            % GS iterations
cfg.slmConfig.gsWeighted         = true;
cfg.slmConfig.gsSeed             = 0;
cfg.slmConfig.maxCells           = 20;            % hologram target cap
cfg.slmConfig.addressableRadiusUm = 150;          % µm, flat-top beam radius    %VERIFY
cfg.slmConfig.minSpacingUm       = 15;            % µm, min inter-cell spacing  %VERIFY

% --- Per-machine overrides (slm_pc_config_local.m; gitignored) -----------
if exist('slm_pc_config_local', 'file') == 2
    local = slm_pc_config_local();
    fn = fieldnames(local);
    for k = 1:numel(fn)
        cfg.(fn{k}) = local.(fn{k});
    end
end

% --- Make msocket reachable (no-op if already on the path) ---------------
if ~exist('mslisten', 'file')
    if isfolder(cfg.msocketPath)
        addpath(genpath(cfg.msocketPath));
    else
        warning('slm_pc_config:noMsocket', ...
            ['msocket is not on the MATLAB path and msocketPath does not exist:\n' ...
             '  %s\n' ...
             'Create slm_pc_config_local.m with the correct cfg.msocketPath.'], ...
            cfg.msocketPath);
    end
end
end
