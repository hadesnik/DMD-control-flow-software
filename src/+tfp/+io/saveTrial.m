function savedPath = saveTrial(trial, dataDir)
%saveTrial Write a single Trial to <dataDir>/trials/trial_NNNN.mat (v7.3).
%
%   Inputs:
%     trial   - tfp.trial.Trial instance.
%     dataDir - non-empty char/string path to the session directory.
%
%   Output:
%     savedPath - absolute path of the .mat file written.

if ~isa(trial, 'tfp.trial.Trial')
    error('tfp:io:saveTrial:badTrial', ...
        'trial must be a tfp.trial.Trial; got %s.', class(trial));
end
if ~(ischar(dataDir) || (isstring(dataDir) && isscalar(dataDir))) ...
        || strlength(string(dataDir)) == 0
    error('tfp:io:saveTrial:badDataDir', ...
        'dataDir must be a non-empty char or string scalar.');
end
dataDir = char(dataDir);

trialsDir = fullfile(dataDir, 'trials');
if ~isfolder(trialsDir)
    mkdir(trialsDir);
end

fname = sprintf('trial_%04d.mat', trial.trialIdx);
fpath = fullfile(trialsDir, fname);
save(fpath, 'trial', '-v7.3');

info = dir(fpath);
savedPath = fullfile(info.folder, info.name);
end
