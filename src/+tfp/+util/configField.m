function value = configField(config, name, default)
%configField Read a struct field with a fallback default.
%
%   value = tfp.util.configField(config, name, default)
%
%   Returns config.(name) when the field exists and is non-empty-struct-safe;
%   otherwise returns default. This is the promoted version of the local
%   helper duplicated across the hardware classes (CLAUDE.md: "promote to
%   +tfp/+util/ if a third caller appears"). New code should call this;
%   existing local copies are removed opportunistically.
%
%   Unlike the Sequencer's dotted-path variant, this reads exactly one
%   level — pass the sub-struct directly for nested reads.

if isstruct(config) && isfield(config, name)
    value = config.(name);
else
    value = default;
end
end
