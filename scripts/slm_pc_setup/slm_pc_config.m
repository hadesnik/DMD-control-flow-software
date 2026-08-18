function cfg = slm_pc_config()
%slm_pc_config Machine-local settings for the SLM PC's slm_server.
%
%   Edit the values below on the SLM PC after cloning the repo there.
%   Mirrors scripts/imaging_pc_setup/imaging_pc_config.m in spirit: one
%   place for machine-local paths, so slm_server.m itself stays generic.

cfg = struct();

% msocket listening port for the mask-spec link (DAQ PC connects here).
% Port map: 3043 SI control, 3044 F-stream, 3045 ROI, 3046 SLM server,
% 3047 imaging-PC motor helper. See docs/PORTS.md.
cfg.port = 3046;

% Path to the lab msocket library on THIS machine ('' if already on path).
cfg.msocketPath = '';

% Blink SDK paths — fill in from the Meadowlark install on this PC, then
% vendor the header into vendor/meadowlark/official/ and complete
% docs/blink-api-audit.md before first hardware use.
cfg.dllPath    = '';   % e.g. 'C:\Program Files\Meadowlark Optics\...\Blink_C_wrapper.dll'
cfg.headerPath = '';   % e.g. '...\Blink_C_wrapper.h'
cfg.lutPath    = '';   % wavelength LUT nearest 1038 nm (e.g. the 1064 file)

% Device geometry (validated against the board at initialize).
cfg.nRows = 1024;
cfg.nCols = 1024;

% Protocol-only mode: compute masks, skip all Blink calls. Use while the
% SDK is not yet vendored, and for end-to-end link tests.
cfg.dryRun = true;
end
