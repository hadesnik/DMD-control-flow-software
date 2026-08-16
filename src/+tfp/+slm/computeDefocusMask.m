function [mask, info] = computeDefocusMask(dzUm, sys)
%computeDefocusMask Paraxial defocus phase mask for a pupil phase modulator.
%
%   [mask, info] = tfp.slm.computeDefocusMask(dzUm, sys)
%
%   Device-agnostic core shared by the Meadowlark SLM (1024x1024, 17 um,
%   256 states, LC) and the TI PLM (904x800, 16.2/10.8 um, 32 states,
%   piston mirrors). tfp.hardware.PLM.computeDefocusPattern delegates here,
%   so the physics lives in exactly one place; the SLM-PC server and the
%   DAQ-PC proxy both call this to guarantee identical masks on both ends
%   of the spec-not-pixels handoff.
%
%   dzUm: axial displacement in um (positive = focus deeper into sample).
%   sys:  struct; required device-geometry fields:
%           .nRows, .nCols        array size (pixels)
%           .pitchXUm, .pitchYUm  pixel pitch (um); pass equal for square
%           .nStates              phase quantization levels (32 PLM, 256 SLM)
%           .lambdaNm             wavelength (nm), e.g. 1038 measured [CERT]
%         optics fields (defaults follow tfp.hardware.PLM for parity):
%           .mRelay    = 2.4      pupil relay magnification, modulator -> BFP
%           .nImm      = 1.33     immersion refractive index
%           .fObjUm    = 16800    objective focal length (um)
%           .NA        = 0.6     objective numerical aperture
%         wrap convention:
%           .wrapPhaseRad = 2*pi*(nStates-1)/nStates
%             The (N-1)/N wrap is the TI PLM's double-pass piston full scale
%             (see tfp.hardware.PLM). A calibrated LC device whose on-device
%             LUT maps 0..nStates-1 onto a full 2*pi should pass 2*pi here.
%         optional correction:
%           .wfcMap = []          per-device wavefront correction, RADIANS,
%                                 double(nRows, nCols); added pre-wrap via
%                                 tfp.slm.applyWFC ([] = flat)
%
%   Returns:
%     mask  uint8(nRows, nCols), values 0..nStates-1
%     info  struct: .rPupilUm (pupil radius at modulator, um),
%                   .nPxRadius (pupil radius in worst-axis pixels),
%                   .wrappedWaves (peak defocus phase / 2*pi across pupil)
%
%   Phase formula (paraxial):
%     phi(r) = pi * nImm * dzUm * mRelay^2 * r^2 / (lambdaUm * fObjUm^2)
%   Pupil: pixels outside rPupil = fObjUm*NA/(nImm*mRelay) are state 0.

if nargin < 2 || ~isstruct(sys)
    error('tfp:slm:computeDefocusMask:badSys', 'sys must be a struct.');
end
if ~isnumeric(dzUm) || ~isscalar(dzUm) || ~isfinite(dzUm)
    error('tfp:slm:computeDefocusMask:badDz', ...
        'dzUm must be a finite numeric scalar.');
end

nRows    = requireField(sys, 'nRows');
nCols    = requireField(sys, 'nCols');
pitchXUm = requireField(sys, 'pitchXUm');
pitchYUm = requireField(sys, 'pitchYUm');
nStates  = requireField(sys, 'nStates');
lambdaNm = requireField(sys, 'lambdaNm');

mRelay   = tfp.util.configField(sys, 'mRelay', 2.4);
nImm     = tfp.util.configField(sys, 'nImm',   1.33);
fObjUm   = tfp.util.configField(sys, 'fObjUm', 16800);
NA       = tfp.util.configField(sys, 'NA',     0.6);
wrapRad  = tfp.util.configField(sys, 'wrapPhaseRad', ...
                                2 * pi * (nStates - 1) / nStates);

lambdaUm = lambdaNm / 1000;

% Pupil radius at the modulator plane (um); paraxial BFP radius / relay mag
rBfpUm   = fObjUm * NA / nImm;
rPupilUm = rBfpUm / mRelay;

% Physical pixel coordinates centred on the array (um)
cx = (nCols + 1) / 2;
cy = (nRows + 1) / 2;
[jj, ii] = meshgrid(1:nCols, 1:nRows);
xUm = (jj - cx) * pitchXUm;
yUm = (ii - cy) * pitchYUm;
r2  = xUm.^2 + yUm.^2;          % squared radial distance, um^2

% Paraxial defocus phase (radians)
phi = (pi * nImm * dzUm * mRelay^2) / (lambdaUm * fObjUm^2) * r2;

% Optional per-device wavefront correction, applied pre-wrap
phi = tfp.slm.applyWFC(phi, tfp.util.configField(sys, 'wfcMap', []));

phiWrap = mod(phi, wrapRad);

% Pixels outside the pupil are set to flat (state 0)
phiWrap(r2 > rPupilUm^2) = 0;

state = uint8(floor(phiWrap * nStates / wrapRad));
mask  = min(state, uint8(nStates - 1));   % clamp numerical edge

if nargout > 1
    info.rPupilUm     = rPupilUm;
    info.nPxRadius    = round(rPupilUm / max(pitchXUm, pitchYUm));
    % Peak (unwrapped) defocus phase at the pupil edge, in waves
    phiEdge = abs((pi * nImm * dzUm * mRelay^2) / (lambdaUm * fObjUm^2) ...
                  * rPupilUm^2);
    info.wrappedWaves = phiEdge / (2 * pi);
end
end

% --- Local helper ---

function v = requireField(s, name)
if ~isfield(s, name) || isempty(s.(name))
    error('tfp:slm:computeDefocusMask:missingField', ...
        'sys.%s is required.', name);
end
v = double(s.(name));
end
