function spec = objectives(name)
%objectives Registry of the four objectives this rig can carry.
%
%   spec = tfp.optics.objectives(name)
%
%   Returns a struct with fields:
%     .fObjUm      objective effective focal length (um)
%     .NA          numerical aperture
%     .nImm        immersion refractive index (1.00 dry, 1.33 water)
%     .tubeLensMm  the tube lens the EFL is quoted against (informational;
%                  EFL is a property of the objective, but the quoted
%                  magnification is only true on this tube lens)
%     .label       human-readable part name
%
%   This registry replaces the stale 180-mm-tube table that used to live in
%   tfp.hardware.PLM.generatePatternLibrary (whose Nikon16x entry, 11.25 mm,
%   assumed a 180 mm tube — wrong for this rig's Nikon 200 mm tube).
%
%   Names (case-insensitive):
%     'nikon10x045' — Nikon CFI Plan Apo Lambda D 10X/0.45, dry.  DEFAULT
%                     for the merged arm (docs/optics_handoff.md §3).
%                     EFL = 200/10 = 20.0 mm.
%     'olympus20x'  — Olympus XLUMPLFLN20XW 20x/1.0 water.
%                     EFL = 180/20 = 9.0 mm (Olympus 180 mm tube standard).
%     'nikon16x'    — Nikon 16x/0.8 water (CFI75 LWD 16X W).
%                     EFL = 200/16 = 12.5 mm.
%     'avocado10x'  — Pacific Optica Avocado 10x/0.6.
%                     EFL = 16.8 mm, BFP Ø20 mm (vendor spec; CLAUDE.md).
%
%   These are design values — the z-calibration fits the effective defocus
%   scale on the rig and uses these only to form the expected slope.

switch lower(char(name))
    case 'nikon10x045'
        spec = struct('fObjUm', 20000, 'NA', 0.45, 'nImm', 1.00, ...
                      'tubeLensMm', 200, ...
                      'label', 'Nikon CFI Plan Apo Lambda D 10X/0.45 (dry)');
    case 'olympus20x'
        spec = struct('fObjUm', 9000, 'NA', 1.00, 'nImm', 1.33, ...
                      'tubeLensMm', 180, ...
                      'label', 'Olympus XLUMPLFLN20XW 20x/1.0 (water)');
    case 'nikon16x'
        spec = struct('fObjUm', 12500, 'NA', 0.80, 'nImm', 1.33, ...
                      'tubeLensMm', 200, ...
                      'label', 'Nikon CFI75 LWD 16X W 16x/0.8 (water)');
    case 'avocado10x'
        spec = struct('fObjUm', 16800, 'NA', 0.60, 'nImm', 1.33, ...
                      'tubeLensMm', 200, ...
                      'label', 'Pacific Optica Avocado 10x/0.6');
    otherwise
        error('tfp:optics:objectives:unknownObjective', ...
            ['Unknown objective "%s". Valid names: nikon10x045, ' ...
             'olympus20x, nikon16x, avocado10x.'], char(name));
end
end
