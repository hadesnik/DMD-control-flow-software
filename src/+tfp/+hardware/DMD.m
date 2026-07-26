classdef DMD < handle
    %DMD Abstract interface for DMD pattern projectors.
    %   Subclasses include MockDMD (simulator) and DLP650LNIR_DMD (real
    %   hardware via ViALUX ALP-4.3). Experiment code talks to this
    %   interface, never to a concrete class.

    properties (Abstract, SetAccess = protected)
        nRows           % e.g., 800 for DLP650LNIR
        nCols           % e.g., 1280
        maxPatternRate  % Hz, binary patterns
        isInitialized
    end

    methods (Abstract)
        initialize(obj, config)

        % patterns: logical(nRows, nCols, nPatterns)
        % options: struct with .exposureUs, .darkTimeUs, .triggerMode
        loadPatternSequence(obj, patterns, options)

        armSequence(obj)
        softTrigger(obj)
        advanceToPattern(obj, idx)
        status = getStatus(obj)
        cleanup(obj)
    end

    methods
        function pxCount = activePixelCount(obj, patternIdx)
            % Useful for power-per-target calculations
            error('not implemented');
        end
    end

    % ====================================================================== %
    % Pattern safety (shared by all DMD subclasses) — TASK-BU T-BU-2a
    % ====================================================================== %
    % loadPatternSequence is the single path every pattern crosses on its way
    % to the chip, so that is where the pattern-domain interlocks live. This is
    % the same argument that put the laser-power check inside
    % tfp.hardware.DAQ (checkLaserAO_ / configureLaserSafety) rather than in
    % each experiment script: one choke point covers the Sequencer, the
    % calibration routines, the scripts and every experiment at once.
    %
    % TWO GUARDS RUN ON EVERY LOAD. Neither subsumes the other:
    %   1. tfp.util.assertPatternInPatch  — every ON mirror must lie inside the
    %      illuminated patch (there is no piShaper on the bring-up path, so the
    %      chip is lit by a raw Gaussian). Needs the PATTERN only.
    %   2. tfp.util.assertPulseEnergySafe — pupil pulse-energy (air-ionisation)
    %      interlock. Needs the PATTERN *and* the commanded photostim-laser
    %      voltage. It is the only guard that can see a high-fill pattern:
    %      assertLaserPowerSafe on the DAQ sees a voltage and a duration and
    %      cannot tell a 2%-fill stim frame from an all-ON alignment frame.
    %      It is also conservative in the OPPOSITE direction from
    %      assertLaserPowerSafe (lowering the rep rate lowers average power but
    %      RAISES pulse energy) — see the rep-rate inversion in that function's
    %      header. Do not merge the two; do not drop either.
    %
    % HOW THE DMD LEARNS THE LASER VOLTAGE (the awkward bit)
    % ------------------------------------------------------
    % The DMD does not own ao3, so it cannot read the commanded voltage. It is
    % therefore told, and the DEFAULT IS THE WORST CASE: until somebody says
    % otherwise the DMD assumes the laser could be at FULL SCALE
    % (laser.modulation_voltage_max, 5 V = 100% = 40 W = 400 uJ/pulse at
    % 100 kHz) while this pattern is displayed. A DMD that has not been told
    % the voltage does NOT skip the check — it fails the dangerous patterns.
    % Because sparse patterns (fill < pupil_interlock_fill_fraction) are exempt
    % regardless of voltage, the conservative default only bites on exactly the
    % patterns the interlock exists for: high-fill / all-ON alignment frames.
    %
    % Four ways to narrow it, highest precedence first — all explicit, and all
    % recorded in the backend's own event log on every load:
    %   (a) options.laserVoltageV on the loadPatternSequence call — the caller
    %       supplies the voltage it is about to command for this sequence.
    %   (b) setAssumedLaserVoltage(v, reason) — a sticky, reasoned declaration,
    %       e.g. setAssumedLaserVoltage(0, 'laser shuttered for alignment')
    %       before projecting an all-ON checkerboard.
    %   (c) config.laser.dmd_assumed_voltage_v — a rig-configured ceiling.
    %   (d) config.laser.modulation_voltage_max — the full-scale worst case.
    % There is deliberately NO "off" switch for this check, matching
    % assertPulseEnergySafe's deliberate lack of an override form.
    %
    % PATCH GEOMETRY. The patch check runs whenever the config declares patch
    % geometry (dmd.patchCenterPx / patchRadiusPx / patchMaxRadiusPx, or the
    % legacy roiHalfWidthPx alias) — i.e. real.yaml and dli4130.yaml — and is
    % skipped, WITH A LOGGED REASON on every load, when it does not (mock.yaml
    % declares no optics at all). The skip is not a bypass of a configured
    % guard: with no declared geometry there is nothing to test against, and
    % inventing the real rig's 278 px design patch for a config that never
    % claimed those optics would assert geometry nobody measured. Any rig that
    % wants enforcement without spelling out the geometry sets
    % dmd.enforcePatch = true, which forces the check against the
    % tfp.util.opticalModel defaults. That knob only ever TIGHTENS the check.
    properties (Access = protected)
        patternSafetyCfg_ = struct( ...
            'opticalConfig',         struct('dmd', struct(), 'laser', struct()), ...
            'patchGeometryDeclared', false, ...  % config named a patch
            'forcePatchCheck',       false, ...  % dmd.enforcePatch
            'assumedLaserVoltageV',  5, ...      % V — full-scale worst case
            'voltageSource',         'default worst case: full scale (no laser config seen)')
    end

    methods
        function configurePatternSafety(obj, config)
            %configurePatternSafety Set the pattern-safety policy from config.
            %   dmd.configurePatternSafety(config)
            %
            %   config may be a full loaded config (with .dmd and/or .laser
            %   sub-structs) or a bare dmd sub-struct — which is how each
            %   backend's initialize() self-configures, so a directly
            %   constructed DMD is protected even when makeHardware is not
            %   used (the same guarantee tfp.hardware.DAQ gives for the laser
            %   policy). Sub-structs are MERGED, so a later laser-only or
            %   dmd-only call does not discard what the other one set.
            %
            %   Recognised keys (all optional; missing ones keep their value):
            %     dmd.patchCenterPx / patchRadiusPx / patchMaxRadiusPx /
            %        roiHalfWidthPx   -> declaring any of these turns the patch
            %                            check ON; the values themselves are
            %                            read by tfp.util.opticalModel.
            %     dmd.enforcePatch    -> force the patch check on even with no
            %                            geometry declared (tightens only).
            %     laser.dmd_assumed_voltage_v -> worst-case ao3 voltage to
            %                            assume for the pupil interlock.
            %     laser.modulation_voltage_max -> full-scale fallback for it.
            %     laser.rep_rate_hz / max_power_w / max_pulse_energy_uj_pupil /
            %     laser.pupil_interlock_fill_fraction /
            %     laser.autoConfirmPulseEnergy -> passed straight through to
            %                            tfp.util.assertPulseEnergySafe.
            %
            %   NOTE autoConfirmPulseEnergy is deliberately SEPARATE from
            %   autoConfirmPower and defaults false even in mock configs, so
            %   the mock rig's autoConfirmPower:true cannot accidentally opt
            %   past the pupil confirmation band (TASKS.md T-BU-1d).
            if nargin < 2 || ~isstruct(config) || isempty(fieldnames(config))
                return
            end

            hasDmd   = isfield(config, 'dmd')   && isstruct(config.dmd);
            hasLaser = isfield(config, 'laser') && isstruct(config.laser);
            if hasDmd
                dmdCfg = config.dmd;
            elseif hasLaser
                dmdCfg = [];            % laser-only call
            else
                dmdCfg = config;        % bare dmd sub-struct (initialize path)
            end

            cfg = obj.patternSafetyCfg_;
            opt = cfg.opticalConfig;
            if ~isempty(dmdCfg)
                opt.dmd = dmdCfg;
            end
            if hasLaser
                opt.laser = config.laser;
            end

            % Fail fast on a malformed optical block: better to throw here, at
            % construction, than mid-experiment on the first pattern load.
            tfp.util.opticalModel(opt);

            cfg.opticalConfig = opt;

            % Patch geometry declared? Any one of the four keys is enough.
            geomKeys = {'patchCenterPx', 'patchRadiusPx', 'patchMaxRadiusPx', ...
                        'roiHalfWidthPx'};
            declared = false;
            for i = 1:numel(geomKeys)
                if isstruct(opt.dmd) && isfield(opt.dmd, geomKeys{i}) ...
                        && ~isempty(opt.dmd.(geomKeys{i}))
                    declared = true;
                    break
                end
            end
            cfg.patchGeometryDeclared = declared;
            cfg.forcePatchCheck = logical(configField(opt.dmd, 'enforcePatch', ...
                cfg.forcePatchCheck));

            % Worst-case ao3 voltage. Only a laser block can narrow it.
            if hasLaser
                v = configField(config.laser, 'dmd_assumed_voltage_v', []);
                if ~isempty(v)
                    cfg.assumedLaserVoltageV = double(v);
                    cfg.voltageSource = ...
                        'config laser.dmd_assumed_voltage_v (configured ceiling)';
                else
                    v = configField(config.laser, 'modulation_voltage_max', []);
                    if ~isempty(v)
                        cfg.assumedLaserVoltageV = double(v);
                        cfg.voltageSource = ...
                            'config laser.modulation_voltage_max (full-scale worst case)';
                    end
                end
            end

            obj.patternSafetyCfg_ = cfg;
        end

        function setAssumedLaserVoltage(obj, voltageV, reason)
            %setAssumedLaserVoltage Declare the ao3 voltage this DMD runs under.
            %   dmd.setAssumedLaserVoltage(voltageV, reason)
            %
            %   Narrows the worst-case assumption used by the pupil
            %   pulse-energy interlock. The classic use is an alignment frame
            %   projected with the laser shuttered:
            %     dmd.setAssumedLaserVoltage(0, 'laser shuttered for alignment')
            %   The declaration is sticky and is echoed (with its reason) in
            %   the backend's log payload on every subsequent load, so an
            %   operator can always see what the guard was told. It NARROWS
            %   nothing else: fill, rep rate and the 68 uJ pupil limit are
            %   untouched, and a wrong declaration cannot disable the check.
            if ~isnumeric(voltageV) || ~isscalar(voltageV) || ~isreal(voltageV) ...
                    || ~isfinite(voltageV) || voltageV < 0
                error('tfp:hardware:DMD:badLaserVoltage', ...
                    ['voltageV must be a finite non-negative scalar (volts on ' ...
                     'the photostim-laser AO channel); got %s.'], ...
                    describeValue(voltageV));
            end
            if nargin < 3 || isempty(reason)
                reason = 'no reason given';
            end
            obj.patternSafetyCfg_.assumedLaserVoltageV = double(voltageV);
            obj.patternSafetyCfg_.voltageSource = sprintf( ...
                'declared via setAssumedLaserVoltage: %s', char(reason));
        end

        function s = patternSafetyStatus(obj)
            %patternSafetyStatus Resolved pattern-safety policy, for inspection.
            %   Fields: .patchCheckEnabled, .patchGeometryDeclared,
            %   .forcePatchCheck, .assumedLaserVoltageV, .voltageSource,
            %   .opticalConfig.
            cfg = obj.patternSafetyCfg_;
            s = struct( ...
                'patchCheckEnabled',     cfg.patchGeometryDeclared || cfg.forcePatchCheck, ...
                'patchGeometryDeclared', cfg.patchGeometryDeclared, ...
                'forcePatchCheck',       cfg.forcePatchCheck, ...
                'assumedLaserVoltageV',  cfg.assumedLaserVoltageV, ...
                'voltageSource',         cfg.voltageSource, ...
                'opticalConfig',         cfg.opticalConfig);
        end
    end

    methods (Access = protected)
        function info = checkPatternSafety_(obj, patterns, context, options)
            %checkPatternSafety_ Run BOTH pattern interlocks. Call from every
            %backend's loadPatternSequence, after argument validation and
            %BEFORE any device or object state is mutated, so a rejected
            %sequence never reaches the chip.
            %
            %   info = obj.checkPatternSafety_(patterns, context, options)
            %     patterns - logical H x W [x N] as passed to loadPatternSequence
            %     context  - caller tag, e.g. 'DLP650LNIR_DMD.loadPatternSequence'
            %     options  - the load options struct; .laserVoltageV (optional)
            %                overrides the assumed ao3 voltage for this load.
            %   info is a summary intended for the caller's event log.
            cfg = obj.patternSafetyCfg_;

            % Per-load voltage supplied by the caller wins over the standing
            % assumption; anything else falls back to the worst case.
            voltageV = cfg.assumedLaserVoltageV;
            source   = cfg.voltageSource;
            if nargin >= 4 && isstruct(options) && isfield(options, 'laserVoltageV') ...
                    && ~isempty(options.laserVoltageV)
                v = options.laserVoltageV;
                if ~isnumeric(v) || ~isreal(v) || any(~isfinite(v(:))) || any(v(:) < 0)
                    error('tfp:hardware:DMD:badLaserVoltage', ...
                        ['options.laserVoltageV must be finite and non-negative ' ...
                         '(volts, scalar or waveform).']);
                end
                voltageV = max(double(v(:)));
                source   = 'options.laserVoltageV supplied by the caller';
            end

            info = struct( ...
                'patchChecked',         false, ...
                'patchSkipReason',      '', ...
                'patchInfo',            [], ...
                'pulseChecked',         false, ...
                'pulseInfo',            [], ...
                'assumedLaserVoltageV', voltageV, ...
                'voltageSource',        source);

            if isempty(patterns) || size(patterns, 3) == 0
                info.patchSkipReason = 'empty pattern array — nothing will be projected';
                return
            end

            % --- (1) Pupil pulse energy: ALWAYS, on every load ---------------
            % Run first: this is the interlock that protects the hardware
            % itself (a high-fill frame ionises air at the relay pupil),
            % independent of where on the chip the mirrors are.
            info.pulseInfo    = obj.checkPulseEnergy_(patterns, voltageV, context);
            info.pulseChecked = true;

            % --- (2) Patch containment --------------------------------------
            if cfg.patchGeometryDeclared || cfg.forcePatchCheck
                info.patchInfo = tfp.util.assertPatternInPatch(patterns, ...
                    cfg.opticalConfig, struct('context', context));
                info.patchChecked = true;
            else
                info.patchSkipReason = ['no patch geometry declared in config ' ...
                    '(dmd.patchCenterPx / patchRadiusPx / roiHalfWidthPx absent) — ' ...
                    'nothing to test the pattern against. Declare the patch, or ' ...
                    'set dmd.enforcePatch = true to check against the ' ...
                    'tfp.util.opticalModel design defaults.'];
            end
        end

        function worst = checkPulseEnergy_(obj, patterns, voltageV, context)
            %checkPulseEnergy_ tfp.util.assertPulseEnergySafe over a whole stack.
            %   Evaluated in chunks: the guard converts each slice to double to
            %   compute the array- and patch-restricted fills, which is ~8 MB
            %   per full-chip slice, and calibration routines load stacks of
            %   dozens of patterns. Chunking bounds the peak allocation without
            %   changing the result — every slice is still evaluated, and the
            %   worst (highest fill) governs. Chunk-local slice indices in the
            %   guard's message are translated back to global ones in the
            %   context prefix.
            cfg   = obj.patternSafetyCfg_;
            [H, W, N] = size(patterns, 1, 2, 3);

            maxElems  = 8e6;                                   % ~64 MB of double
            chunkSize = max(1, floor(maxElems / max(1, H * W)));

            worst = [];
            for k0 = 1:chunkSize:N
                idx = k0:min(k0 + chunkSize - 1, N);
                if N > chunkSize
                    ctx = sprintf('%s, patterns %d-%d of %d', ...
                        context, idx(1), idx(end), N);
                else
                    ctx = context;
                end
                try
                    chunkInfo = tfp.util.assertPulseEnergySafe( ...
                        patterns(:, :, idx), voltageV, cfg.opticalConfig);
                catch err
                    throw(prefixError(err, ctx));
                end
                chunkInfo.worstIndex = idx(1) + chunkInfo.worstIndex - 1;
                if isempty(worst) || chunkInfo.fillFraction > worst.fillFraction
                    worst = chunkInfo;
                end
            end
        end
    end
end

% ========================================================================== %
% Local helpers

function err = prefixError(err, context)
%prefixError Tag a guard's error with the backend that rejected the pattern.
%   The identifier is preserved verbatim so callers and tests keep matching on
%   tfp:util:assertPulseEnergySafe:<reason>; only the message gains the tag
%   (assertPatternInPatch does this itself via options.context).
if isempty(err.identifier)
    return      % nothing to re-throw it as; pass the original through
end
err = MException(err.identifier, '[%s] %s', context, err.message);
end

function s = describeValue(v)
%describeValue Short, safe rendering of a rejected argument for an error message.
if isnumeric(v) && isscalar(v)
    s = num2str(v);
elseif isnumeric(v) || islogical(v) || ischar(v)
    s = mat2str(size(v));
    s = sprintf('a %s %s', s, class(v));
else
    s = sprintf('a %s', class(v));
end
end

function value = configField(s, name, default)
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    value = s.(name);
else
    value = default;
end
end
