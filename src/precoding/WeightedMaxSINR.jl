immutable WeightedMaxSINRState
    U::Array{Matrix{Complex128},1}
    W::Array{Hermitian{Complex128},1} # these are only used for rate calculations
    V::Array{Matrix{Complex128},1}
end

function WeightedMaxSINR(channel::SinglecarrierChannel, network::Network)
    cell_assignment = get_cell_assignment(network)

    K = get_no_MSs(network)
    Ps = get_transmit_powers(network)
    sigma2s = get_receiver_noise_powers(network)
    ds = get_no_streams(network)
    aux_params = get_aux_precoding_params(network)

    state = WeightedMaxSINRState(
        zero_receivers(channel, ds),
        unity_MSE_weights(ds),
        initial_precoders(channel, Ps, sigma2s, ds, cell_assignment, aux_params))
    objective = Float64[]
    logdet_rates = Array(Float64, K, maximum(ds), aux_params["max_iters"])
    MMSE_rates = Array(Float64, K, maximum(ds), aux_params["max_iters"])
    allocated_power = Array(Float64, K, maximum(ds), aux_params["max_iters"])

    iters = 0; conv_crit = Inf
    while iters < aux_params["max_iters"]
        update_MSs!(state, channel, sigma2s, cell_assignment)
        iters += 1

        # Results after this iteration
        logdet_rates[:,:,iters] = calculate_logdet_rates(state)
        push!(objective, sum(logdet_rates[:,:,iters]))
        MMSE_rates[:,:,iters] = calculate_MMSE_rates(state)
        allocated_power[:,:,iters] = calculate_allocated_power(state)

        # Check convergence
        if iters >= 2
            conv_crit = abs(objective[end] - objective[end-1])/abs(objective[end-1])
            if conv_crit < aux_params["stop_crit"]
                Lumberjack.debug("WeightedMaxSINR converged.",
                    { :no_iters => iters, :final_objective => objective[end],
                      :conv_crit => conv_crit, :stop_crit => aux_params["stop_crit"],
                      :max_iters => aux_params["max_iters"] })
                break
            end
        end

        # Begin next iteration, unless the loop will end
        if iters < aux_params["max_iters"]
            update_BSs!(state, channel, Ps, sigma2s, cell_assignment, aux_params)
        end
    end
    if iters == aux_params["max_iters"]
        Lumberjack.debug("WeightedMaxSINR did NOT converge.",
            { :no_iters => iters, :final_objective => objective[end],
              :conv_crit => conv_crit, :stop_crit => aux_params["stop_crit"],
              :max_iters => aux_params["max_iters"] })
    end

    results = PrecodingResults()
    if aux_params["output_protocol"] == :all_iterations
        results["objective"] = objective
        results["logdet_rates"] = logdet_rates
        results["MMSE_rates"] = MMSE_rates
        results["allocated_power"] = allocated_power
    elseif aux_params["output_protocol"] == :final_iteration
        results["objective"] = objective[iters]
        results["logdet_rates"] = logdet_rates[:,:,iters]
        results["MMSE_rates"] = MMSE_rates[:,:,iters]
        results["allocated_power"] = allocated_power[:,:,iters]
    end
    return results
end

function update_MSs!(state::WeightedMaxSINRState,
    channel::SinglecarrierChannel, sigma2s::Vector{Float64},
    cell_assignment::CellAssignment)

    ds = [ size(state.W[k], 1) for k = 1:channel.K ]

    for i = 1:channel.I
        for k in served_MS_ids(i, cell_assignment)
            Phi = Hermitian(complex(sigma2s[k]*eye(channel.Ns[k])))
            for j = 1:channel.I
                for l in served_MS_ids(j, cell_assignment)
                    #Phi += Hermitian(channel.H[k,j]*(state.V[l]*state.V[l]')*channel.H[k,j]')
                    Base.LinAlg.BLAS.herk!(Phi.uplo, 'N', complex(1.), channel.H[k,j]*state.V[l], complex(1.), Phi.S)
                end
            end

            # Per-stream receivers
            for n = 1:ds[k]
                Phi_i_plus_n = Hermitian(
                    Base.LinAlg.BLAS.herk!(Phi.uplo, 'N', complex(-1.), channel.H[k,i]*state.V[k][:,n], complex(1.), copy(Phi.S)),
                    Phi.uplo)
                u = Phi_i_plus_n\channel.H[k,i]*state.V[k][:,n]
                state.U[k][:,n] = u/norm(u,2)
            end

            # Optimal MSE weights
            F = channel.H[k,i]*state.V[k]
            Ummse = Phi\F
            state.W[k] = Hermitian((eye(ds[k]) - Ummse'*F)\eye(ds[k]))

            # Weighting
            state.U[k] = state.U[k]*sqrtm(state.W[k])
            state.U[k] = state.U[k]/vecnorm(state.U[k])
        end
    end
end

function update_BSs!(state::WeightedMaxSINRState,
    channel::SinglecarrierChannel, Ps::Vector{Float64},
    sigma2s::Vector{Float64}, cell_assignment::CellAssignment,
    aux_params::AuxPrecodingParams)

    ds = [ size(state.W[k], 1) for k = 1:channel.K ]

    for i = 1:channel.I
        # Virtual uplink covariance
        Gamma = Hermitian(complex(zeros(channel.Ms[i],channel.Ms[i])))
        for j = 1:channel.I
            for l = served_MS_ids(j, cell_assignment)
                #Gamma += Hermitian(channel.H[k,i]'*(state.U[k]*state.U[k]')*channel.H[k,i])
                Base.LinAlg.BLAS.herk!(Gamma.uplo, 'N', complex(1.), channel.H[l,i]'*state.U[l], complex(1.), Gamma.S)
            end
        end

        # Per-stream precoders
        served = served_MS_ids(i, cell_assignment)
        Nserved = length(served)
        for k in served
            for n = 1:ds[k]
                Gamma_i_plus_n = Hermitian(
                    Base.LinAlg.BLAS.herk!(Gamma.uplo, 'N', complex(-1.), channel.H[k,i]'*state.U[k][:,n], complex(1.), copy(Gamma.S)) + (sigma2s[k]/Ps[i])*eye(channel.Ms[i]),
                    Gamma.uplo)
                v = Gamma_i_plus_n\channel.H[k,i]'*state.U[k][:,n]
                state.V[k][:,n] = v/norm(v,2)
            end

            # Weighting
            state.V[k] = state.V[k]*sqrtm(state.W[k])
            state.V[k] = sqrt(Ps[i]/Nserved)*state.V[k]/vecnorm(state.V[k])
        end
    end
end
