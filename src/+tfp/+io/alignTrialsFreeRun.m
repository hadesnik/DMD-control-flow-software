function [perTrial, perFrame, report] = alignTrialsFreeRun(trials, frameStartSamples, sampleRate, nPlanes, options)
%alignTrialsFreeRun Frame/plane alignment for free-running 3D sessions.
%
%   [perTrial, perFrame, report] = tfp.io.alignTrialsFreeRun( ...
%       trials, frameStartSamples, sampleRate, nPlanes)
%
%   The 3D (async) counterpart of tfp.io.alignTrialsEpisodic: in a 3D
%   session ScanImage free-runs continuous nPlanes ETL volumes for the
%   whole session — ONE long acquisition, no per-trial TIFFs — so there is
%   no per-trial TIFF cross-check. Instead, every decoded frame-clock edge
%   is (a) tagged with its ETL plane via tfp.io.assignFramePlanes
%   (gap-aware mode: a dropped edge would silently shift every later
%   plane assignment), and (b) windowed against each trial's DAQ sample
%   anchors, exactly the episodic aligner's windowing vocabulary.
%
%   Inputs
%   ------
%   trials            - 1xN tfp.trial.Trial array
%   frameStartSamples - uint64 vector from tfp.io.decodeFrameClock
%   sampleRate        - Hz (must match the trials' anchors)
%   nPlanes           - ETL planes per volume (config.etl.n_planes)
%   options           - .volumeStartFrame (default 1) anchor for plane 1
%
%   Outputs
%   -------
%   perTrial - 1xN struct array:
%     .trialIdx, .frame_indices_during_stim, .frame_indices_baseline
%     (1xK uint64 DI frame indices, as episodic), plus the 3D additions:
%     .planes_during_stim / .planes_baseline (1xK plane index per frame),
%     .alignmentConfidence ("high" | "low" | "quarantine" | "none":
%       high       — all this trial's frames carry "exact" plane tags
%       low        — some frames are gap-"corrected"
%       quarantine — any frame "quarantined", or no frames in window
%       none       — trial not complete / missing anchors)
%     .reason
%   perFrame - table: frameIdx, frameStartSample, planeIdx,
%              planeConfidence, trialIdx (NaN outside every trial), phase
%              ("baseline"|"stim"|"post"|"outside")
%   report   - .fatal, .fatalReason, .planeReport (assignFramePlanes
%              report), .nFrames

if nargin < 5 || isempty(options)
    options = struct();
end

frameStartSamples = uint64(frameStartSamples(:)');
K = numel(frameStartSamples);

report = struct('fatal', false, 'fatalReason', "", ...
    'planeReport', struct(), 'nFrames', K);

if any(diff(double(frameStartSamples)) <= 0)
    report.fatal = true;
    report.fatalReason = "non-monotonic frameStartSamples";
end

% --- Plane tags for every frame (gap-aware) --------------------------
planeOpts = struct('fromClockSamples', true, ...
    'volumeStartFrame', double(tfp.util.configField(options, 'volumeStartFrame', 1)));
[planeIdx, planeReport] = tfp.io.assignFramePlanes( ...
    frameStartSamples, nPlanes, planeOpts);
report.planeReport = planeReport;

% --- Per-frame table --------------------------------------------------
frameTrial = nan(1, K);
framePhase = repmat("outside", 1, K);

% alignmentDiscrepancy is NaN throughout — free-run has no per-trial TIFF
% to cross-check frame counts against; the field exists for vocabulary
% parity with alignTrialsEpisodic (Trial.attachEpisodicAlignment).
perTrial = struct('trialIdx', {}, 'frame_indices_during_stim', {}, ...
    'frame_indices_baseline', {}, 'planes_during_stim', {}, ...
    'planes_baseline', {}, 'alignmentDiscrepancy', {}, ...
    'alignmentConfidence', {}, 'reason', {});

fs = double(frameStartSamples);
for t = 1:numel(trials)
    trial = trials(t);
    rec.trialIdx = trial.trialIdx;
    rec.frame_indices_during_stim = uint64([]);
    rec.frame_indices_baseline    = uint64([]);
    rec.planes_during_stim        = [];
    rec.planes_baseline           = [];
    rec.alignmentDiscrepancy      = NaN;

    if ~strcmp(trial.status, 'complete') || ...
            isempty(trial.t_onset_daq_samples) || ...
            isempty(trial.t_offset_daq_samples)
        rec.alignmentConfidence = "none";
        rec.reason = "trial not complete or missing DAQ anchors";
        perTrial(t) = rec; %#ok<AGROW>
        continue
    end
    if abs(double(trial.daq_master_sample_rate_hz) - sampleRate) > ...
            1e-6 * sampleRate
        report.fatal = true;
        report.fatalReason = sprintf("sample-rate mismatch on trial %d", ...
            trial.trialIdx);
    end

    onset  = double(trial.t_onset_daq_samples);
    offset = double(trial.t_offset_daq_samples);
    preN   = round(double(trial.preStim_s)  * sampleRate);
    postN  = round(double(trial.postStim_s) * sampleRate);

    inBaseline = fs >= (onset - preN) & fs < onset;
    inStim     = fs >= onset          & fs <= offset;
    inPost     = fs >  offset         & fs <= (offset + postN);

    rec.frame_indices_baseline    = uint64(find(inBaseline));
    rec.frame_indices_during_stim = uint64(find(inStim));
    rec.planes_baseline           = planeIdx(inBaseline);
    rec.planes_during_stim        = planeIdx(inStim);

    frameTrial(inBaseline | inStim | inPost) = trial.trialIdx;
    framePhase(inBaseline) = "baseline";
    framePhase(inStim)     = "stim";
    framePhase(inPost)     = "post";

    % Confidence from the plane tags this trial actually touched.
    touched = inBaseline | inStim | inPost;
    if ~any(touched)
        rec.alignmentConfidence = "quarantine";
        rec.reason = "no frame-clock edges inside the trial window";
    else
        conf = planeReport.confidence(touched);
        if any(conf == "quarantined")
            rec.alignmentConfidence = "quarantine";
            rec.reason = "plane assignment quarantined by a non-integer frame gap";
        elseif any(conf == "corrected")
            rec.alignmentConfidence = "low";
            rec.reason = "plane assignment corrected across a dropped-frame gap";
        else
            rec.alignmentConfidence = "high";
            rec.reason = "";
        end
    end
    perTrial(t) = rec; %#ok<AGROW>
end

perFrame = table((1:K)', frameStartSamples(:), planeIdx(:), ...
    planeReport.confidence(:), frameTrial(:), framePhase(:), ...
    'VariableNames', {'frameIdx', 'frameStartSample', 'planeIdx', ...
                      'planeConfidence', 'trialIdx', 'phase'});
end
