function [ totalCost, chargeProfile, totalDamageCost, demForecastUsed,...
    pvForecastUsed, respVecs, featVecs, bestCTG, imp, exp] = ...
    mpcControllerDp(cfg, trainedModel, demGodCast, demand, pvGodCast, ...
    pv, demandDelays, pvDelays, battery, runControl)

% mpcController: Simulate time series behaviour of MPC controller with
% given forecast, using DP to solve horizon

% Select forecasting function handle
switch cfg.fc.modelType
    case 'FFNN'
        forecastHandle = @forecastFfnn;
    case 'RF'
        forecastHandle = @forecastRandomForest;
    case 'MLR'
        forecastHandle = @forecastMlr;
    otherwise
        error('Selected cfg.fc.modelType not implemented');
end


%% Initializations
battery.reset();
nIdxs = size(demGodCast, 1);
if nIdxs ~= size(pvGodCast, 1)
    error('pv and demand godcast not of same length');
end


%% Pre-Allocations
totalCost = 0;
totalDamageCost = 0;
chargeProfile = zeros(1, nIdxs);
bestCTG = zeros(1, nIdxs);
demForecastUsed = zeros(cfg.sim.horizon, nIdxs);
pvForecastUsed = zeros(cfg.sim.horizon, nIdxs);
respVecs = zeros(1, nIdxs);
imp = zeros(1, nIdxs);
exp = zeros(1, nIdxs);

% DEBUGGING:
cumulativeValue = zeros(1, nIdxs);
valueOverNBs = zeros(1, nIdxs);
b_hats = zeros(1,nIdxs);
batteryValues = zeros(1, nIdxs);

% featVec = [nLag prev dem, (demandNow), nLag prev pv, (pvNow), SoC,...
% hourNum]

if cfg.opt.knowDemandNow
    if cfg.fc.createNetDemand
        nFeat = length(cfg.fc.lagsToInclude) + 4;
    else
        nFeat = 2*length(cfg.fc.lagsToInclude) + 4;
    end
else
    if cfg.fc.createNetDemand
        nFeat = length(cfg.fc.lagsToInclude) + 2;
    else
        nFeat = 2*length(cfg.fc.lagsToInclude) + 2;
    end
end

featVecs = zeros(nFeat, nIdxs);

%% Run through time series
clear controllerDp; % Clear function so first horizon is plotted

for idx = 1:nIdxs;
    demandNow = demand(idx);
    pvNow = pv(idx);
    
    if isfield(runControl, 'randomizeInterval')
        if mod(idx, runControl.randomizeInterval) == 0
            battery.randomReset();
        end
    end
    
    % Have enforced elsewhere that training and testing data-set start at
    % t=0, TODO: need to check No. of idxs dropped for godCast doesnt
    % affect this
    hourNow = mod(idx, cfg.sim.stepsPerDay);
    
    [importPrice, exportPrice] = getGridPrices(cfg, hourNow);
    imp(idx) = importPrice;
    exp(idx) = exportPrice;
    
    % Create Feature/Response Vec for FF controller training:
    if cfg.fc.createNetDemand
        if cfg.fc.knowFutureFF
            % featVec = [futureNetDemand, (netDemandNow), SoC, hourNum]
            if cfg.opt.knowDemandNow
                featVecs(:, idx) = [demand(idx:(idx + cfg.sim.horizon - 1)) - ...
                    pv(idx:(idx + cfg.sim.horizon - 1)); demandNow - pvNow; ...
                    battery.SoC; hourNow];
            else
                featVecs(:, idx) = [demand(idx:(idx + cfg.sim.horizon - 1)) - ...
                    pv(idx:(idx + cfg.sim.horizon - 1)); battery.SoC; hourNow];
            end
        else
            % featVec = [nLag prev dem, (demandNow), nLag prev pv, (pvNow), SoC,...
            % hourNum]
            if cfg.opt.knowDemandNow
                featVecs(:, idx) = [demandDelays(end - (cfg.fc.lagsToInclude - 1)) - ...
                    pvDelays(end - (cfg.fc.lagsToInclude - 1)); ...
                    demandNow - pvNow; battery.SoC; hourNow];
            else
                featVecs(:, idx) = [demandDelays(end - (cfg.fc.lagsToInclude - 1)) - ...
                    pvDelays(end - (cfg.fc.lagsToInclude - 1)); ...
                    battery.SoC; hourNow];
            end
        end
    else
        if cfg.fc.knowFutureFF
            % featVec = [futureDemand, (demandNow), futurePv, (pvNow), SoC,...
            % hourNum]
            if cfg.opt.knowDemandNow
                featVecs(:, idx) = [demand(idx:(idx + cfg.sim.horizon - 1));...
                    demandNow; pv(idx:(idx + cfg.sim.horizon - 1)); ...
                    pvNow; battery.SoC; hourNow];
            else
                featVecs(:, idx) = [demand(idx:(idx + cfg.sim.horizon - 1));...
                    pv(idx:(idx + cfg.sim.horizon - 1)); battery.SoC; hourNow];
            end
        else
            % featVec = [nLag prev dem, (demandNow), nLag prev pv, (pvNow), SoC,...
            % hourNum]
            if cfg.opt.knowDemandNow
                featVecs(:, idx) = [demandDelays(end - (cfg.fc.lagsToInclude - 1));...
                    demandNow; pvDelays(end - (cfg.fc.lagsToInclude - 1)); ...
                    pvNow; battery.SoC; hourNow];
            else
                featVecs(:, idx) = [demandDelays(end - (cfg.fc.lagsToInclude - 1));...
                    pvDelays(end - (cfg.fc.lagsToInclude - 1)); battery.SoC; ...
                    hourNow];
            end
        end
    end
    
    %%%% NO BATTERY %%%%
    if isfield(runControl, 'NB') && runControl.NB
        bestDischargeStep = 0;
        
        %%%% FORECAST FREE %%%%
    elseif isfield(runControl, 'forecastFree') && runControl.forecastFree
        [bestDischargeStep, ~, ~] = forecastFreeControl(cfg, ...
            featVecs(:, idx), battery, trainedModel, []);
        
        % Using FF, no need for a forecast
        demForecastUsed(:, idx) = zeros(cfg.sim.horizon, 1);
        pvForecastUsed = zeros(cfg.sim.horizon, 1);
        
        %%%% SP, or NORMAL FORECAST-DRIVEN MODEL %%%%
    else
        
        % Obtain forecast as required
        if runControl.godCast
            demandForecast = demGodCast(idx, :)';
            pvForecast = pvGodCast(idx, :)';
            
        elseif isfield(runControl, 'modelCast') && runControl.modelCast
            demandForecast = demGodCast(idx, :)';
            pvForecast = pvGodCast(idx, :)';
            
        elseif runControl.naivePeriodic
            demandForecast = demandDelays((end-cfg.sim.horizon+1):end);
            pvForecast = pvDelays((end-cfg.sim.horizon+1):end);
            
        elseif runControl.setPoint
            demandForecast = ones(cfg.sim.horizon, 1).*demandNow;
            pvForecast = ones(cfg.sim.horizon, 1).*pvNow;
            
        else
            % Produce forecast from input model (& asosciated method)
            demandForecast = forecastHandle( cfg, trainedModel.demand,...
                demandDelays );
            
            pvForecast = forecastHandle( cfg, trainedModel.pv, pvDelays);
        end
        
        demForecastUsed(:, idx) = demandForecast;
        pvForecastUsed(:, idx) = pvForecast;
        
        if ~runControl.setPoint
            % Do DP control:
            [bestDischargeStep, bestCTG(idx)] = controllerDp_mex(...
                getCfgForController(cfg), demandForecast, pvForecast,...
                battery.getStruct(), hourNow);
        else
            % Do SP control:
            bestDischargeValue = demandNow - pvNow;
            bestDischargeStep = round(bestDischargeValue./...
                battery.increment);
            
            % Limit SP decision to feasible range
            bestDischargeStep = ...
                -battery.limitChargeStep(-bestDischargeStep);
        end
    end
    
    % Implement set point recourse, if selected
    % don't increase exports by discharging
    if cfg.opt.setPointRecourse
        while bestDischargeStep > 0 && (pvNow - demandNow + ...
                bestDischargeStep*battery.increment*...
                cfg.sim.batteryEtaD) > 0
            
            bestDischargeStep = bestDischargeStep - 1;
        end
        
        % Limit SPR decision to feasible range
        bestDischargeStep = ...
            -battery.limitChargeStep(-bestDischargeStep);
    end
    
    % Store best discharge step decision
    respVecs(:, idx) = bestDischargeStep;
    
    if bestDischargeStep < 0
        b_hat = (bestDischargeStep*battery.increment)...
            /cfg.sim.batteryEtaC;
    else
        b_hat = (bestDischargeStep*battery.increment)...
            *cfg.sim.batteryEtaD;
    end
    
    % Apply control decision, subject to rate and state of charge
    % constriants
    chargeProfile(idx) = battery.SoC;
    
    % Energy from grid during interval
    g_t = demandNow - pvNow - b_hat;
    costWithBattery = importPrice*max(0,g_t) - exportPrice*max(0,-g_t);
    
    g_t_noBatt = demandNow - pvNow;
    costWithoutBattery = importPrice*max(0,g_t_noBatt) - ...
        exportPrice*max(0,-g_t_noBatt);
    
    valueOverNB = costWithoutBattery - costWithBattery;
    if idx == 1
        cumulativeValue(idx) = valueOverNB;
    else
        cumulativeValue(idx) = cumulativeValue(idx-1) + valueOverNB;
    end
    
    battery.chargeStep(-bestDischargeStep, valueOverNB);
    
    valueOverNBs(idx) = valueOverNB;
    b_hats(idx) = b_hat;
    batteryValues(idx) = battery.Value();
    
    fracDegradation = calcFracDegradation(cfg, battery, battery.state,...
        bestDischargeStep);
    
    damageCost = battery.Value()*fracDegradation;
    totalDamageCost = totalDamageCost + damageCost;
    
    totalCost = totalCost + costWithBattery + damageCost;
    
    % Shift demand delays (and add current demand)
    demandDelays = [demandDelays(2:end); demandNow];
    pvDelays = [pvDelays(2:end); pvNow];
    
    % DEBUGGING:
    if mod(idx, 1000) == 0
        disp(['Done idx: ' num2str(idx) '/' num2str(nIdxs)]);
    end
end

figure;
plot(cumulativeValue); ylabel('Battery Cumulative Value');
disp('Ending Battery Value: ');
disp(battery.Value());

end
