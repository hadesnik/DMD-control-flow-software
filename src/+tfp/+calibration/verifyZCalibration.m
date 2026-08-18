function report = verifyZCalibration(zcal, found, options)
%verifyZCalibration Cross-check the indirect z-calibration against marks.
%
%   report = tfp.calibration.verifyZCalibration(zcal, found)
%   report = tfp.calibration.verifyZCalibration(zcal, found, options)
%
%   zcal:  composed indirect calibration (tfp.calibration.composeZCalibration)
%   found: direct-method mark localisations (tfp.calibration.locateMarksInStack)
%
%   For each mark: the indirect calibration PREDICTS which imaging plane a
%   stimulation at dzCmdUm lands in (nearest plane by
%   |slm depth - etlPlaneZUm|); the direct method OBSERVED the darkest
%   plane. Agreement per mark, plus the depth residual where the composed
%   plane depths allow one, decides pass/fail.
%
%   options:
%     .tolUm        — max |predicted depth - observed plane depth| counted
%                     as agreement (default 10 um; well under the 32.6 um
%                     axial FWHM)
%     .mockResponse — bypass the operator acknowledgement prompt in tests
%                     (the verifyScanFieldComposition pattern): true/false
%                     stands in for the y/n answer.
%
%   report: .perMark (struct array: dzCmdUm, predictedPlane, observedPlane,
%           residualUm, agree), .nAgree, .nTotal, .pass (all marks agree),
%           .acknowledged (operator saw the table)

if nargin < 3 || isempty(options)
    options = struct();
end
tolUm = double(tfp.util.configField(options, 'tolUm', 10));

if ~isstruct(zcal) || ~strcmp(tfp.util.configField(zcal, 'kind', ''), 'z_composed')
    error('tfp:calibration:verifyZCalibration:badZcal', ...
        'zcal must be a z_composed struct (composeZCalibration).');
end
if isempty(found)
    error('tfp:calibration:verifyZCalibration:noMarks', ...
        'found is empty — nothing to verify.');
end

perMark = struct('dzCmdUm', {}, 'predictedPlane', {}, 'observedPlane', {}, ...
    'residualUm', {}, 'agree', {});
for m = 1:numel(found)
    dz = found(m).dzCmdUm;
    % Indirect prediction: depth of this command, nearest imaging plane.
    depthUm = zcal.slmUmPerCmd * dz + zcal.slmInterceptUm;
    [resid, predPlane] = min(abs(depthUm - zcal.etlPlaneZUm));
    obsPlane = found(m).planeIdx;
    rec.dzCmdUm        = dz;
    rec.predictedPlane = predPlane;
    rec.observedPlane  = obsPlane;
    rec.residualUm     = abs(depthUm - zcal.etlPlaneZUm(obsPlane));
    rec.agree          = (predPlane == obsPlane) && (rec.residualUm <= tolUm + resid);
    perMark(end+1) = rec; %#ok<AGROW>
end

nAgree = sum([perMark.agree]);
nTotal = numel(perMark);

fprintf('\n=== verifyZCalibration: indirect vs direct ===\n');
fprintf('%10s  %10s  %9s  %11s  %s\n', 'dzCmd um', 'pred plane', ...
    'obs plane', 'resid um', 'agree');
for m = 1:nTotal
    fprintf('%+10.1f  %10d  %9d  %11.2f  %s\n', perMark(m).dzCmdUm, ...
        perMark(m).predictedPlane, perMark(m).observedPlane, ...
        perMark(m).residualUm, boolToStr(perMark(m).agree));
end
fprintf('%d / %d marks agree (tol %.1f um)\n', nAgree, nTotal, tolUm);

if isfield(options, 'mockResponse')
    acknowledged = logical(options.mockResponse);
else
    answer = input('Accept this verification? y/n: ', 's');
    acknowledged = strcmpi(strtrim(answer), 'y');
end

report.perMark      = perMark;
report.nAgree       = nAgree;
report.nTotal       = nTotal;
report.pass         = (nAgree == nTotal);
report.acknowledged = acknowledged;
report.tolUm        = tolUm;
report.timestamp    = datetime('now');

if ~report.pass
    warning('tfp:calibration:verifyZCalibration:disagreement', ...
        ['%d of %d marks disagree between indirect and direct ' ...
         'z-calibration. Do not run 3D experiments on this calibration ' ...
         'until resolved (suspects: m_relay sign/magnitude, ETL plane ' ...
         'order, stack plane interleave).'], nTotal - nAgree, nTotal);
end
end

% --- Local helper ---

function s = boolToStr(tf)
if tf, s = 'yes'; else, s = 'NO'; end
end
