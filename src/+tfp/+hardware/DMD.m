classdef DMD < handle
    %DMD Abstract interface for DMD pattern projectors.
    %   Subclasses include MockDMD (simulator) and DLP650LNIR_DMD (real
    %   hardware via ViALUX ALP-4.3). Experiment code talks to this
    %   interface, never to a concrete class.

    properties (Abstract, SetAccess = protected)
        nRows           % e.g., 800 for DLP650LNIR
        nCols           % e.g., 1280
        maxPatternRate  % Hz, binary patterns
        isInitialized
    end

    methods (Abstract)
        initialize(obj, config)

        % patterns: logical(nRows, nCols, nPatterns)
        % options: struct with .exposureUs, .darkTimeUs, .triggerMode
        loadPatternSequence(obj, patterns, options)

        armSequence(obj)
        softTrigger(obj)
        advanceToPattern(obj, idx)
        status = getStatus(obj)
        cleanup(obj)
    end

    methods
        function pxCount = activePixelCount(obj, patternIdx)
            % Useful for power-per-target calculations
            error('not implemented');
        end
    end
end
