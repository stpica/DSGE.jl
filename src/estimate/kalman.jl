"""
```
Kalman{S<:AbstractFloat}
```
### Fields:

- `loglh`: vector of conditional log-likelihoods log p(y_t | y_{1:t-1}), t = 1:T
- `s_T`: state vector in the last period for which data is provided
- `P_T`: variance-covariance matrix for `s_T`
- `s_pred`: `Ns` x `Nt` matrix of s_{t|t-1}, t = 1:T
- `P_pred`: `Ns` x `Ns` x `Nt` array of P_{t|t-1}, t = 1:T
- `s_filt`: `Ns` x `Nt` matrix of s_{t|t}, t = 1:T
- `P_filt`: `Ns` x `Ns` x `Nt` array of P_{t|t}, t = 1:T
- `s_0`: starting-period state vector. If there are presample periods in the
  data, then `s_0` is the state vector at the end of the presample/beginning of
  the main sample
- `P_0`: variance-covariance matrix for `s_0`
- `total_loglh`: log p(y_{1:t})
"""
struct Kalman{S<:AbstractFloat}
    loglh::Vector{S}            # log p(y_t | y_{1:t-1}), t = 1:T
    s_pred::AbstractArray{S}    # s_{t|t-1}, t = 1:T
    P_pred::Array{S, 3}         # P_{t|t-1}, t = 1:T
    s_filt::AbstractArray{S}    # s_{t|t}, t = 1:T
    P_filt::Array{S, 3}         # P_{t|t}, t = 1:T
    s_0::Vector{S}              # s_0
    P_0::AbstractArray{S}       # P_0
    s_T::Vector{S}              # s_{T|T}
    P_T::AbstractArray{S}       # P_{T|T}
    total_loglh::S              # log p(y_{1:t})
end

function Kalman(loglh::Vector{S},
                s_pred::AbstractArray{S}, P_pred::Array{S, 3},
                s_filt::AbstractArray{S}, P_filt::Array{S, 3},
                s_0::Vector{S}, P_0::AbstractArray{S},
                s_T::Vector{S}, P_T::AbstractArray{S}) where S<:AbstractFloat

    return Kalman{S}(loglh, s_pred, P_pred, s_filt, P_filt, s_0, P_0, s_T, P_T, sum(loglh))
end

function Base.getindex(K::Kalman, d::Symbol)
    if d in (:loglh, :s_pred, :P_pred, :s_filt, :P_filt, :s_0, :P_0, :s_T, :P_T, :total_loglh)
        return getfield(K, d)
    else
        throw(KeyError(d))
    end
end

function Base.getindex(kal::Kalman, inds::Union{Int, UnitRange{Int}})
    t0 = first(inds)
    t1 = last(inds)

    return DSGE.Kalman(kal[:loglh][inds],        # loglh
                       kal[:s_pred][:,    inds], # s_pred
                       kal[:P_pred][:, :, inds], # P_pred
                       kal[:s_filt][:,    inds], # filt
                       kal[:P_filt][:, :, inds], # P_filt
                       kal[:s_filt][:,    t0],   # s_0
                       kal[:P_filt][:, :, t0],   # P_0
                       kal[:s_filt][:,    t1],   # s_T
                       kal[:P_filt][:, :, t1],   # P_T
                       sum(kal[:loglh][inds]))   # total_loglh
end

function Base.cat(m::AbstractDSGEModel, k1::Kalman{S},
                  k2::Kalman{S}; allout::Bool = true) where S<:AbstractFloat

    loglh  = cat(k1[:loglh], k2[:loglh], dims = 1)
    s_pred = cat(k1[:s_pred], k2[:s_pred], dims = 2)
    P_pred = cat(k1[:P_pred], k2[:P_pred], dims = 3)
    s_filt = cat(k1[:s_filt], k2[:s_filt], dims = 2)
    P_filt = cat(k1[:P_filt], k2[:P_filt], dims = 3)
    s_0    = k1[:s_0]
    P_0    = k1[:P_0]
    s_T    = k2[:s_T]
    P_T    = k2[:P_T]
    total_loglh = k1[:total_loglh] + k2[:total_loglh]

    return Kalman(loglh, s_pred, P_pred, s_filt, P_filt, s_0, P_0, s_T, P_T, total_loglh)
end

"""
```
zlb_regime_indices(m, data, start_date = date_presample_start(m))
```

Returns a Vector{UnitRange{Int64}} of index ranges for the pre- and post-ZLB
regimes. The optional argument `start_date` indicates the first quarter of
`data`.
"""
function zlb_regime_indices(m::AbstractDSGEModel{S}, data::AbstractArray,
                            start_date::Dates.Date=date_presample_start(m)) where S<:AbstractFloat
    T = size(data, 2)
    if n_mon_anticipated_shocks(m) > 0 && !isempty(data)
        if start_date < date_presample_start(m)
            error("Start date $start_date must be >= date_presample_start(m)")

        elseif 0 < subtract_quarters(date_zlb_start(m), start_date) < T
            n_nozlb_periods = subtract_quarters(date_zlb_start(m), start_date)
            regime_inds::Vector{UnitRange{Int64}} = [1:n_nozlb_periods, (n_nozlb_periods+1):T]
        else
            regime_inds = UnitRange{Int64}[1:T]
        end
    else
        regime_inds = UnitRange{Int64}[1:T]
    end
    return regime_inds
end

"""
```
function zlb_plus_regime_indices(m::AbstractDSGEModel{S}, data::AbstractArray,
                                 start_date::Dates.Date=date_presample_start(m)) where S<:AbstractFloat
```
returns a Vector{UnitRange{Int64}} of index ranges for regime switches with the pre- and post-ZLB
regimes spliced into the regime switches. The optional argument `start_date` indicates the first quarter of
`data`. Use the `Setting` with key `:regime_dates` to set the start dates of different regimes (excluding
the ZLB regime), and use the `Setting` key `:date_zlb_start` to set the start of the post-ZLB regime.
"""
function zlb_plus_regime_indices(m::AbstractDSGEModel{S}, data::AbstractArray,
                                 start_date::Dates.Date=date_presample_start(m)) where S<:AbstractFloat

    T = size(data, 2)
    if !isempty(data)
        if start_date < date_presample_start(m)
            error("Start date $start_date must be >= date_presample_start(m)")
        elseif 0 < subtract_quarters(date_zlb_start(m), start_date) < T
            n_nozlb_periods  = subtract_quarters(date_zlb_start(m), start_date)
            n_regime_periods = Vector{Int}(undef, length(get_setting(m, :regime_dates))) # number of periods since start date for each regime
            for (k, v) in get_setting(m, :regime_dates)
                n_regime_periods[k] = subtract_quarters(v, start_date)
            end
            # Get index of next regime after ZLB starts.
            # Note that it cannot be 1 b/c the first regime starts at the start date
            i_splice_zlb = findfirst(n_nozlb_periods .< n_regime_periods)

            # Populate vector of regime indices
            regime_inds = Vector{UnitRange{Int64}}(undef, length(n_regime_periods) + 1)
            if isnothing(i_splice_zlb) # post-ZLB is the last regime
                for reg in 1:(length(n_regime_periods) - 1)
                    regime_inds[reg] = (n_regime_periods[reg] + 1):n_regime_periods[reg + 1]
                end
                regime_inds[end] = (n_regime_periods[end] + 1):T
            elseif i_splice_zlb > 2 # at least one full regime before ZLB starts
                regime_inds[1] = 1:n_regime_periods[2]
                for reg in 2:i_splice_zlb - 2 # if i_splice_zlb == 3, then this loop does not run
                    regime_inds[reg] = (n_regime_periods[reg] + 1):n_regime_periods[reg + 1]
                end
                regime_inds[i_splice_zlb - 1] = (n_regime_periods[i_splice_zlb - 2] + 1):n_nozlb_periods
                regime_inds[i_splice_zlb]     = (n_nozlb_periods + 1):(n_regime_periods[i_splice_zlb - 1])

                # Index reg + 1 b/c we have spliced pre- and post- ZLB regime in
                for reg in i_splice_zlb:(length(n_regime_periods) - 1)
                    regime_inds[reg + 1] = (n_regime_periods[reg] + 1):n_regime_periods[reg + 1]
                end
                regime_inds[end] = (n_regime_periods[end] + 1):T
            else # first regime is pre-ZLB regime
                regime_inds[1] = 1:n_nozlb_periods
                regime_inds[2] = (n_nozlb_periods + 1):n_regime_periods[1]

                # Index reg + 1 b/c spliced pre- and post-ZLB regime in
                for reg in 2:length(n_regime_periods)
                    regime_inds[reg + 1] = (n_regime_periods[reg - 1] + 1):n_regime_periods[reg]
                end
            end
        else # DOES NOT COVER REGIME SWITCHING YET
            # This is the case that date_zlb_start <= start_date so the first regime is the post-ZLB regime (no pre-ZLB)
            regime_inds = UnitRange{Int64}[1:T]
        end
    else # Empty, so we ignore regime switching
        regime_inds = UnitRange{Int64}[1:T]
    end
    return regime_inds
end

"""
```
zlb_regime_matrices(m, system, start_date = date_presample_start(m))
```
Returns `TTTs, RRRs, CCCs, QQs, ZZs, DDs, EEs`, an 8-tuple of
`Vector{AbstractArray{S}}`s and `Vector{Vector{S}}`s of system matrices for the pre-
and post-ZLB regimes. Of these, only `QQ` changes from pre- to post-ZLB: the
entries corresponding to anticipated shock variances are zeroed out pre-ZLB.
"""
function zlb_regime_matrices(m::AbstractDSGEModel{S}, system::System{S},
                             start_date::Dates.Date=date_presample_start(m)) where S<:AbstractFloat
    if n_mon_anticipated_shocks(m) > 0
        if start_date < date_presample_start(m)
            error("Start date $start_date must be >= date_presample_start(m)")

        # TODO: This technically doesn't handle the case where the end_date of the sample
        # is before the start of the ZLB
        elseif date_presample_start(m) <= start_date <= date_zlb_start(m)
            n_regimes = 2

            shock_inds = inds_shocks_no_ant(m)
            QQ_ZLB = system[:QQ]
            QQ_preZLB = zeros(size(QQ_ZLB))
            QQ_preZLB[shock_inds, shock_inds] = QQ_ZLB[shock_inds, shock_inds]
            QQs = Matrix{S}[QQ_preZLB, QQ_ZLB]

        elseif date_zlb_start(m) < start_date
            n_regimes = 1
            QQs = Matrix{S}[system[:QQ]]
        end
    else
        n_regimes = 1
        QQs = Matrix{S}[system[:QQ]]
    end

    TTTs = fill(system[:TTT], n_regimes)
    RRRs = fill(system[:RRR], n_regimes)
    CCCs = fill(system[:CCC], n_regimes)
    ZZs  = fill(system[:ZZ], n_regimes)
    DDs  = fill(system[:DD], n_regimes)
    EEs  = fill(system[:EE], n_regimes)

    return TTTs, RRRs, CCCs, QQs, ZZs, DDs, EEs
end

function zlb_plus_regime_matrices(m::AbstractDSGEModel{S}, system::RegimeSwitchingSystem{S},
                                  start_date::Dates.Date = date_presample_start(m);
                                  n_regimes::Int = 0) where S<:AbstractFloat
    ### THIS IS WORK IN PROGRES, DOES NOT COVER ALL CASES FOR REGIME SWITCHING, ALSO ONLY FOR SWITCHING JUST ONCE.
    if n_mon_anticipated_shocks(m) > 0 # Need to turn off anticipated MP shocks for pre-ZLB regime
        if start_date < date_presample_start(m)
            error("Start date $start_date must be >= date_presample_start(m)")

            # TODO: This technically doesn't handle the case where the end_date of the sample
            # is before the start of the ZLB
        elseif date_presample_start(m) <= start_date <= date_zlb_start(m)
            shock_inds = inds_shocks_no_ant(m)
            QQ_preZLB_R1 = zeros(size(system[1][:QQ]))
            QQ_preZLB_R1[shock_inds, shock_inds] = system[1][:QQ][shock_inds, shock_inds]

            # Figure out the appropriate regime switching scheme
            n_regime1_periods = subtract_quarters(get_setting(m, :date_regime2_start), start_date)
            n_nozlb_periods = subtract_quarters(date_zlb_start(m), start_date)
            if n_regime1_periods > n_nozlb_periods
                QQ_ZLB = system[1][:QQ] # regime switch after ZLB
                QQ_ZLB_R2 = system[2][:QQ]
                QQs = Matrix{S}[QQ_preZLB_R1, QQ_ZLB, QQ_ZLB_R2]
            elseif n_regime1_periods == n_nozlb_periods
                QQ_ZLB = system[2][:QQ] # regime switch coincides ZLB
                QQs = Matrix{S}[QQ_preZLB_R1, QQ_ZLB]
            else
                QQ_ZLB = system[2][:QQ] # regime switch before ZLB
                QQ_preZLB_R2 = zeros(size(system[2][:QQ]))
                QQ_preZLB_R2[shock_inds, shock_inds] = system[2][:QQ][shock_inds, shock_inds]
                QQs = Matrix{S}[QQ_preZLB_R1, QQ_preZLB_R2, QQ_ZLB]
            end

            if n_regimes == 0
                n_regimes = length(QQs)
            elseif n_regimes < length(QQs)
                QQs = QQs[1:n_regimes]
            end
        elseif date_zlb_start(m) < start_date
            # NEED TO ADD REGIME SWITCHING
            n_regimes = 1
            QQs = Matrix{S}[system[:QQ]]
        end
    else
        # NEED TO ADD REGIME SWITCHING HERE TOO
        n_regimes = 2
        QQs = Matrix{S}[system[1][:QQ], system[2][:QQ]]
    end

    TTTs = vcat([system[1][:TTT]], fill(system[2][:TTT], n_regimes-1))
    RRRs = vcat([system[1][:RRR]], fill(system[2][:RRR], n_regimes-1))
    CCCs = vcat([system[1][:CCC]], fill(system[2][:CCC], n_regimes-1))
    ZZs  = vcat([system[1][:ZZ]], fill(system[2][:ZZ], n_regimes-1))
    DDs  = vcat([system[1][:DD]], fill(system[2][:DD], n_regimes-1))
    EEs  = vcat([system[1][:EE]], fill(system[2][:EE], n_regimes-1))

    return TTTs, RRRs, CCCs, QQs, ZZs, DDs, EEs
end
    #=  if n_mon_anticipated_shocks(m) > 0
        if start_date < date_presample_start(m)
            error("Start date $start_date must be >= date_presample_start(m)")

        # TODO: This technically doesn't handle the case where the end_date of the sample
        # is before the start of the ZLB
        elseif date_presample_start(m) <= start_date <= get_setting(m, :date_regime2_start) #date_zlb_start(m)
            n_regimes = 3

            shock_inds = inds_shocks_no_ant(m)
            QQ_ZLB = system[2][:QQ]
            QQ_preZLB = zeros(size(QQ_ZLB))
            QQ_preZLB[shock_inds, shock_inds] = QQ_ZLB[shock_inds, shock_inds]
            QQs = Matrix{S}[QQ_preZLB, QQ_preZLB, QQ_ZLB]

        elseif date_zlb_start(m) < start_date
            n_regimes = 2
            QQs = Matrix{S}[system[1][:QQ], system[2][:QQ]]
        end
    else
        n_regimes = 2
        QQs = Matrix{S}[system[1][:QQ], system[2][:QQ]]
    end

    TTTs = vcat([system[1][:TTT]], fill(system[2][:TTT], n_regimes-1))
    RRRs = vcat([system[1][:RRR]], fill(system[2][:RRR], n_regimes-1))
    CCCs = vcat([system[1][:CCC]], fill(system[2][:CCC], n_regimes-1))
    ZZs  = vcat([system[1][:ZZ]], fill(system[2][:ZZ], n_regimes-1))
    DDs  = vcat([system[1][:DD]], fill(system[2][:DD], n_regimes-1))
    EEs  = vcat([system[1][:EE]], fill(system[2][:EE], n_regimes-1))

    return TTTs, RRRs, CCCs, QQs, ZZs, DDs, EEs
end=#
