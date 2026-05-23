function [perTrial, perFrame] = alignTrialsToFrames(trials, frameStartSamples)
%alignTrialsToFrames Post-hoc map between trials and ScanImage frames.
%
%   Builds two complementary views of the stim/frame relationship:
%
%     perTrial - 1xN struct array (one entry per input trial) with the
%                frame index lists defined in docs/SYNC_FRAME.md §6.2:
%                  .trialIdx                  scalar (echoed from Trial)
%                  .frame_indices_during_stim 1xK uint64 row vector
%                  .frame_indices_baseline    1xK uint64 row vector
%                Empty rows are returned (not NaN) when the corresponding
%                window contains no frames or when the trial has no DAQ
%                sample anchors set.
%
%     perFrame - MATLAB table with one row per element of
%                frameStartSamples (i.e. one row per ScanImage frame):
%                  frameIdx         uint64  1-based frame index
%                  frameStartSample uint64  DAQ sample of rising edge
%                  trialIdx         double  trialIdx of the assigned
%                                           trial, NaN if the frame
%                                           falls outside every window
%                  phase            string  "stim" | "baseline" | "none"
%
%   Window definitions (all in DAQ sample units, sample rate is taken
%   from each trial's daq_master_sample_rate_hz):
%     stim     window: [t_onset_daq_samples, t_offset_daq_samples]
%                      (inclusive both ends)
%     baseline window: [t_onset_daq_samples - preStim_s*sampleRate,
%                       t_onset_daq_samples)
%
%   Phase priority when a frame falls in multiple windows:
%     stim > baseline > none. Among colliding stim windows, the trial
%     that appears earlier in the input array wins; a one-shot warning
%     tfp:io:alignTrialsToFrames:overlap is issued.
%
%   This function does NOT mutate the input trials. Apply the results
%   to a Trial via tfp.trial.Trial.attachFrameAlignment(...).
%
%   Inputs:
%     trials            - vector of tfp.trial.Trial objects, or [].
%     frameStartSamples - numeric vector of frame rising-edge DAQ
%                         sample indices (output of decodeFrameClock).
%                         Cast to uint64 internally.

if ~isempty(trials) && ~isa(trials, 'tfp.trial.Trial')
    error('tfp:io:alignTrialsToFrames:badTrials', ...
        'trials must be a tfp.trial.Trial array or empty; got %s.', ...
        class(trials));
end
if ~isnumeric(frameStartSamples) && ~islogical(frameStartSamples)
    error('tfp:io:alignTrialsToFrames:badFrames', ...
        'frameStartSamples must be a numeric vector; got %s.', ...
        class(frameStartSamples));
end
if ~isempty(frameStartSamples) && ~isvector(frameStartSamples)
    error('tfp:io:alignTrialsToFrames:badFrames', ...
        'frameStartSamples must be a vector.');
end

fss       = uint64(frameStartSamples(:));
fssDouble = double(fss);
nFrames   = numel(fss);
nTrials   = numel(trials);

trialIdxCol = nan(nFrames, 1);
phaseCol    = strings(nFrames, 1);
phaseCol(:) = "none";

emptyEntry = struct( ...
    'trialIdx',                  NaN, ...
    'frame_indices_during_stim', uint64(zeros(1, 0)), ...
    'frame_indices_baseline',    uint64(zeros(1, 0)));
if nTrials == 0
    perTrial = repmat(emptyEntry, 1, 0);
else
    perTrial = repmat(emptyEntry, 1, nTrials);
end

windows = repmat(struct('onset', NaN, 'offset', NaN, 'baseline', NaN), ...
    1, nTrials);
for i = 1:nTrials
    windows(i) = trialWindow(trials(i));
    perTrial(i).trialIdx = trials(i).trialIdx;
end

% First pass: per-trial frame lists + baseline assignment.
for i = 1:nTrials
    w = windows(i);
    if isnan(w.onset)
        continue
    end
    inStim     = fssDouble >= w.onset    & fssDouble <= w.offset;
    inBaseline = fssDouble >= w.baseline & fssDouble <  w.onset;

    perTrial(i).frame_indices_during_stim = uint64(reshape(find(inStim),     1, []));
    perTrial(i).frame_indices_baseline    = uint64(reshape(find(inBaseline), 1, []));

    sel = inBaseline & phaseCol == "none";
    trialIdxCol(sel) = trials(i).trialIdx;
    phaseCol(sel)    = "baseline";
end

% Second pass: stim assignment (overrides baseline, but the earliest
% trial wins among colliding stim windows).
overlapWarned = false;
for i = 1:nTrials
    w = windows(i);
    if isnan(w.onset)
        continue
    end
    inStim = fssDouble >= w.onset & fssDouble <= w.offset;
    if ~overlapWarned && any(inStim & phaseCol == "stim")
        warning('tfp:io:alignTrialsToFrames:overlap', ...
            ['Overlapping stim windows detected; ' ...
             'earliest trial in input order wins.']);
        overlapWarned = true;
    end
    sel = inStim & phaseCol ~= "stim";
    trialIdxCol(sel) = trials(i).trialIdx;
    phaseCol(sel)    = "stim";
end

frameIdx         = uint64((1:nFrames).');
frameStartSample = fss;
perFrame = table(frameIdx, frameStartSample, trialIdxCol, phaseCol, ...
    'VariableNames', {'frameIdx', 'frameStartSample', 'trialIdx', 'phase'});
end

function w = trialWindow(tr)
%trialWindow Compute [onset, offset, baselineStart] in double-DAQ-samples
%   for one Trial, or NaNs if the trial has no usable sample anchor.
onset  = double(tr.t_onset_daq_samples);
offset = double(tr.t_offset_daq_samples);
sr     = double(tr.daq_master_sample_rate_hz);
preS   = tr.preStim_s;
if isempty(preS) || ~isnumeric(preS)
    preS = 0;
end

if isnan(onset) || isnan(sr)
    w = struct('onset', NaN, 'offset', NaN, 'baseline', NaN);
    return
end
if isnan(offset)
    offset = onset;   % zero-length stim window if offset wasn't recorded
end
w = struct( ...
    'onset',    onset, ...
    'offset',   offset, ...
    'baseline', onset - double(preS) * sr);
end
