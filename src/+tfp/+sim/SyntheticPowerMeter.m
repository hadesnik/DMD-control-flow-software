classdef SyntheticPowerMeter < handle
    %SyntheticPowerMeter A stand-in for a Thorlabs PM100D, driven by the DAQ log.
    %
    %   Exposes the one method the sweeps actually use — measPower() returning
    %   watts — so tfp.calibration.powerMeterSweepSingle and
    %   tfp.calibration.powerMeterSweep can be exercised end to end with no
    %   hardware, through options.meter.
    %
    %   THE POINT. Before the meter became injectable, powerMeterSweep_mock had
    %   to re-implement the sweep's arithmetic, so the tested code was never the
    %   code that runs at the bench. This meter instead WATCHES a MockDAQ's log
    %   for the most recent outputSingleAnalog on the modulator channel and
    %   reports the power that voltage would produce. The real sweep therefore
    %   drives the real controller, which drives the real interlock, which
    %   drives the mock DAQ, which drives this meter — one loop, no shortcuts.
    %
    %   Construction:
    %     m = tfp.sim.SyntheticPowerMeter(daq, aoChannel, options)
    %
    %   options:
    %     .responseFcn  @(volts) -> mW at the sample. Default is a saturating
    %                   curve, maxMw / (1 + exp(-k*(v - v0))) rebased so v=0
    %                   gives 0 mW: monotone but distinctly non-linear, which is
    %                   what a real modulator looks like and what an
    %                   interpolating inverse must cope with.
    %     .maxMw        default 50
    %     .k, .v0       sigmoid shape (defaults 2 and 2.5)
    %     .noiseMw      Gaussian read noise std (default 0.005)
    %     .seed         rng seed for reproducible noise (default 42)
    %
    %   See also tfp.calibration.powerMeterSweepSingle, tfp.hardware.MockDAQ.

    properties (SetAccess = protected)
        aoChannel
        responseFcn
        noiseMw
        nReads = 0
    end

    properties (Access = private)
        daq_
        rng_
    end

    methods
        function obj = SyntheticPowerMeter(daq, aoChannel, options)
            if nargin < 3 || isempty(options), options = struct(); end
            obj.daq_      = daq;
            obj.aoChannel = char(aoChannel);
            obj.noiseMw   = tfp.util.configField(options, 'noiseMw', 0.005);

            fcn = tfp.util.configField(options, 'responseFcn', []);
            if isempty(fcn)
                maxMw = tfp.util.configField(options, 'maxMw', 50);
                k     = tfp.util.configField(options, 'k',     2);
                v0    = tfp.util.configField(options, 'v0',    2.5);
                sig   = @(v) maxMw ./ (1 + exp(-k * (v - v0)));
                zero  = sig(0);
                fcn   = @(v) max(0, (sig(v) - zero) / (1 - zero / maxMw));
            end
            obj.responseFcn = fcn;
            obj.rng_ = RandStream('twister', 'Seed', ...
                tfp.util.configField(options, 'seed', 42));
        end

        function w = measPower(obj)
            %measPower Power in WATTS, matching the TLPM wrapper's unit.
            v = obj.commandedVolts();
            mw = obj.responseFcn(v) + obj.noiseMw * randn(obj.rng_);
            mw = max(0, mw);
            obj.nReads = obj.nReads + 1;
            w = mw * 1e-3;
        end

        function close(~)
            % No-op; present so ownership handling is uniform with TLPM.
        end

        function v = commandedVolts(obj)
            %commandedVolts Last voltage written to the modulator channel.
            v = 0;
            entries = obj.daq_.getLog();
            for k = numel(entries):-1:1
                e = entries(k);
                if strcmp(e.eventType, 'outputSingleAnalog') && ...
                        strcmp(e.payload.channel, obj.aoChannel)
                    v = e.payload.voltageV;
                    return
                end
            end
        end
    end
end
