function isResponder = responseClassifier(trace, baselineWin, responseWin, threshold)
%responseClassifier Decide whether a trace shows a response.
%
%   isResponder = responseClassifier(trace, baselineWin, responseWin, threshold)
%
%   Formula:
%     baselineMean = mean(trace(baselineWin(1):baselineWin(2)))
%     baselineStd  = std (trace(baselineWin(1):baselineWin(2)))
%     responseMax  = max (trace(responseWin(1):responseWin(2)))
%     isResponder  = responseMax > baselineMean + threshold * baselineStd
%
%   Inputs:
%     trace       - numeric vector.
%     baselineWin - 2-vector [startIdx endIdx] within 1..numel(trace).
%     responseWin - 2-vector [startIdx endIdx] within 1..numel(trace).
%     threshold   - finite numeric scalar (typical 2..5).
%
%   Output:
%     isResponder - logical scalar.

if ~isnumeric(trace) || ~isvector(trace)
    error('tfp:analysis:responseClassifier:badTrace', ...
        'trace must be a numeric vector.');
end
validateWin(baselineWin, 'baselineWin', numel(trace));
validateWin(responseWin, 'responseWin', numel(trace));
if ~isnumeric(threshold) || ~isscalar(threshold) || ~isfinite(threshold)
    error('tfp:analysis:responseClassifier:badThreshold', ...
        'threshold must be a finite numeric scalar.');
end

baseline = trace(baselineWin(1):baselineWin(2));
response = trace(responseWin(1):responseWin(2));

isResponder = max(response) > mean(baseline) + threshold * std(baseline);
end

function validateWin(win, name, traceLen)
if ~isnumeric(win) || numel(win) ~= 2 || ~all(win == round(win)) ...
        || win(1) < 1 || win(2) > traceLen || win(1) > win(2)
    error('tfp:analysis:responseClassifier:badWin', ...
        '%s must be [startIdx endIdx] (integers) within 1..%d.', ...
        name, traceLen);
end
end
