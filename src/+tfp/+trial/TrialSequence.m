classdef TrialSequence < handle
    %TrialSequence Ordered collection of tfp.trial.Trial objects.
    %
    %   Static factory methods generate canonical sequence shapes
    %   (PPSF, rapid sequential, power curve). shuffle() randomizes
    %   the order reproducibly via a local RandStream.
    %
    %   See ARCHITECTURE.md "+tfp.+trial".

    properties
        trials           % array of tfp.trial.Trial handles
        randSeed
        description
    end

    methods (Static)
        function seq = generatePPSF(targets, distancesUm, nReps, powerMw)
            %generatePPSF Build a PPSF sequence.
            %
            %   Inputs:
            %     targets     - N x 2 numeric [col row] DMD pixel coords.
            %     distancesUm - vector of offset magnitudes (um), stored on
            %                   trial.metadata.distanceUm.
            %     nReps       - positive integer, reps per (target, distance).
            %     powerMw     - non-negative numeric scalar; same power for
            %                   every trial.
            %
            %   Iteration order: rep outer, target middle, distance inner.
            %
            %   Defaults applied to every Trial (override post-hoc as needed):
            %     duration_s  = 2.0      pulseTrain.pulseWidth_s = 0.1
            %     preStim_s   = 0.5      pulseTrain.nPulses      = 1
            %     postStim_s  = 1.0      pulseTrain.interPulse_s = 0

            validateTargets(targets, 'generatePPSF');
            validateVector(distancesUm, 'distancesUm', 'generatePPSF');
            validatePosInt(nReps, 'nReps', 'generatePPSF');
            validateScalarNonNeg(powerMw, 'powerMw', 'generatePPSF');

            nTargets   = size(targets, 1);
            nDistances = numel(distancesUm);
            nExpected  = nTargets * nDistances * nReps;

            trials(nExpected, 1) = tfp.trial.Trial();
            idx = 0;
            for rep = 1:nReps
                for t = 1:nTargets
                    for d = 1:nDistances
                        idx = idx + 1;
                        tr = trials(idx);
                        tr.trialIdx   = idx;
                        tr.targetSpec = struct( ...
                            'cellIds',   [], ...
                            'dmdCoords', targets(t, :), ...
                            'patternRef', []);
                        tr.powerMw    = powerMw;
                        tr.duration_s = 2.0;
                        tr.pulseTrain = struct( ...
                            'nPulses', 1, 'interPulse_s', 0, 'pulseWidth_s', 0.1);
                        tr.preStim_s  = 0.5;
                        tr.postStim_s = 1.0;
                        tr.metadata   = struct( ...
                            'distanceUm', distancesUm(d), 'repIdx', rep);
                    end
                end
            end

            seq = tfp.trial.TrialSequence();
            seq.trials = trials;
            seq.description = sprintf('PPSF: %d targets x %d distances x %d reps', ...
                nTargets, nDistances, nReps);
        end

        function seq = generateRapidSequential(targets, isi_s, nReps)
            %generateRapidSequential Build a rapid-sequential sequence.
            %
            %   Inputs:
            %     targets - N x 2 numeric [col row] DMD pixel coords.
            %     isi_s   - positive scalar inter-stimulus interval (s).
            %               Stored on trial.metadata.isi_s and used as
            %               trial.duration_s default.
            %     nReps   - positive integer, reps per target.
            %
            %   Iteration order: rep outer, target inner.
            %
            %   powerMw is left empty; set per-trial by the experiment.

            validateTargets(targets, 'generateRapidSequential');
            validateScalarPos(isi_s, 'isi_s', 'generateRapidSequential');
            validatePosInt(nReps, 'nReps', 'generateRapidSequential');

            nTargets  = size(targets, 1);
            nExpected = nTargets * nReps;

            trials(nExpected, 1) = tfp.trial.Trial();
            idx = 0;
            for rep = 1:nReps
                for t = 1:nTargets
                    idx = idx + 1;
                    tr = trials(idx);
                    tr.trialIdx   = idx;
                    tr.targetSpec = struct( ...
                        'cellIds',   [], ...
                        'dmdCoords', targets(t, :), ...
                        'patternRef', []);
                    tr.duration_s = isi_s;
                    tr.pulseTrain = struct( ...
                        'nPulses', 1, 'interPulse_s', 0, 'pulseWidth_s', 0.01);
                    tr.preStim_s  = 0;
                    tr.postStim_s = isi_s;
                    tr.metadata   = struct('isi_s', isi_s, 'repIdx', rep);
                end
            end

            seq = tfp.trial.TrialSequence();
            seq.trials = trials;
            seq.description = sprintf( ...
                'RapidSequential: %d targets x %d reps @ isi=%.3gs', ...
                nTargets, nReps, isi_s);
        end

        function seq = generatePowerCurve(target, powersMw, nReps)
            %generatePowerCurve Build a power-curve sequence at one target.
            %
            %   Inputs:
            %     target   - 1 x 2 numeric [col row] DMD pixel coords.
            %     powersMw - vector of sample-plane powers (mW).
            %     nReps    - positive integer, reps per power level.
            %
            %   Iteration order: rep outer, power inner.

            validateSingleTarget(target, 'generatePowerCurve');
            validateVector(powersMw, 'powersMw', 'generatePowerCurve');
            validatePosInt(nReps, 'nReps', 'generatePowerCurve');

            nPowers   = numel(powersMw);
            nExpected = nPowers * nReps;

            trials(nExpected, 1) = tfp.trial.Trial();
            idx = 0;
            for rep = 1:nReps
                for p = 1:nPowers
                    idx = idx + 1;
                    tr = trials(idx);
                    tr.trialIdx   = idx;
                    tr.targetSpec = struct( ...
                        'cellIds',   [], ...
                        'dmdCoords', target, ...
                        'patternRef', []);
                    tr.powerMw    = powersMw(p);
                    tr.duration_s = 2.0;
                    tr.pulseTrain = struct( ...
                        'nPulses', 1, 'interPulse_s', 0, 'pulseWidth_s', 0.1);
                    tr.preStim_s  = 0.5;
                    tr.postStim_s = 1.0;
                    tr.metadata   = struct('repIdx', rep);
                end
            end

            seq = tfp.trial.TrialSequence();
            seq.trials = trials;
            seq.description = sprintf('PowerCurve: %d powers x %d reps', nPowers, nReps);
        end
    end

    methods
        function obj = shuffle(obj, seed)
            %shuffle Randomly permute trials in place using seed.
            %
            %   Uses a local RandStream so the global rng state is not
            %   modified. seed is stored in obj.randSeed.
            if ~isnumeric(seed) || ~isscalar(seed) || ~isfinite(seed)
                error('tfp:trial:TrialSequence:badSeed', ...
                    'seed must be a finite numeric scalar.');
            end
            s = RandStream('twister', 'Seed', seed);
            perm = randperm(s, numel(obj.trials));
            obj.trials = obj.trials(perm);
            obj.randSeed = seed;
        end
    end
end

% --- Local validators (classdef-file scope) ---

function validateTargets(targets, fnName)
if ~isnumeric(targets) || ndims(targets) > 2 || size(targets, 2) ~= 2 || isempty(targets)
    error('tfp:trial:TrialSequence:badTargets', ...
        '%s: targets must be a non-empty N x 2 numeric [col row]; got size [%s].', ...
        fnName, num2str(size(targets)));
end
end

function validateSingleTarget(target, fnName)
if ~isnumeric(target) || numel(target) ~= 2
    error('tfp:trial:TrialSequence:badTarget', ...
        '%s: target must be a 1 x 2 numeric [col row].', fnName);
end
end

function validateVector(v, name, fnName)
if ~isnumeric(v) || ~isvector(v) || isempty(v)
    error('tfp:trial:TrialSequence:badVector', ...
        '%s: %s must be a non-empty numeric vector.', fnName, name);
end
end

function validatePosInt(n, name, fnName)
if ~isnumeric(n) || ~isscalar(n) || ~isfinite(n) || n < 1 || n ~= round(n)
    error('tfp:trial:TrialSequence:badInt', ...
        '%s: %s must be a positive integer scalar.', fnName, name);
end
end

function validateScalarPos(x, name, fnName)
if ~isnumeric(x) || ~isscalar(x) || ~isfinite(x) || x <= 0
    error('tfp:trial:TrialSequence:badScalar', ...
        '%s: %s must be a positive finite numeric scalar.', fnName, name);
end
end

function validateScalarNonNeg(x, name, fnName)
if ~isnumeric(x) || ~isscalar(x) || ~isfinite(x) || x < 0
    error('tfp:trial:TrialSequence:badScalar', ...
        '%s: %s must be a non-negative finite numeric scalar.', fnName, name);
end
end
