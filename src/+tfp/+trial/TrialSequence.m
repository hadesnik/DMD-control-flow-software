classdef TrialSequence < handle
    %TrialSequence Ordered collection of Trial objects.
    %   Static factory methods generate canonical sequence shapes
    %   (PPSF, rapid sequential, power curve). shuffle randomizes order.

    properties
        trials           % array of Trial objects
        randSeed
        description
    end

    methods (Static)
        function seq = generatePPSF(targets, distancesUm, nReps, powerMw)
            %TODO Build a PPSF sequence: for each target × distance × rep, a trial at that offset and power.
            error('not implemented');
        end

        function seq = generateRapidSequential(targets, isi_s, nReps)
            %TODO Build a rapid-sequential sequence: cycle through targets with inter-stimulus interval isi_s, nReps times.
            error('not implemented');
        end

        function seq = generatePowerCurve(target, powersMw, nReps)
            %TODO Build a power-curve sequence: target stimulated at each power level, nReps times each.
            error('not implemented');
        end
    end

    methods
        function obj = shuffle(obj, seed)
            %TODO Randomize trials in place using seed; store seed in randSeed.
            error('not implemented');
        end
    end
end
