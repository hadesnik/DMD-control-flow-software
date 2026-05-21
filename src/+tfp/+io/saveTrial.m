function [metaPath, rawPath] = saveTrial(trial, dataDir, options)
%saveTrial Write trial data to split .mat files under <dataDir>/trials/.
%
%   Schema v2 (TASK-P3-05): replaces the single trial_NNNN.mat (schema v1)
%   with two files:
%
%     trial_NNNN_meta.mat  — always written; small (~10 KB).
%       Variable 'meta': trialIdx, status, targetSpec (pattern arrays
%       stripped), powerMw, timingSpec, metadata, responseSummary, error
%       (failed trials only), fileRef (path to raw file or '').
%
%     trial_NNNN_raw.mat   — written when options.saveRawData is true (default).
%       Variable 'raw': trialIdx, status, aiData, frameClock,
%       frameTimestamps, imaging, imagingTiffPath, dmdLog, daqLog, plmLog.
%
%   Migration note: code that loaded trial_NNNN.mat and accessed
%   loaded.trial.* must be updated to load trial_NNNN_meta.mat and access
%   loaded.meta.* (or load trial_NNNN_raw.mat and access loaded.raw.*).
%
%   Inputs:
%     trial   - tfp.trial.Trial instance.
%     dataDir - non-empty char/string path to the session directory.
%     options - optional struct; fields:
%                 .saveRawData (logical, default true)
%
%   Outputs:
%     metaPath - absolute path of the _meta.mat file written.
%     rawPath  - absolute path of the _raw.mat file written, or '' if skipped.

if ~isa(trial, 'tfp.trial.Trial')
    error('tfp:io:saveTrial:badTrial', ...
        'trial must be a tfp.trial.Trial; got %s.', class(trial));
end
if ~(ischar(dataDir) || (isstring(dataDir) && isscalar(dataDir))) ...
        || strlength(string(dataDir)) == 0
    error('tfp:io:saveTrial:badDataDir', ...
        'dataDir must be a non-empty char or string scalar.');
end
if nargin < 3 || isempty(options)
    options = struct();
end
dataDir = char(dataDir);

saveRawData = true;
if isfield(options, 'saveRawData')
    saveRawData = logical(options.saveRawData);
end

trialsDir = fullfile(dataDir, 'trials');
if ~isfolder(trialsDir)
    mkdir(trialsDir);
end

% Strip large pattern arrays from targetSpec to keep meta file small.
tspec = trial.targetSpec;
if isstruct(tspec)
    if isfield(tspec, 'patternRef'), tspec = rmfield(tspec, 'patternRef'); end
    if isfield(tspec, 'plmPattern'), tspec = rmfield(tspec, 'plmPattern'); end
end

timingSpec.duration_s = trial.duration_s;
timingSpec.preStim_s  = trial.preStim_s;
timingSpec.postStim_s = trial.postStim_s;
timingSpec.pulseTrain = trial.pulseTrain;

% Determine raw path before writing meta so fileRef can reference it.
if saveRawData
    rawPath = fullfile(trialsDir, sprintf('trial_%04d_raw.mat', trial.trialIdx));
else
    rawPath = '';
end

meta.trialIdx        = trial.trialIdx;
meta.status          = trial.status;
meta.targetSpec      = tspec;
meta.powerMw         = trial.powerMw;
meta.timingSpec      = timingSpec;
meta.metadata        = trial.metadata;
meta.responseSummary = computeResponseSummary(trial);
meta.fileRef         = rawPath;

% Error detail lives in meta so failed trials can be diagnosed without the
% raw file (important when saveRawData is false for dry runs).
meta.error = [];
if strcmp(trial.status, 'failed') && isstruct(trial.data) && ...
        isfield(trial.data, 'error')
    meta.error = trial.data.error;
end

metaPath = fullfile(trialsDir, sprintf('trial_%04d_meta.mat', trial.trialIdx));
save(metaPath, 'meta', '-v7.3');
info     = dir(metaPath);
metaPath = fullfile(info.folder, info.name);

% Write raw file with all acquired / logged arrays.
if saveRawData
    raw.trialIdx        = trial.trialIdx;
    raw.status          = trial.status;
    raw.aiData          = [];
    raw.frameClock      = [];
    raw.frameTimestamps = [];
    raw.imaging         = [];
    raw.imagingTiffPath = '';
    raw.dmdLog          = [];
    raw.daqLog          = [];
    raw.plmLog          = [];
    if isstruct(trial.data)
        rawFields = {'aiData','frameClock','frameTimestamps','imaging', ...
                     'imagingTiffPath','dmdLog','daqLog','plmLog'};
        for k = 1:numel(rawFields)
            f = rawFields{k};
            if isfield(trial.data, f)
                raw.(f) = trial.data.(f);
            end
        end
    end
    save(rawPath, 'raw', '-v7.3');
    info    = dir(rawPath);
    rawPath = fullfile(info.folder, info.name);
end
end

function summary = computeResponseSummary(trial)
summary.peakDff = NaN;
summary.cellIds = [];
if ~strcmp(trial.status, 'complete'), return; end
if ~isstruct(trial.data), return; end
if ~isfield(trial.data, 'imaging') || isempty(trial.data.imaging), return; end
if ~isfield(trial.data.imaging, 'F'), return; end
BASELINE        = 1000;
dff             = (double(trial.data.imaging.F) - BASELINE) / BASELINE;
summary.peakDff = max(dff(:));
if isstruct(trial.targetSpec) && isfield(trial.targetSpec, 'cellIds')
    summary.cellIds = trial.targetSpec.cellIds;
end
end
