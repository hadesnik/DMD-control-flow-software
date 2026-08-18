classdef test_parse_roi_payload < matlab.unittest.TestCase
    %test_parse_roi_payload Wire-format parsing for the ROI link (socket-free).

    methods (Test)

        function legacyNx2(testCase)
            rois = tfp.io.parseRoiPayload([1 2; 3 4]);
            testCase.verifyEqual(rois.centroids, [1 2; 3 4]);
            testCase.verifyFalse(rois.is3D);
            testCase.verifyTrue(all(isnan(rois.planeIdx)));
            testCase.verifyTrue(all(isnan(rois.zUm)));
        end

        function taggedNx4(testCase)
            payload = [1 2 1 -15; 3 4 3 NaN];
            rois = tfp.io.parseRoiPayload(payload);
            testCase.verifyTrue(rois.is3D);
            testCase.verifyEqual(rois.centroids, [1 2; 3 4]);
            testCase.verifyEqual(rois.planeIdx, [1; 3]);
            testCase.verifyEqual(rois.zUm(1), -15);
            testCase.verifyTrue(isnan(rois.zUm(2)));   % z unknown is legal
        end

        function structCompatibility(testCase)
            rois = tfp.io.parseRoiPayload(struct('centroids', [5 6]));
            testCase.verifyEqual(rois.centroids, [5 6]);
        end

        function rejectsBadShapes(testCase)
            testCase.verifyError(@() tfp.io.parseRoiPayload([1 2 3]), ...
                'tfp:io:parseRoiPayload:badShape');
            testCase.verifyError(@() tfp.io.parseRoiPayload(zeros(0, 2)), ...
                'tfp:io:parseRoiPayload:noROIs');
            testCase.verifyError(@() tfp.io.parseRoiPayload('nope'), ...
                'tfp:io:parseRoiPayload:badPayload');
            % Non-integer plane index is corruption, not data.
            testCase.verifyError(@() tfp.io.parseRoiPayload([1 2 1.5 0]), ...
                'tfp:io:parseRoiPayload:badPlaneIdx');
        end
    end
end
