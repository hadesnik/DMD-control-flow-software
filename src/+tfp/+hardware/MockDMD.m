classdef MockDMD < tfp.hardware.DMD
    %MockDMD Simulated DMD device for pre-hardware development.
    %   Logs every call with a timestamp and (optionally) renders the
    %   active pattern to a debug figure. See ARCHITECTURE.md "MockDMD"
    %   for simulated behaviors (pattern load latency, trigger-to-mirror
    %   settle delay, optional failure modes).

    properties (SetAccess = protected)
        nRows
        nCols
        maxPatternRate
        isInitialized
    end

    methods
        function initialize(obj, config)
            %TODO Initialize the simulator from config (mirror dimensions, debug-figure on/off, failure-injection options).
            error('not implemented');
        end

        function loadPatternSequence(obj, patterns, options)
            %TODO Store patterns in memory and render the first to a tfp.util.DebugFigure singleton; simulate load latency.
            error('not implemented');
        end

        function armSequence(obj)
            %TODO Mark the loaded sequence as armed; subsequent softTrigger advances through it.
            error('not implemented');
        end

        function softTrigger(obj)
            %TODO Advance through the sequence at the configured rate, updating the debug figure.
            error('not implemented');
        end

        function advanceToPattern(obj, idx)
            %TODO Jump to pattern index idx and update the debug figure.
            error('not implemented');
        end

        function status = getStatus(obj)
            %TODO Return a struct describing armed/running/idle state, current pattern index, etc.
            error('not implemented');
        end

        function cleanup(obj)
            %TODO Close the debug figure and clear stored state.
            error('not implemented');
        end
    end
end
