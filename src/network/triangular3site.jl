##########################################################################
# The Triangular3SiteNetwork is a macrocell network with three sites,
# placed on the vertices of an equilateral triangle. The simulation
# parameters are based on 3GPP Case 1 (TR 25.814 and TR 36.814) macrocell
# simulation environment. Distance-dependent pathloss and log-normal
# shadow fading is used. The shadow fading is correlated (with correlation
# coefficient 0.5) between the three cells.

##########################################################################
# Six sector antenna params from 3gpp TR 25.996
immutable SixSector3gppAntennaParams <: AntennaParams
    bore_sight_angle::Float64
    angle_with_3dB_gain::Float64
    min_antenna_gain_dB::Float64
end

get_antenna_gain(antenna_params::SixSector3gppAntennaParams, angle::Float64) =
    10^(-min(12*(angle/antenna_params.angle_with_3dB_gain)^2, antenna_params.min_antenna_gain_dB)/10)

##########################################################################
# Network definition
type Triangular3SiteNetwork{MS_t <: PhysicalMS, BS_t <: PhysicalBS, System_t <: System, PropagationEnvironment_t <: PropagationEnvironment} <: PhysicalNetwork
    MSs::Vector{MS_t}
    BSs::Vector{BS_t}

    system::System_t
    no_MSs_per_cell::Int
    propagation_environment::PropagationEnvironment_t
    inter_site_distance::Float64
    guard_distance::Float64
end
Base.show(io::IO, x::Triangular3SiteNetwork) =
    print(io, "Triangular3Site(I = $(length(x.BSs)), Kc = $(x.no_MSs_per_cell), ISD = $(x.inter_site_distance), GD = $(x.guard_distance))")
Base.showcompact(io::IO, x::Triangular3SiteNetwork) =
    print(io, "Triangular3Site($(length(x.BSs)), $(x.no_MSs_per_cell), $(x.inter_site_distance), $(x.guard_distance))")

get_no_MSs(network::Triangular3SiteNetwork) = 3*network.no_MSs_per_cell
get_no_BSs(network::Triangular3SiteNetwork) = 3
get_no_MSs_per_cell(network::Triangular3SiteNetwork) = network.no_MSs_per_cell

# The default parameter values are taken from 3GPP Case 1
# (TR 25.814 and TR 36.814).
function setup_triangular3site_network{AntennaParams_t <: AntennaParams}(
    no_BSs::Int, no_MSs_per_cell::Int, no_MS_antennas::Int, no_BS_antennas::Int;
    system = SinglecarrierSystem(AuxPrecodingParams(), 2., 15e3),
    propagation_environment = SimpleLargescaleFadingEnvironment(37.6, 15.3, 20, 8),
    inter_site_distance::Float64 = 500.,
    guard_distance::Float64 = 35.,
    transmit_power::Float64 = 10^(18.2/10),
    BS_antenna_gain_params::Vector{AntennaParams_t} = 
        [SixSector3gppAntennaParams(-90/180*pi, 35/180*pi, 23),
         SixSector3gppAntennaParams( 30/180*pi, 35/180*pi, 23),
         SixSector3gppAntennaParams(150/180*pi, 35/180*pi, 23)],
    user_priorities::Vector{Float64} = ones(Float64, no_BSs*no_MSs_per_cell),
    no_streams::Int = 1,
    MS_antenna_gain_dB::Float64 = 0.,
    receiver_noise_figure::Float64 = 9.)

    # Consistency check
    if no_BSs != 3
        error("Triangular3SiteNetwork only allows for I = 3.")
    end

    BSs = [
        PhysicalBS(no_BS_antennas,
            Position(0, sqrt((inter_site_distance/2)^2 + (inter_site_distance/(2*sqrt(3)))^2)),
            transmit_power, BS_antenna_gain_params[1]),
        PhysicalBS(no_BS_antennas,
            Position(-inter_site_distance/2, -inter_site_distance/(2*sqrt(3))),
            transmit_power, BS_antenna_gain_params[2]),
        PhysicalBS(no_BS_antennas,
            Position(+inter_site_distance/2, -inter_site_distance/(2*sqrt(3))),
            transmit_power, BS_antenna_gain_params[3])
    ]
    MSs = [ PhysicalMS(no_MS_antennas, Position(0, 0), Velocity(0, 0), user_priorities[k], no_streams, MS_antenna_gain_dB, receiver_noise_figure, SimpleLargescaleFadingEnvironmentState(zeros(Float64, no_BSs), falses(no_BSs))) for k = 1:3*no_MSs_per_cell ]

    Triangular3SiteNetwork(MSs, BSs, system, no_MSs_per_cell, 
        propagation_environment, inter_site_distance, guard_distance)
end

##########################################################################
# Standard cell assignment functions
function assign_cells_by_id{MS_t <: PhysicalMS, BS_t <: PhysicalBS, System_t <: System, PropagationEnvironment_t <: PropagationEnvironment}(network::Triangular3SiteNetwork{MS_t,BS_t,System_t,PropagationEnvironment_t})
    Kc = get_no_MSs_per_cell(network); I = get_no_BSs(network)
    assignment = Array(Int, I*Kc)

    for i = 1:I
        assignment[(i-1)*Kc+1:i*Kc] = i
    end

    return CellAssignment(assignment, I)
end

##########################################################################
# Simulation functions
function draw_user_drop!{MS_t <: PhysicalMS, BS_t <: PhysicalBS, System_t <: System}(network::Triangular3SiteNetwork{MS_t, BS_t, System_t, SimpleLargescaleFadingEnvironment})
    I = get_no_BSs(network); K = get_no_MSs(network)

    # Shadow fading covariance (correlation coefficient 0.5 between cells)
    Cov_shadow_sqrtm = chol(network.propagation_environment.shadow_sigma_dB^2*(ones(3,3) + eye(3))/2)

    for k = 1:K
        # Generate user position within standard triangle [0,30] degrees, to
        # the right of the base. Apply guard distance to x coordinate.
        xtri = sqrt(((network.inter_site_distance/2)^2 - network.guard_distance^2)*rand() + network.guard_distance^2)
        ytri = (xtri/sqrt(3))*rand()

        # Flip it over with probability 0.5
        if rand() < 0.5
            pos = [xtri;ytri]
        else
            pos = [xtri;-ytri]

            theta = 60*pi/180
            pos = [cos(theta) -sin(theta);sin(theta) cos(theta)]*pos
        end

        # Generate rotation angle
        i = div(k - 1, get_no_MSs_per_cell(network)) + 1 # serving BS id
        if i == 1
            theta = 240*pi/180
        elseif i == 2
            theta = 0
        elseif i == 3
            theta = 120*pi/180
        end

        # Get final user position
        position = [cos(theta) -sin(theta);sin(theta) cos(theta)]*pos
        network.MSs[k].position = (Position(position[1], position[2]) 
                                   + network.BSs[i].position)

        # Shadow fading
        network.MSs[k].propagation_environment_state =
            SimpleLargescaleFadingEnvironmentState(Cov_shadow_sqrtm*randn(I), falses(I)) # LoS not used in this model
    end
end

function draw_channel{MS_t <: PhysicalMS, BS_t <: PhysicalBS}(network::Triangular3SiteNetwork{MS_t, BS_t, SinglecarrierSystem, SimpleLargescaleFadingEnvironment})
    K = get_no_MSs(network); I = get_no_BSs(network)
    Ns = Int[ network.MSs[k].no_antennas for k = 1:K ]
    Ms = Int[ network.BSs[i].no_antennas for i = 1:I ]

    coefs = Array(Matrix{Complex128}, K, I)

    distances = get_distances(network)
    angles = get_angles(network)

    for k = 1:K
        for i = 1:I
            # Small scale fading
            coefs[k,i] = (1/sqrt(2))*(randn(Ns[k], Ms[i])
                                 + im*randn(Ns[k], Ms[i]))

            # Pathloss
            pathloss_factor = sqrt(10^(-(network.propagation_environment.pathloss_beta + network.propagation_environment.pathloss_alpha*log10(distances[k,i]))/10))

            # Shadow fading
            shadow_factor = sqrt(10^(network.MSs[k].propagation_environment_state.shadow_realizations_dB[i]/10))

            # Penetration loss
            penetration_loss_factor = sqrt(10^(-network.propagation_environment.penetration_loss_dB/10))

            # BS antenna gain
            bs_antenna_gain = sqrt(get_antenna_gain(network.BSs[i].antenna_params, angles[k,i]))

            # MS antenna gain
            ms_antenna_gain = sqrt(10^(network.MSs[k].antenna_gain_dB/10))

            # Apply scale factors
            coefs[k,i] *= pathloss_factor*shadow_factor*penetration_loss_factor*bs_antenna_gain*ms_antenna_gain
        end
    end

    return SinglecarrierChannel(coefs, Ns, Ms, K, I)
end

##########################################################################
# Visualization functions
# function plot_network_layout(network::Triangular3SiteNetwork)
#     using PyCall; @pyimport matplotlib.pyplot as plt
# end
