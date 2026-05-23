function resetAlignTrialsEpisodicWarnings()
%resetAlignTrialsEpisodicWarnings Reset one-shot warning flags. Test-only.
%
%   tfp.io.resetAlignTrialsEpisodicWarnings()
%
%   Resets the persistent one-shot flags inside tfp.io.alignTrialsEpisodic
%   that gate
%
%     tfp:io:alignTrialsEpisodic:lowConfidence
%     tfp:io:alignTrialsEpisodic:overlap
%
%   to "not yet warned this session". Intended for use in test setup
%   (so each test method can independently observe a one-shot warning
%   without resorting to `clear functions`). Has no production caller.
%
%   Implementation is a thin wrapper around the
%   alignTrialsEpisodic('__resetWarnings__') sentinel so the persistent
%   state stays co-located with the helpers that own it.
%
%   See also tfp.io.alignTrialsEpisodic.
    arguments
    end
    tfp.io.alignTrialsEpisodic('__resetWarnings__');
end
