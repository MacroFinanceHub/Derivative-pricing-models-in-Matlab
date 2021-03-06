% Zero spread curve stores {curve_tenors, zero_spreads}
function [curve, error_tenor_indices] = constructBasisSwapZeroSpreadCurveXCCY(swap_tenor, non_benchmark_forecast_curve, market_spreads, value_date, spot_lag, dcc, bdc, calendars)

    % construct/convert inputs
    nonref_freq_term = swap_tenor{1,1};
    nonref_freq_base = swap_tenor{1,2};
    maturities_term = cell2mat(market_spreads(:,1));
    maturities_base = cell2mat(market_spreads(:,2));
    spreads = cell2mat(market_spreads(:,3));
    nc = size(market_spreads,1);    
    spot_date = calcSpotDates(value_date, spot_lag, calendars); % calc spot date based on spot lag and holidays from merged calendars
    start_dates = spot_date .* ones(nc,1); % col vector of start date
    
    % initialise outputs
    curve(:,1) = num2cell(calcEndDates(start_dates, maturities_term, maturities_base, dcc, bdc, calendars)); % calc curve tenors 
    error_tenor_indices = zeros(1,nc); % 1-by-nc row vector  
    
    % bootstrap each tenor for zero spread curve from each market quoted
    % fair spread
    j = 0;
    past_exponents = [];
    first_root = 0; % dummy init
    for i=1:nc
        % gencashflows
        nonref_cfs_dates = genCashflowDates(spot_date, curve{i,1}, nonref_freq_term, nonref_freq_base, dcc, bdc, calendars); % cashflows on the non-ref side
        n = length(nonref_cfs_dates);
        if (i==1)
            first_j = n; % remember the first j index for initial adjusted df calculation
        end      
        nonref_reset_dates = nonref_cfs_dates; % set reset dates to accrual dates for now, need to implement full floating side cashflows later!!!!!
        nonref_dfs = getDFsFromCurve(non_benchmark_forecast_curve, value_date, nonref_cfs_dates,'loglinearDf');
        nonref_df_spot = getDFsFromCurve(non_benchmark_forecast_curve, value_date, spot_date,'loglinearDf'); % df from adjusted curve from spot to value date
        nonref_cfs_dates_down = shift(nonref_cfs_dates, 'down', spot_date); % shift down
        nonref_taus = findDaysFraction(nonref_cfs_dates_down, nonref_cfs_dates, dcc);
        clear fwd_dates;
        fwd_dates(1) = spot_date;
        fwd_dates(2:length(nonref_reset_dates)+1) = nonref_reset_dates;
        nonref_fwd_rates = getFwdRatesFromCurve(non_benchmark_forecast_curve, value_date, fwd_dates, dcc);   
        taus = findDaysFraction(value_date, nonref_cfs_dates, dcc);
        
        % root solver
        [lb ub] = calcBounds(nonref_dfs, past_exponents, nonref_taus, taus, nonref_fwd_rates, j, spreads(i)); % fzero converges faster if bound is given
        f = @(x)function_f(x, nonref_dfs, nonref_df_spot, past_exponents, nonref_taus, taus, nonref_fwd_rates, nonref_cfs_dates, first_j, j, first_root, spreads(i), value_date, spot_date);
        
        % for testing only - low and up should have opposite signs
        %low = function_f(lb, nonref_dfs, nonref_df_spot, past_exponents, nonref_taus, taus, nonref_fwd_rates, nonref_cfs_dates, first_j, j, first_root, spreads(i), value_date, spot_date);
        %up = function_f(ub, nonref_dfs, nonref_df_spot, past_exponents, nonref_taus, taus, nonref_fwd_rates, nonref_cfs_dates, first_j, j, first_root, spreads(i), value_date, spot_date);
        
        [root, ~, exitflag] = fzero(f,(lb+ub)/2); % Brent's method - with initial guess instead of bounds        
        %[root, fval, exitflag] = fzero(f,1000); % Brent's method - with initial guess instead of bounds        
        
        % for testing only - should be zero
        %function_f(root, nonref_dfs, nonref_df_spot, past_exponents, nonref_taus, taus, nonref_fwd_rates, nonref_cfs_dates, first_j, j, first_root, spreads(i), value_date, spot_date);
        
        if (exitflag == 1) % a root is found
            if (i==1)
                first_root = root;
            end            
            curve{i,2} = root;
            new_exponent = -root * taus(end);
            new_exponents = calcExponents(past_exponents, new_exponent, nonref_cfs_dates, j, value_date);
            clear past_exponents;
            past_exponents = new_exponents;
        else
            error_tenor_indices(i:end) = 1; % this spread tenor in error because no root is found, and hence all subsequent ones cannot be solved either
            curve(i:end,2) = (lb + ub) / 2; % set the zero spread to the initial guess of the root solver, could be set to something else if desired
            return; % stop
        end
        
        j = n;
    end
    
end


% Find upper and lower bounds for the root solver
function [lb ub] = calcBounds(dfs, past_exponents, taus_period, taus_actual, fwd_rates, last_cf_index, spread)
    j = last_cf_index;
    n = length(taus_period);
    is_a = j+1:n-1;
    is_b = j+1:n;
    
    % calc zero_spread_a
    numerator = dfs(end) * (taus_period(end) * (fwd_rates(end) + spread) + 1);
    if (~isempty(past_exponents)) % i.e. j > 0
        past_adjusted_dfs = dfs(1:j) .* exp(past_exponents); % past_exponents is of length j
        sum_c = (taus_period(1:j) .* (fwd_rates(1:j) + spread) * past_adjusted_dfs');
        sum_a = (taus_period(is_a) .* (fwd_rates(is_a) + spread) * exp(past_exponents(end)) * dfs(is_a)');
        denominator = 1 - sum_a - sum_c;
    else
        denominator = 1 - (taus_period(is_a) .* (fwd_rates(is_a) + spread) * dfs(is_a)');
    end    
    zero_spread_a = log(numerator / denominator) / taus_actual(end);
    
    % calc zero_spread_b
    clear numerator denominator;
    numerator = taus_period(is_b) .* (fwd_rates(is_b) + spread) * dfs(is_b)' + dfs(end);
    denominator = 1;
    if (~isempty(past_exponents)) % i.e. j > 0
        denominator = denominator - taus_period(1:j) .* (fwd_rates(1:j) + spread) * past_adjusted_dfs';
    end
    zero_spread_b = log(numerator / denominator) / taus_actual(end);
    
    lb = min(zero_spread_a, zero_spread_b);
    ub = max(zero_spread_a, zero_spread_b);
    
end


% Implements equation 1.11 in model spec and equation 3 in client's spec -
% Calc function value of the function required to solve for the zero
% spread. Inputs are (all wrt nonref ccy side) : x (input zero spread rate at this zero spread tenor
% date T_n, dfs (discount factors on the discount
% curve), past_exponents (calculated past exponents - have size j only), taus_accrual (day count fractions of the accrual periods ), fwd_rates
% (the forecast rates on each rateset date), cf_dates (the set of all accrual start dates), taus_whole (the day count fractions from 
% value date to each accrual dates), and
% market quoted spread. Output of this function is fx (f(x)).
function [fx] = function_f(x, dfs, df_spot, past_exponents, taus_period, taus_actual, fwd_rates, cf_dates, first_last_cf_index, last_cf_index, first_root, spread, value_date, spot_date)
    j = last_cf_index;
    input_exponent = -x * taus_actual(end);
    if (j == 0)
        first_root = x;
    end
    init_exponent1 = -first_root * taus_actual(first_last_cf_index);
    init_exponent = (spot_date - value_date) / (cf_dates(first_last_cf_index) - value_date) * init_exponent1;
    init_adjusted_df = df_spot * exp(init_exponent);
    
    fx = -init_adjusted_df; % init to first term of the function

    if (j > 0)
        past_adjusted_dfs = dfs(1:j) .* exp(past_exponents); % past_exponents is of length j
        term2 = taus_period(1:j) .* (fwd_rates(1:j) + spread) * past_adjusted_dfs';
        fx = fx + term2;
    end    
    
    n = length(cf_dates);
    is = j+1:n;

    if (~isempty(past_exponents)) % i.e. j > 0
        exponents = (cf_dates(end) - cf_dates(is)) ./ (cf_dates(end) - cf_dates(j)) * past_exponents(end) + (cf_dates(is) - cf_dates(j)) ./ (cf_dates(end) - cf_dates(j)) * input_exponent;
    else % j = 0
        exponents = (cf_dates(is) - value_date) ./ (cf_dates(end) - value_date) * input_exponent; % the first term is zero since we assume zero spread at T_0 = 0
    end
    
    new_adjusted_dfs = dfs(is) .* exp(exponents);
    term3 = taus_period(j+1:end) .* (fwd_rates(j+1:end) + spread) *  new_adjusted_dfs';
    fx = fx + term3;
           
    term4 = new_adjusted_dfs(end);
    fx = fx + term4;
end

% Calculate all the -ve expoenents between the last known and the newly
% calculated one
function [new_exponents] = calcExponents(past_exponents, new_exponent, cf_dates, last_cf_index, value_date)
    j = last_cf_index;
    n = length(cf_dates);
    new_exponents = past_exponents; % return all old known values as well
    is = j+1:n;
    if (j > 0)
        new_exponents(end+1:n) = (cf_dates(end) - cf_dates(is)) ./ (cf_dates(end) - cf_dates(j)) * past_exponents(end) + ...
            (cf_dates(is) - cf_dates(j)) ./ (cf_dates(end) - cf_dates(j)) * new_exponent;
    else
        new_exponents(end+1:n) = (cf_dates(is) - value_date) ./ (cf_dates(end) - value_date) * new_exponent;
    end
end