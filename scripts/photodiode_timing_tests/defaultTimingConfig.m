function cfg = defaultTimingConfig(override)
% defaultTimingConfig  Canonical configuration struct for the DMD/PLM timing toolset.
%
% Part of the DMD/PLM switching-timing and refresh-rate measurement toolset
% located in scripts/photodiode_timing_tests/.  See scripts/photodiode_timing_tests/README.md for the toolset
% overview and measurement procedure.
%
% USAGE
%   cfg = defaultTimingConfig()
%       Returns the default timing configuration struct.
%
%   cfg = defaultTimingConfig(override)
%       Returns the default struct with fields in OVERRIDE merged on top.
%       Nested struct fields are merged recursively; scalar/vector values in
%       OVERRIDE replace the corresponding defaults entirely.
%
% OUTPUT
%   cfg  - struct with the following top-level fields:
%
%     .hardwareKind        'mock' | 'real'  (default 'mock')
%     .device              String device tag (default 'DMD')
%     .useSynthSignal      Logical.  When true the sweep functions overlay a
%                          synthetic APD + trigger trace, enabling the full
%                          analysis pipeline to run without any hardware.
%     .sampleRateHz        DAQ acquisition sample rate (Hz).
%                          250 000 matches the NI PCIe-6323 aggregate AI cap.
%     .aiRangeV            [lo hi] analog-input voltage range.
%     .channels            Sub-struct: apdAI, trigDI, trigAO channel IDs.
%     .trigger             Sub-struct: mode, voltage levels, pulseWidthFrac.
%     .sweep               Sub-struct: ratesHz, transitionsPerRate.
%     .pattern             Sub-struct: DMD pattern coords, radiusPx, stack.
%     .dmd                 Sub-struct: array geometry, backend SDK params.
%     .paths               Sub-struct: dataDir resolved relative to repo root.
%     .makePlots           Logical.  Enable figure generation in sweep fns.
%     .synth               Sub-struct: synthetic-signal model parameters.
%
% OVERRIDE MERGING
%   If OVERRIDE is provided and is a non-empty struct, each field present in
%   OVERRIDE replaces (scalar/vector) or recursively merges (nested struct)
%   the corresponding default field.  Fields absent from OVERRIDE are left
%   at their defaults.  After merging, two fields are validated:
%     cfg.hardwareKind  must be 'mock' or 'real'
%     cfg.trigger.mode  must be 'external' or 'internal'
%
% ERRORS
%   tfp:timing:defaultTimingConfig:badHardwareKind
%       cfg.hardwareKind is not 'mock' or 'real'.
%   tfp:timing:defaultTimingConfig:badTriggerMode
%       cfg.trigger.mode is not 'external' or 'internal'.
%   tfp:timing:defaultTimingConfig:badOverride
%       The OVERRIDE argument is not a struct.
%
% EXAMPLES
%   % Default config for mock pipeline
%   cfg = defaultTimingConfig();
%
%   % Override sample rate and dataDir for a real-hardware session
%   ov.hardwareKind  = 'real';
%   ov.sampleRateHz  = 200000;
%   ov.paths.dataDir = '/mnt/raid/sessions/2026-06-01';
%   cfg = defaultTimingConfig(ov);
%
% See also: scripts/photodiode_timing_tests/README.md

% -------------------------------------------------------------------------
% Repo root is three fileparts() levels up from this file:
%   scripts/photodiode_timing_tests/defaultTimingConfig.m  ->  scripts/photodiode_timing_tests  ->  scripts  ->  repo root
% -------------------------------------------------------------------------
repoRoot = fileparts(fileparts(fileparts(mfilename('fullpath'))));

% =========================================================================
% Build defaults
% =========================================================================
cfg = struct();

% --- top-level scalars ---
cfg.hardwareKind   = 'mock';    % 'mock' | 'real'
cfg.device         = 'DMD';
cfg.useSynthSignal = true;      % overlay synthetic APD+trigger trace in mock path
cfg.sampleRateHz   = 250000;    % NI PCIe-6323 AI cap ~250 kS/s aggregate
cfg.aiRangeV       = [-10 10];
cfg.makePlots      = true;

% --- channels ---
cfg.channels.apdAI  = 0;               % APD analog-input channel number
cfg.channels.trigDI = 'port0/line0';   % digital-input line for trigger loopback
cfg.channels.trigAO = 0;               % analog-output channel generating trigger square wave

% --- trigger ---
cfg.trigger.mode           = 'external'; % 'external' (DAQ-generated) | 'internal' (device pacer)
cfg.trigger.highV          = 5;
cfg.trigger.lowV           = 0;
cfg.trigger.pulseWidthFrac = 0.5;        % trigger high fraction of each commanded half-period

% --- sweep ---
cfg.sweep.ratesHz            = [50 100 200 500 1000 2000 5000 8000 10000 12500];
cfg.sweep.transitionsPerRate = 200;      % optical transitions captured per rate point

% --- pattern ---
cfg.pattern.onCoords  = [640 400];  % [col row] spot A: on-axis, aligned to pinhole
cfg.pattern.offCoords = [160 400];  % [col row] spot B: off-axis
cfg.pattern.offMode   = 'spot';     % 'spot' | 'alloff'
cfg.pattern.radiusPx  = 14;
cfg.pattern.stack     = [];         % optional logical(nRows,nCols,2) cache filled by sweep

% --- dmd ---
cfg.dmd.nRows          = 800;
cfg.dmd.nCols          = 1280;
cfg.dmd.maxPatternRate = 12500;     % Hz; hard ceiling from DLPC410 spec
cfg.dmd.darkTimeUs     = 0;
cfg.dmd.backend        = struct( ...
    'alpVersion', '4.3', ...
    'dmdType',    'DLP650LNIR', ...
    'dllPath',    '', ...
    'protoFile',  '' ...
);

% --- paths ---
cfg.paths.dataDir = fullfile(repoRoot, 'data');

% --- synthetic signal model ---
%   Describes how the mock signal generator simulates the optical response.
cfg.synth.latency_s      = 20e-6;   % trigger edge -> optical 50% crossing
cfg.synth.riseTime_s     = 12e-6;   % 10-90% rise
cfg.synth.fallTime_s     = 12e-6;   % 10-90% fall
cfg.synth.jitterStd_s    = 1e-6;    % per-transition timing jitter (std dev)
cfg.synth.highV          = 2.0;     % APD output when spot is on (V)
cfg.synth.lowV           = 0.05;    % APD output when spot is off (V)
cfg.synth.noiseStd_v     = 0.01;    % Gaussian noise std added to trace (V)
cfg.synth.maxTrackRateHz = 9000;    % above this rate synthetic device drops transitions

% =========================================================================
% Apply optional override
% =========================================================================
if nargin >= 1
    if isempty(override)
        % empty override is a no-op — caller may pass [] for clarity
    elseif ~isstruct(override)
        error('tfp:timing:defaultTimingConfig:badOverride', ...
            'OVERRIDE must be a struct; got %s.', class(override));
    else
        cfg = mergeStruct(cfg, override);
    end
end

% =========================================================================
% Validate required enumerated fields
% =========================================================================
validKinds = {'mock', 'real'};
if ~ischar(cfg.hardwareKind) || ~any(strcmp(cfg.hardwareKind, validKinds))
    error('tfp:timing:defaultTimingConfig:badHardwareKind', ...
        'cfg.hardwareKind must be ''mock'' or ''real''; got ''%s''.', ...
        char(cfg.hardwareKind));
end

validModes = {'external', 'internal'};
if ~ischar(cfg.trigger.mode) || ~any(strcmp(cfg.trigger.mode, validModes))
    error('tfp:timing:defaultTimingConfig:badTriggerMode', ...
        'cfg.trigger.mode must be ''external'' or ''internal''; got ''%s''.', ...
        char(cfg.trigger.mode));
end

end % defaultTimingConfig


% =========================================================================
% Local helper — recursive struct merge
% =========================================================================
function merged = mergeStruct(base, over)
% mergeStruct  Recursively merge struct OVER onto BASE.
%
%   For each field F in OVER:
%     - If OVER.(F) is a struct AND BASE has a struct field F, recurse.
%     - Otherwise OVER.(F) replaces BASE.(F) entirely (or adds the field if
%       absent from BASE).
%   Fields present only in BASE are preserved unchanged.

merged = base;
overFields = fieldnames(over);

for k = 1 : numel(overFields)
    f = overFields{k};
    overVal = over.(f);

    if isstruct(overVal) && isfield(base, f) && isstruct(base.(f))
        % Both sides have a struct for this field — recurse
        merged.(f) = mergeStruct(base.(f), overVal);
    else
        % Scalar, vector, char, cell, or new field — replace/add directly
        merged.(f) = overVal;
    end
end

end % mergeStruct
