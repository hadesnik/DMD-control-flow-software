function runtests()
%runtests Run the full Phase 1 test suite.
%   Adds src/ to the MATLAB path, discovers and runs all tests under
%   tests/, prints a summary, and exits with nonzero status if any
%   test failed.
%
%   Interactive: `runtests` at the MATLAB prompt.
%   CI / terminal: `matlab -batch "runtests"` — process exits with
%   code 1 on failure, 0 on full pass.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, 'src'));

% macOS MATLAB is not headless under -batch alone: it keeps a window-server
% connection, so every figure the calibration/experiment code opens becomes a
% real window that steals focus. Suppress them for batch runs only; figures are
% still built (invisibly), so tests that save or inspect them are unaffected.
if batchStartupOptionUsed
    set(groot, 'DefaultFigureVisible', 'off');
end

import matlab.unittest.TestSuite;
import matlab.unittest.TestRunner;

suite  = TestSuite.fromFolder(fullfile(thisDir, 'tests'));
runner = TestRunner.withTextOutput;
result = runner.run(suite);

total    = numel(result);
passed   = nnz([result.Passed]);
failed   = nnz([result.Failed]);
filtered = nnz([result.Incomplete]);

fprintf('\n========================================\n');
fprintf('Test summary: %d total | %d passed | %d failed | %d filtered\n', ...
    total, passed, failed, filtered);
fprintf('========================================\n');

if failed > 0
    if batchStartupOptionUsed
        exit(1);  % matlab -batch "runtests" returns nonzero.
    else
        error('runtests:failed', '%d test(s) failed', failed);
    end
end
end
