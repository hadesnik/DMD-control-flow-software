function wfcMap = loadWFC(wfcPath, sys)
%loadWFC Load a per-device wavefront-correction map as a radians field.
%
%   wfcMap = tfp.slm.loadWFC(wfcPath, sys)
%
%   Accepts:
%     ''        — returns [] (flat correction; the safe default until the
%                 Meadowlark device file for this HSP1K is located)
%     *.mat     — must contain a variable `wfc` (double, radians) or
%                 `wfc_states` (uint8 device states, converted assuming the
%                 device's 0..nStates-1 spans sys.wrapPhaseRad)
%     image     — (bmp/png/tif, as Meadowlark ships) 8-bit gray, converted:
%                 radians = double(gray) / 255 * wrapPhaseRad
%
%   sys must carry .nRows, .nCols, .nStates (and optionally .wrapPhaseRad)
%   so the map can be validated against the device geometry.

if isempty(wfcPath)
    wfcMap = [];
    return
end
wfcPath = char(wfcPath);
if exist(wfcPath, 'file') ~= 2
    error('tfp:slm:loadWFC:fileNotFound', 'WFC file not found: %s', wfcPath);
end

nStates = double(sys.nStates);
wrapRad = tfp.util.configField(sys, 'wrapPhaseRad', ...
                               2 * pi * (nStates - 1) / nStates);

[~, ~, ext] = fileparts(wfcPath);
switch lower(ext)
    case '.mat'
        s = load(wfcPath);
        if isfield(s, 'wfc')
            wfcMap = double(s.wfc);
        elseif isfield(s, 'wfc_states')
            wfcMap = double(s.wfc_states) / (nStates - 1) * wrapRad;
        else
            error('tfp:slm:loadWFC:badMat', ...
                '%s must contain `wfc` (radians) or `wfc_states` (uint8).', ...
                wfcPath);
        end
    otherwise
        gray = imread(wfcPath);
        if size(gray, 3) > 1
            gray = gray(:, :, 1);   % Meadowlark files are gray; take one channel
        end
        wfcMap = double(gray) / 255 * wrapRad;
end

if ~isequal(size(wfcMap), [double(sys.nRows), double(sys.nCols)])
    error('tfp:slm:loadWFC:badShape', ...
        'WFC map is [%s]; device is [%d x %d].', ...
        num2str(size(wfcMap)), double(sys.nRows), double(sys.nCols));
end
end
