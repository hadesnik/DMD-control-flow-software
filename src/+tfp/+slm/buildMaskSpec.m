function spec = buildMaskSpec(dzListUm, sys, opts)
%buildMaskSpec Build the flat mask-spec struct sent DAQ PC -> SLM PC.
%
%   spec = tfp.slm.buildMaskSpec(dzListUm, sys, opts)
%
%   The spec-not-pixels contract: the DAQ PC sends this small FLAT struct
%   over msocket (nested structs do not round-trip reliably on the lab
%   msocket build; flat structs are confirmed working — see
%   tfp.io.receiveROIsFromScanImage header). The SLM PC re-derives the
%   masks with tfp.slm.computeDefocusStack from the same fields, so both
%   ends compute byte-identical stacks.
%
%   dzListUm: 1xN defocus commands (um) in SEQUENCE ORDER (= depth-group
%             order; the TTL/software advance contract).
%   sys:      geometry+optics struct (see tfp.slm.computeDefocusMask).
%   opts:     optional struct:
%               .lutPath     — on-device wavelength LUT file path ('' none)
%               .wfcPath     — wavefront-correction file path ('' none)
%               .triggerMode — 'ttl' | 'software' (default 'software')
%
%   Validate with tfp.slm.validateSpec before sending / after receiving.

if nargin < 3 || isempty(opts)
    opts = struct();
end

spec = struct();
spec.version      = 1;
spec.dzListUm     = double(dzListUm(:)');
spec.nRows        = double(sys.nRows);
spec.nCols        = double(sys.nCols);
spec.pitchXUm     = double(sys.pitchXUm);
spec.pitchYUm     = double(sys.pitchYUm);
spec.nStates      = double(sys.nStates);
spec.lambdaNm     = double(sys.lambdaNm);
spec.mRelay       = double(tfp.util.configField(sys, 'mRelay', 2.4));
spec.nImm         = double(tfp.util.configField(sys, 'nImm',   1.33));
spec.fObjUm       = double(tfp.util.configField(sys, 'fObjUm', 16800));
spec.NA           = double(tfp.util.configField(sys, 'NA',     0.6));
spec.wrapPhaseRad = double(tfp.util.configField(sys, 'wrapPhaseRad', ...
                        2 * pi * (spec.nStates - 1) / spec.nStates));
spec.lutPath      = char(tfp.util.configField(opts, 'lutPath', ''));
spec.wfcPath      = char(tfp.util.configField(opts, 'wfcPath', ''));
spec.triggerMode  = char(tfp.util.configField(opts, 'triggerMode', 'software'));

tfp.slm.validateSpec(spec);
end
