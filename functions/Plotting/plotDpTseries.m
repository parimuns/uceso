function [ axHandle ] = plotDpTseries(tsFig, plotIdx, demand, pv, SoCs,...
    battery, titleString, nObsTrain, imp, exp)

%plotDpTseries: Plot time-series output of mpcControllerDp function

figure(tsFig);
axHandle = subplot(5,1,plotIdx);
idxPlt = 1:length(SoCs);
plot([demand(idxPlt), pv(idxPlt), SoCs(idxPlt)', imp(idxPlt)',...
    exp(idxPlt)']);
hold on;
hline1 = refline(0, battery.capacity);
hline1.Color = 'k';

legend('Local Demand [kWh/int]', 'PV [kWh/int]', 'SoC [kWh]',...
    'Import Price [$/kWh]', 'Export Price [$/kWh]', 'Batt Cap [kWh]');

title([titleString,', with ' num2str(nObsTrain) ' data points']);

end
