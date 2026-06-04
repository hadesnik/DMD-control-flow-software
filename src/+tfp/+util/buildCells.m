function cells = buildCells(fakeCellsCfg)
%buildCells Build a CellResponseModel cell array from a fakeCells config struct array.
%
%   cells = tfp.util.buildCells(fakeCellsCfg)
%
%   Returns a 1xN cell array; callers index with cells{k}.  Typed-array
%   pre-allocation (backward loop) requires a no-arg constructor, which
%   CellResponseModel intentionally omits — hence a cell array here.  Shared by
%   the all-optical mock experiment scripts.

nCells = numel(fakeCellsCfg);
cells  = cell(1, nCells);
for k = 1:nCells
    fc   = fakeCellsCfg(k);
    args = {};
    if isfield(fc, 'amplitude'),   args = [args, {'amplitude',   double(fc.amplitude)}]; end %#ok<AGROW>
    if isfield(fc, 'sigma'),       args = [args, {'sigma',       double(fc.sigma)}]; end %#ok<AGROW>
    if isfield(fc, 'aiChannel'),   args = [args, {'aiChannel',   double(fc.aiChannel)}]; end %#ok<AGROW>
    if isfield(fc, 'tag'),         args = [args, {'responseTag', char(fc.tag)}]; end %#ok<AGROW>
    cells{k} = tfp.sim.CellResponseModel( ...
        [double(fc.dmdCol), double(fc.dmdRow)], double(fc.radiusDmd), args{:});
end
end
