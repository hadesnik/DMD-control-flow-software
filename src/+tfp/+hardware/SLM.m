classdef SLM < handle
    %SLM Abstract interface for liquid-crystal spatial light modulators.
    %   Subclasses include MockSLM (in-memory simulator) and
    %   Meadowlark1024_SLM (real Meadowlark 1024×1024 via Blink SDK).
    %   Experiment code talks only to this interface, never to a concrete
    %   class.  The device acts as a display element only — holography and
    %   CGH computation live in +patterns/+threeDShot/.
    %
    %   State machine: idle → loaded → presenting.
    %   initialize   : idle
    %   loadPhaseMask: idle|presenting → loaded
    %   present      : loaded → presenting
    %   blank        : any → presenting (zero mask)
    %   cleanup      : any → idle
    %
    %   displayPhase is a concrete convenience wrapper: loadPhaseMask + present.

    properties (Abstract, SetAccess = protected)
        nRows           % pixel rows (y dimension)
        nCols           % pixel columns (x dimension)
        pitch_um        % square pixel pitch, µm (e.g. 17 for Meadowlark 1024)
        isInitialized   % logical scalar
    end

    methods (Abstract)
        %initialize Configure and connect to the SLM hardware.
        %   config: struct with device-specific fields.
        initialize(obj, config)

        %loadPhaseMask Upload a uint8 phase mask to the SLM frame buffer.
        %   mask: uint8([nRows nCols]), values 0..255 (0 = 0 rad, 255 ≈ 2π).
        %   Transitions state to 'loaded'.
        loadPhaseMask(obj, mask)

        %present Commit the loaded mask to the SLM display.
        %   Transitions state to 'presenting'.
        present(obj)

        %blank Display a flat (all-zero) mask immediately.
        %   Transitions state to 'presenting'.
        blank(obj)

        %slmPower Enable or disable the SLM LC drive voltage.
        %   onTF: logical scalar. Powering off protects the LC crystal.
        slmPower(obj, onTF)

        %getStatus Return a scalar struct with at minimum:
        %   .state      char  — 'idle' | 'loaded' | 'presenting'
        %   .isMaskLoaded logical
        %   .powerOn    logical
        status = getStatus(obj)

        %cleanup Release hardware resources; must never throw.
        cleanup(obj)
    end

    methods
        function displayPhase(obj, mask)
            %displayPhase Load a phase mask and immediately present it.
            %   Convenience wrapper: loadPhaseMask(mask) then present().
            obj.loadPhaseMask(mask);
            obj.present();
        end
    end
end
