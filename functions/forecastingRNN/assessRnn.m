% file: assessRnn.m
% auth: Khalid Abdulla
% date: 04/04/2016
% brief: Given a neural network test time-series, assess the test MSE

function [ mseTest ] = assessRnn( net, demand, trainControl )

% INPUT:
% net: MATLAB trained recursive neural network object
% demand: input data time-series

% OUPUT:
% mse: Average MSE over test data set
nLags = net.input.size;
horizon = net.output.size;
[featureVectors, responseVectors] = computeFeatureResponseVectors( ...
    demand, nLags, horizon);

x = con2seq(featureVectors);
mses = zeros(length(x), 1);

for idx = 1:length(x)
    [ thisFc, net ] = forecastRnn(net, x(idx), trainControl);
    mses(idx) = mse(responseVectors, cell2mat(thisFc));
end

mseTest = mean(mses);

end