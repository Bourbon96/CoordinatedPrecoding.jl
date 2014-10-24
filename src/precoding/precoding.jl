##########################################################################
# Reference implementation of standard coordinated precoding algorithms
include("Eigenprecoding.jl")
include("Gomadam2008_MaxSINR.jl")
include("Komulainen2013_WMMSE.jl")
include("Razaviyayn2013_MaxMinWMMSE.jl")
include("Shi2011_WMMSE.jl")

##########################################################################
# Standard functions to calculate rates from optimal MSE weights
function calculate_logdet_rates(state::Union(Gomadam2008_MaxSINRState, Komulainen2013_WMMSEState, Razaviyayn2013_MaxMinWMMSEState, Shi2011_WMMSEState))
    K = length(state.W)
    ds = Int[ size(state.W[k], 1) for k = 1:K ]; max_d = maximum(ds)

    logdet_rates = Array(Float64, K, max_d)

    for k = 1:K
        # W is p.d., so we should only get real eigenvalues. Numerically we may
        # get some imaginary noise however. Also, numerically the eigenvalues
        # may be less than 1, so we need to handle that to not get negative
        # rates.
        r = log2(max(1, real(eigvals(state.W[k]))))

        if ds[k] < max_d
            logdet_rates[k,:] = cat(1, r, zeros(Float64, max_d - ds[k]))
        else
            logdet_rates[k,:] = r
        end
    end

    return logdet_rates
end

function calculate_MMSE_rates(state::Union(Gomadam2008_MaxSINRState, Komulainen2013_WMMSEState, Razaviyayn2013_MaxMinWMMSEState, Shi2011_WMMSEState))
    K = length(state.W)
    ds = Int[ size(state.W[k], 1) for k = 1:K ]; max_d = maximum(ds)

    MMSE_rates = Array(Float64, K, max_d)

    for k = 1:K
        # Invert W to get MMSE matrix and pick out diagonal elements, to obtain
        # MSE performance of MMSE receiver. Then take log2 of the reciprocal
        # to get the rates for the streams.
        # N.B. it is a little wasteful to take the inverse here, but it makes
        # for cleaner code in the algorithms. Also, these matrices are typically
        # small (like 2-by-2 or 3-by-3), so the complexity isn't too bad.
        E = state.W[k]\eye(state.W[k])
        r = log2(max(1, real(1./diag(E))))

        if ds[k] < max_d
            MMSE_rates[k,:] = cat(1, r, zeros(Float64, max_d - ds[k]))
        else
            MMSE_rates[k,:] = r
        end
    end

    return MMSE_rates
end

##########################################################################
# Initialization functions
zero_receivers(channel::SinglecarrierChannel, ds::Vector{Int}) = 
    [ zeros(Complex128, channel.Ns[k], ds[k]) for k = 1:channel.K ]

unity_MSE_weights(ds::Vector{Int}) = [ Hermitian(eye(ds[k])) for k = 1:length(ds) ]

function initial_precoders(channel::SinglecarrierChannel, Ps::Vector{Float64},
    sigma2s::Vector{Float64}, ds::Vector{Int}, cell_assignment::CellAssignment,
    settings)

    V = Array(Matrix{Complex128}, channel.K)

    if settings["initial_precoders"] == "dft"
        for i = 1:channel.I
            served = served_MS_ids(i, cell_assignment)
            Kc = length(served)

            for k in served
                V[k] = sqrt(Ps[i]/(channel.Ms[i]*ds[k]*Kc))*fft(eye(channel.Ms[i], ds[k]), 1)
            end
        end
    elseif settings["initial_precoders"] == "white"
        for i = 1:channel.I
            served = served_MS_ids(i, cell_assignment)
            Kc = length(served)

            for k in served
                V[k] = sqrt(Ps[i]/(ds[k]*Kc))*eye(channel.Ms[i], ds[k])
            end
        end
    elseif settings["initial_precoders"] == "zeros"
        for i = 1:channel.I
            served = served_MS_ids(i, cell_assignment)
            Kc = length(served)

            for k in served
                V[k] = zeros(channel.Ms[i], ds[k])
            end
        end
    elseif settings["initial_precoders"] == "eigendirection"
        for i = 1:channel.I
            served = served_MS_ids(i, cell_assignment)
            Kc = length(served)

            for k in served
                _, _, Vtmp = svd(channel.H[k,i])
                V[k] = sqrt(Ps[i]/Kc)*Vtmp[:, 1:ds[k]]/vecnorm(Vtmp[:, 1:ds[k]])
            end
        end
    end

    return V
end
