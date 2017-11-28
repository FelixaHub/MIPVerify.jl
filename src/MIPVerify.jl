module MIPVerify

using Base.Cartesian
using JuMP
using ConditionalJuMP
using Gurobi

JuMPReal = Union{Real, JuMP.AbstractJuMPScalar}

abstract type LayerParameters end

struct Conv2DParameters{T<:JuMPReal, U<:JuMPReal} <: LayerParameters
    filter::Array{T, 4}
    bias::Array{U, 1}

    function Conv2DParameters{T, U}(filter::Array{T, 4}, bias::Array{U, 1}) where {T<:JuMPReal, U<:JuMPReal}
        (filter_height, filter_width, filter_in_channels, filter_out_channels) = size(filter)
        bias_out_channels = length(bias)
        @assert(
            filter_out_channels == bias_out_channels,
            "For the convolution layer, number of output channels in filter, $filter_out_channels, does not match number of output channels in bias, $bias_out_channels."
        )
        return new(filter, bias)
    end

end

function Conv2DParameters(filter::Array{T, 4}, bias::Array{U, 1}) where {T<:JuMPReal, U<:JuMPReal}
    Conv2DParameters{T, U}(filter, bias)
end

function Conv2DParameters(filter::Array{T, 4}) where {T<:JuMPReal}
    bias_out_channels::Int = size(filter)[4]
    bias = zeros(bias_out_channels)
    Conv2DParameters(filter, bias)
end

struct PoolParameters{N} <: LayerParameters
    strides::NTuple{N, Int}
end

struct MaxpoolParameters{N} <: LayerParameters
    strides::NTuple{N, Int}
end

struct ConvolutionLayerParameters{T<:Real, U<:Real} <: LayerParameters
    conv2dparams::Conv2DParameters{T, U}
    maxpoolparams::PoolParameters{4}

end

function ConvolutionLayerParameters{T<:Real, U<:Real}(filter::Array{T, 4}, bias::Array{U, 1}, strides::NTuple{4, Int})
    ConvolutionLayerParameters(Conv2DParameters(filter, bias), PoolParameters(strides))
end

struct MatrixMultiplicationParameters{T<:Real, U<:Real} <: LayerParameters
    matrix::Array{T, 2}
    bias::Array{U, 1}

    function MatrixMultiplicationParameters{T, U}(matrix::Array{T, 2}, bias::Array{U, 1}) where {T<:Real, U<:Real}
        (matrix_height, matrix_width) = size(matrix)
        bias_height = length(bias)
        @assert(
            matrix_height == bias_height,
            "Number of output channels in matrix, $matrix_height, does not match number of output channels in bias, $bias_height."
        )
        return new(matrix, bias)
    end

end

function MatrixMultiplicationParameters(matrix::Array{T, 2}, bias::Array{U, 1}) where {T<:Real, U<:Real}
    MatrixMultiplicationParameters{T, U}(matrix, bias)
end

struct SoftmaxParameters{T<:Real, U<:Real} <: LayerParameters
    mmparams::MatrixMultiplicationParameters{T, U}
end

function SoftmaxParameters(matrix::Array{T, 2}, bias::Array{U, 1}) where {T<:Real, U<:Real}
    SoftmaxParameters(MatrixMultiplicationParameters(matrix, bias))
end

struct FullyConnectedLayerParameters{T<:Real, U<:Real} <: LayerParameters
    mmparams::MatrixMultiplicationParameters{T, U}
end

function FullyConnectedLayerParameters(matrix::Array{T, 2}, bias::Array{U, 1}) where {T<:Real, U<:Real}
    FullyConnectedLayerParameters(MatrixMultiplicationParameters(matrix, bias))
end

abstract type NeuralNetParameters end

# TODO: Support empty convlayer array, empty fclayer array, and optional softmax params

struct StandardNeuralNetParameters <: NeuralNetParameters
    convlayer_params::Array{ConvolutionLayerParameters, 1}
    fclayer_params::Array{FullyConnectedLayerParameters, 1}
    softmax_params::SoftmaxParameters
    UUID::String
end

"""
Computes a 2D-convolution given 4-D `input` and `filter` tensors.

Mirrors `tf.nn.conv2d` from `tensorflow` package, with `strides` = [1, 1, 1, 1],
 `padding` = 'SAME'.

 # Throws
 * ArgumentError if input and filter are not compatible.
"""
function conv2d{T<:JuMPReal, U<:JuMPReal, V<:JuMPReal}(
    input::Array{T, 4},
    params::Conv2DParameters{U, V})

    # Todo: Print this one level up
    if T<:JuMP.AbstractJuMPScalar || U<:JuMP.AbstractJuMPScalar || V<:JuMP.AbstractJuMPScalar
        println("Setting convolution constraints ... ")
    end
    filter = params.filter

    (batch, in_height, in_width, input_in_channels) = size(input)
    (filter_height, filter_width, filter_in_channels, filter_out_channels) = size(filter)
    
    @assert(
        input_in_channels == filter_in_channels, 
        "Number of channels in input, $input_in_channels, does not match number of channels, $filter_in_channels, that filters operate on."
    )
    
    output_size = (batch, in_height, in_width, filter_out_channels)

    # Considered using offset arrays here, but could not get it working.

    # Calculating appropriate offsets so that center of kernel is matched with
    # cell at which correlation is being calculated. Note that tensorflow
    # chooses a specific convention for a dimension with even size which we
    # replicate here.
    filter_height_offset = round(Int, filter_height/2, RoundUp)
    filter_width_offset = round(Int, filter_width/2, RoundUp)
    W = Base.promote_op(+, V, Base.promote_op(*, T, U))
    output = Array{W}(output_size)

    @nloops 4 i output begin
        s::W = 0
        @nloops 4 j filter begin
            if i_4 == j_4
                x = i_2 + j_1 - filter_height_offset
                y = i_3 + j_2 - filter_width_offset
                if x > 0 && y > 0 && x<=in_height && y<=in_width
                    # Doing bounds check to make sure that we stay within bounds
                    # for input. This effectively zero-pads the input.
                    # TODO: Use default checkbounds function here instead?
                    s = increment!(s, input[i_1, x, y, j_3], filter[j_1, j_2, j_3, j_4])
                end
            end
        end
        s += params.bias[i_4]
        (@nref 4 output i) = s
    end

    return output
end

function increment!(s::Real, input_val::Real, filter_val::Real)
    return s + input_val*filter_val
end

function increment!(s::JuMP.AffExpr, input_val::JuMP.AffExpr, filter_val::Real)
    append!(s, input_val*filter_val)
    return s
end

function increment!(s::JuMP.AffExpr, input_val::JuMP.Variable, filter_val::Real)
    push!(s, Float64(filter_val), input_val)
end

function increment!(s::JuMP.AffExpr, input_val::Real, filter_val::JuMP.AffExpr)
    append!(s, filter_val*input_val)
    return s
end

function increment!(s::JuMP.AffExpr, input_val::Real, filter_val::JuMP.Variable)
    push!(s, Float64(input_val), filter_val)
end

"""
For pooling operations on an array where a given element in the output array
corresponds to equal-sized blocks in the input array, returns (for a given
dimension) the index range in the input array corresponding to a particular
index `output_index` in the output array.

Returns an empty array if the `output_index` does not correspond to any input
indices.

# Arguments
* `stride::Integer`: the size of the operating blocks along the active
     dimension.

"""
function getsliceindex(input_array_size::Int, stride::Int, output_index::Int)::Array{Int, 1}
    parent_start_index = (output_index-1)*stride+1
    parent_end_index = min((output_index)*stride, input_array_size)
    if parent_start_index > parent_end_index
        return []
    else
        return parent_start_index:parent_end_index
    end
end

"""
For pooling operations on an array, returns a view of the parent array
corresponding to the `output_index` in the output array.
"""
function getpoolview{T, N}(input_array::AbstractArray{T, N}, strides::NTuple{N, Int}, output_index::NTuple{N, Int})::SubArray{T, N}
    it = zip(size(input_array), strides, output_index)
    input_index_range = map(x -> getsliceindex(x...), it)
    return view(input_array, input_index_range...)
end

"""
For pooling operations on an array, returns the expected size of the output
array.
"""
function getoutputsize{T, N}(input_array::AbstractArray{T, N}, strides::NTuple{N, Int})::NTuple{N, Int}
    output_size = ((x, y) -> round(Int, x/y, RoundUp)).(size(input_array), strides)
    return output_size
end

"""
Returns output from applying `f` to subarrays of `input_array`, with the windows
determined by the `strides`.
"""
function poolmap{T, N}(f::Function, input_array::AbstractArray{T, N}, strides::NTuple{N, Int})
    output_size = getoutputsize(input_array, strides)
    output_indices = collect(CartesianRange(output_size))
    return ((I) -> f(getpoolview(input_array, strides, I.I))).(output_indices)
end

function avgpool{T<:Real, N}(
    input::AbstractArray{T, N},
    params::PoolParameters{N})
    return poolmap(mean, input, params.strides)
end

"""
Computes the result of a max-pooling operation on `input` with specified
`strides`.
"""
function maxpool{T<:Real, N}(
    input::AbstractArray{T, N},
    params::PoolParameters{N})::Array{T, N}
    # NB: Tried to use pooling function from Knet.relu but it had way too many
    # incompatibilities
    return poolmap(Base.maximum, input, params.strides)
end

function maxpool{T<:JuMP.AbstractJuMPScalar, N}(
    input::Array{T, N},
    params::PoolParameters{N})
    println("Setting maxpool constraints ... ")
    return poolmap(MIPVerify.maximum, input, params.strides)
end

function maximum{T<:JuMP.AbstractJuMPScalar, N}(xs::AbstractArray{T, N})::JuMP.Variable
    @assert length(xs) >= 1
    model = ConditionalJuMP.getmodel(xs[1])
    ls = tight_lowerbound.(xs)
    us = tight_upperbound.(xs)
    l = Base.maximum(ls)
    u = Base.maximum(us)
    x_max = @variable(model,
        lowerbound = l,
        upperbound = u)
    
    xs_filtered::Array{T, 1} = map(
        t-> t[1], 
        Iterators.filter(
            t -> t[2]>l, 
            zip(xs, us)
        )
    )

    if length(xs_filtered) == 1
        @constraint(model, x_max == xs_filtered[1])
    else
        indicators = []
        for (i, x) in enumerate(xs_filtered)
            a = @variable(model, category =:Bin)
            umaxi = Base.maximum(us[1:end .!= i])
            @constraint(model, x_max <= x + (1-a)*(umaxi - ls[i]))
            @constraint(model, x_max >= x)
            push!(indicators, a)
        end
        @constraint(model, sum(indicators) == 1)
    end
    return x_max
end

"""
Computes the rectification of `x`
"""
function relu(x::Real)::Real
    return max(0, x)
end

function relu(x::JuMP.AbstractJuMPScalar)::JuMP.Variable
    model = ConditionalJuMP.getmodel(x)
    x_rect = @variable(model)
    u = tight_upperbound(x)
    l = tight_lowerbound(x)

    if u < 0
        # rectified value is always 0
        @constraint(model, x_rect == 0)
        setlowerbound(x_rect, 0)
        setupperbound(x_rect, 0)
    elseif l > 0
        # rectified value is always equal to x itself.
        @constraint(model, x_rect == x)
        setlowerbound(x_rect, l)
        setupperbound(x_rect, u)
    else
        a = @variable(model, category = :Bin)

        # refined big-M formulation that takes advantage of the knowledge
        # that lower and upper bounds  are different.
        @constraint(model, x_rect <= x + (-l)*(1-a))
        @constraint(model, x_rect >= x)
        @constraint(model, x_rect <= u*a)
        @constraint(model, x_rect >= 0)

        # model.ext[:objective] = get(model.ext, :objective, 0) + x_rect - x
        model.ext[:objective] = get(model.ext, :objective, 0) + x_rect - x*u/(u-l)

        # Manually set the bounds for x_rect so they can be used by downstream operations.
        setlowerbound(x_rect, 0)
        setupperbound(x_rect, u)
    end

    return x_rect
end

function convlayer{T<:JuMPReal}(
    x::Array{T, 4},
    params::ConvolutionLayerParameters)
    x_conv = params.conv2dparams(x)
    x_maxpool = maxpool(x_conv, params.maxpoolparams)
    if T<:JuMP.AbstractJuMPScalar println("Setting rectified linearity constraints ... ") end
    x_relu = relu.(x_maxpool)
    return x_relu
end

function matmul{T<:JuMPReal}(
    x::Array{T, 1}, 
    params::MatrixMultiplicationParameters)
    return params.matrix*x .+ params.bias
end

function fullyconnectedlayer{T<:JuMPReal}(
    x::Array{T, 1}, 
    params::FullyConnectedLayerParameters)
    if T<:JuMP.AbstractJuMPScalar println("Setting rectified linearity constraints ... ") end
    return relu.(x |> params.mmparams)
end

# TODO: Handle interaction between setting max index and setting unmax index.
# TODO: rename to set_max_output_index

function set_max_index{T<:JuMP.AbstractJuMPScalar}(
    x::Array{T, 1},
    target_index::Integer,
    tol::Real = 0)
    """
    Sets the target index to be the maximum.

    Tolerance is the amount of gap between x[target_index] and the other elements.
    """
    @assert length(x) >= 1
    @assert (target_index >= 1) && (target_index <= length(x))
    model = ConditionalJuMP.getmodel(x[1])

    other_vars = [x[1:target_index-1]; x[target_index+1:end]]
    @constraint(model, other_vars - x[target_index] .<= -tol)
    
end

function set_unmax_index{T<:JuMP.AbstractJuMPScalar}(
    x::Array{T, 1},
    target_index::Integer,
    tol::Real = 0)
    """
    Sets the target index to NOT be the maximum.
    """
    @assert length(x) >= 1
    @assert (target_index >= 1) && (target_index <= length(x))
    model = ConditionalJuMP.getmodel(x[1])
    
    x_max = MIPVerify.maximum(x)
    @constraint(model, x_max - x[target_index] >= tol)
end

function get_max_index{T<:Real}(
    x::Array{T, 1})::Integer
    return findmax(x)[2]
end

function tight_upperbound(x::JuMP.AbstractJuMPScalar)
    u = upperbound(x)
    m = ConditionalJuMP.getmodel(x)
    @objective(m, Max, x)
    status = solve(m)
    if status == :Optimal || status == :UserLimit
        u = min(getobjectivebound(m), u)
        if status == :UserLimit
            gap = abs(1-getobjectivebound(m)/getobjectivevalue(m))
            println("Gap was $gap.")
        end
    end
    println("Δu = $(upperbound(x)-u)")
    return u
end

function tight_lowerbound(x::JuMP.AbstractJuMPScalar)
    l = lowerbound(x)
    m = ConditionalJuMP.getmodel(x)
    @objective(m, Min, x)
    status = solve(m)
    if status == :Optimal || status == :UserLimit
        l = max(getobjectivebound(m), l)
        if status == :UserLimit
            gap = abs(1-getobjectivebound(m)/getobjectivevalue(m))
            println("Gap was $gap.")
        end
    end
    println("Δl = $(l-lowerbound(x))")
    return l
end

function set_input_constraint{T<:Real}(v_input::Array{JuMP.Variable}, input::Array{T})
    @assert length(v_input) > 0
    m = ConditionalJuMP.getmodel(v_input[1])
    @constraint(m, v_input .== input)
end

(p::MatrixMultiplicationParameters){T<:JuMPReal}(x::Array{T, 1}) = matmul(x, p)
(p::Conv2DParameters){T<:JuMPReal}(x::Array{T, 4}) = conv2d(x, p)

(p::ConvolutionLayerParameters){T<:JuMPReal}(x::Array{T, 4}) = convlayer(x, p)
(p::FullyConnectedLayerParameters){T<:JuMPReal}(x::Array{T, 1}) = fullyconnectedlayer(x, p)
(p::SoftmaxParameters){T<:JuMPReal}(x::Array{T, 1}) = p.mmparams(x)

(ps::Array{U, 1}){T<:JuMPReal, U<:Union{ConvolutionLayerParameters, FullyConnectedLayerParameters}}(x::Array{T}) = (
    length(ps) == 0 ? x : ps[2:end](ps[1](x))
)

(p::StandardNeuralNetParameters){T<:JuMPReal}(x::Array{T, 4}) = (
    x |> p.convlayer_params |> MIPVerify.flatten |> p.fclayer_params |> p.softmax_params
)

"""
Permute dimensions of array because Python flattens arrays in the opposite order.
"""
function flatten{T, N}(x::Array{T, N})
    # return x[:]
    return permutedims(x, N:-1:1)[:]
end

function abs_ge(x::JuMP.AbstractJuMPScalar)::JuMP.Variable
    model = ConditionalJuMP.getmodel(x)
    x_abs = @variable(model)
    u = upperbound(x)
    l = lowerbound(x)
    if u < 0
        @constraint(model, x_abs == -x)
        setlowerbound(x_abs, -u)
        setupperbound(x_abs, -l)
    elseif l > 0
        @constraint(model, x_abs == x)
        setlowerbound(x_abs, l)
        setupperbound(x_abs, u)
    else
        @constraint(model, x_abs >= x)
        @constraint(model, x_abs >= -x)
        setlowerbound(x_abs, 0)
        setupperbound(x_abs, max(-l, u))
    end
    return x_abs
end

function abs_strict(x::JuMP.AbstractJuMPScalar)::JuMP.Variable
    model = ConditionalJuMP.getmodel(x)
    x_abs = @variable(model)
    u = upperbound(x)
    l = lowerbound(x)
    if u < 0
        @constraint(model, x_abs == -x)
        setlowerbound(x_abs, -u)
        setupperbound(x_abs, -l)
    elseif l > 0
        @constraint(model, x_abs == x)
        setlowerbound(x_abs, l)
        setupperbound(x_abs, u)
    else
        a = @variable(model, category = :Bin)
        @constraint(model, x_abs <= x + 2(-l)*(1-a))
        @constraint(model, x_abs >= x)
        @constraint(model, x_abs <= -x + 2*u*a)
        @constraint(model, x_abs >= -x)
        setlowerbound(x_abs, 0)
        setupperbound(x_abs, max(-l, u))
    end
    return x_abs
end

# TODO: Not everything from solve has been included here.

function example_solve(nnparams, input, target_label; tolerance = 0.0, norm_type = 1)
    """
    Solving (without logging etc) for a simple example.
    """
    d = initialize_additive(nnparams, input, rebuild = true)
    m = d["model"]
    v_e = d["perturbation"]
    v_output = d["output variable"]
    v_input = d["input variable"]

    # Set perturbation constraint
    e_norm = get_norm(norm_type, v_e)
    @objective(m, Min, e_norm)

    # Set input constraint
    set_input_constraint(v_input, input)

    # Set output constraint
    set_max_index(v_output, target_label, tolerance)
    println("Attempting to find adversarial example. Neural net predicted label is $(input |> nnparams |> get_max_index), target label is $target_label")
    status = solve(m)
end

function initialize_additive{T<:Real, N}(
    nn_params::Union{NeuralNetParameters, LayerParameters},
    input::Array{T, N}; rebuild::Bool = false
    )::Dict
    input_size = size(input)
    model_file_name = "models/$(nn_params.UUID).$(input_size).additive.jls"
    if isfile(model_file_name) && !rebuild
        println("Loading model from cache.")
        d = open(model_file_name, "r") do f
            deserialize(f)
        end
    else
        println("Rebuilding model from scratch.")
        d = initialize_additive_uncached(nn_params, input_size)
        open(model_file_name, "w") do f
            serialize(f, d)
        end
    return d
    end
end

function initialize_additive_uncached{N}(
    nn_params::Union{NeuralNetParameters, LayerParameters},
    input_size::NTuple{N}
    )::Dict

    m = Model(solver=GurobiSolver(MIPFocus = 0, OutputFlag=0, TimeLimit = 120))
    input_range = CartesianRange(input_size)

    v_input = map(_ -> @variable(m), input_range) # what you're trying to perturb
    v_e = map(_ -> @variable(m), input_range) # perturbation added
    v_x0 = map(_ -> @variable(m, lowerbound = 0, upperbound = 1), input_range) # perturbation + original image
    @constraint(m, v_x0 .== v_input + v_e)

    v_output = v_x0 |> nn_params

    setsolver(m, GurobiSolver(MIPFocus = 3))

    d = Dict()
    d["model"] = m
    d["input variable"] = v_input
    d["base layer variable"] = v_x0
    d["perturbation"] = v_e
    d["output variable"] = v_output
    
    return d
end

function check_size{N}(input::AbstractArray, expected_size::NTuple{N, Int})::Void
    input_size = size(input)
    @assert input_size == expected_size "Input size $input_size did not match expected size $expected_size."
end

function check_size(params::ConvolutionLayerParameters, sizes::NTuple{4, Int})::Void
    check_size(params.conv2dparams, sizes)
end

function check_size(params::Conv2DParameters, sizes::NTuple{4, Int})::Void
    check_size(params.filter, sizes)
    check_size(params.bias, (sizes[4], ))
end

function check_size(params::MatrixMultiplicationParameters, sizes::NTuple{2, Int})::Void
    check_size(params.matrix, sizes)
    check_size(params.bias, (sizes[1], ))
end

function get_label{T<:Real}(y::Array{T, 2}, test_index::Int)::Int
    return findmax(y[test_index, :])[2]
end

function get_input{T<:Real}(x::Array{T, 4}, test_index::Int)::Array{T, 4}
    return x[test_index:test_index, :, :, :]
end

# Maybe merge functionality?
function get_matrix_params(
    param_dict::Dict{String},
    layer_name::String,
    expected_size::NTuple{2, Int};
    matrix_name::String = "weight",
    bias_name::String = "bias")

    params = MatrixMultiplicationParameters(
        transpose(param_dict["$layer_name/$matrix_name"]),
        squeeze(param_dict["$layer_name/$bias_name"], 1)
    )

    check_size(params, expected_size)

    return params
end

function get_conv_params(
    param_dict::Dict{String},
    layer_name::String,
    expected_size::NTuple{4, Int};
    matrix_name::String = "weight",
    bias_name::String = "bias")

    params = Conv2DParameters(
        param_dict["$layer_name/$matrix_name"],
        squeeze(param_dict["$layer_name/$bias_name"], 1)
    )

    check_size(params, expected_size)

    return params
end

function get_norm{T<:Real}(
    norm_type::Int,
    v::Array{T}
)
    if norm_type == 1
        return sum(abs.(v))
    elseif norm_type == 2
        return sqrt(sum(v.^2))
    elseif norm_type == Inf
        return maximum(Iterators.flatten(abs.(v)))
    end
end

function get_norm{T<:JuMP.AbstractJuMPScalar}(
    norm_type::Int,
    v::Array{T}
)
    if norm_type == 1
        abs_v = abs_ge.(v)
        return sum(abs_v)
    elseif norm_type == 2
        return sum(v.*v)
    elseif norm_type == Inf
        return v |> MIPVerify.flatten |> MIPVerify.maximum
    end
end

end
