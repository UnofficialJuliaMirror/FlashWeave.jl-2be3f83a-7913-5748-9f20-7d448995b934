module Learning

export LGL, si_HITON_PC

using LightGraphs
using DataStructures
using StatsBase
using Clustering

using FlashWeave.Tests
using FlashWeave.Types
using FlashWeave.Misc
using FlashWeave.Statfuns
using FlashWeave.StackChannels


function interleaving_phase{ElType <: Real}(T::Int, candidates::AbstractVector{Int}, data::AbstractMatrix{ElType},
    test_obj::AbstractTest, max_k::Integer, alpha::AbstractFloat, hps::Integer=5, n_obs_min::Integer=0,
    prev_TPC_dict::OrderedDict{Int,Tuple{Float64,Float64}}=Dict(), time_limit::AbstractFloat=0.0, start_time::AbstractFloat=0.0,
        debug::Integer=0, whitelist::Set{Int}=Set{Int}(), blacklist::Set{Int}=Set{Int}(),
    rej_dict::Dict{Int, Tuple{Tuple,TestResult}}=Dict{Int, Tuple{Tuple,TestResult}}(), track_rejections::Bool=false,
        z::Vector{ElType}=ElType[])


    nz = is_zero_adjusted(test_obj)
    is_discrete = isdiscrete(test_obj)
    is_dense = !issparse(data)

    if isempty(prev_TPC_dict)
        TPC = [candidates[1]]
        TPC_dict = OrderedDict{Int,Tuple{Float64,Float64}}(TPC[1] => (-1.0, -1.0))
        OPEN = candidates[2:end]
    else
        TPC = collect(keys(prev_TPC_dict))
        TPC_dict = prev_TPC_dict
        OPEN = candidates
    end

    #start_time = time()
    n_candidates = length(OPEN)
    for (cand_index, candidate) in enumerate(OPEN)
        if debug > 0
            println("\tTesting candidate $candidate ($cand_index out of $n_candidates) conditioned on $TPC, current set size: $(length(TPC))")
        end

        if !isempty(whitelist) && candidate in whitelist
            push!(TPC, candidate)
            TPC_dict[candidate] = (NaN64, NaN64)
            
            if debug > 0
                println("\tin whitelist")
            end
            continue
        end

        if !isempty(blacklist) && candidate in blacklist
            continue
        end

        if needs_nz_view(candidate, data, test_obj)
            sub_data = @view data[data[:, candidate] .!= 0, :]
        else
            sub_data = data
        end

        (test_result, lowest_sig_Zs) = test_subsets(T, candidate, TPC, sub_data, test_obj, max_k, alpha, hps=hps,
                                   n_obs_min=n_obs_min, debug=debug, z=z)

        if issig(test_result, alpha)
            push!(TPC, candidate)
            TPC_dict[candidate] = (test_result.stat, test_result.pval)

            if debug > 0
                println("\taccepted: ", test_result)
            end
        else
            if track_rejections
                rej_dict[candidate] = (Tuple(lowest_sig_Zs), test_result)
            end
            if debug > 0
                println("\trejected: ", test_result, " through Z ", lowest_sig_Zs)
            end
        end

        if cand_index < n_candidates && stop_reached(start_time, time_limit)
            candidates_unchecked = OPEN[cand_index+1:end]
            return TPC_dict, candidates_unchecked
        end
    end

    TPC_dict, Int[]
end


function elimination_phase{ElType <: Real}(T::Int, TPC::AbstractVector{Int}, data::AbstractMatrix{ElType},
        test_obj::AbstractTest, max_k::Integer, alpha::AbstractFloat, hps::Integer=5, n_obs_min::Integer=0,
        fast_elim::Bool=true, no_red_tests::Bool=false, prev_PC_dict::OrderedDict{Int,Tuple{Float64,Float64}}=Dict(),
        PC_unchecked::AbstractVector{Int}=[], time_limit::AbstractFloat=0.0, start_time::AbstractFloat=0.0,
        debug::Integer=0, whitelist::Set{Int}=Set{Int}(), blacklist::Set{Int}=Set{Int}(),
        rej_dict::Dict{Int, Tuple{Tuple,TestResult}}=Dict{Int, Tuple{Tuple,TestResult}}(), track_rejections::Bool=false,
        z::Vector{ElType}=ElType[]) 

    nz = is_zero_adjusted(test_obj)
    is_discrete = isdiscrete(test_obj)
    is_dense = !issparse(data)

    if !isempty(prev_PC_dict)
        PC_dict = prev_PC_dict
        PC_candidates = PC_unchecked
    else
        PC_dict = OrderedDict{Int,Tuple{Float64,Float64}}()
        PC_candidates = TPC
    end

    n_candidates = length(PC_candidates)

    if n_candidates < 1
        if n_candidates == 1
            PC_dict[PC_candidates[1]] = (NaN64, NaN64)
        end
        return PC_dict, Int[]
    end

    PC = copy(TPC)
    for (cand_index, candidate) in enumerate(PC_candidates)
        PC_nocand = PC[PC .!= candidate]

        if debug > 0
            println("\tTesting candidate $candidate ($cand_index out of $n_candidates) conditioned on $PC_nocand, current set size: $(length(PC_nocand))")
        end

        if !isempty(whitelist) && candidate in whitelist
            PC_dict[candidate] = (NaN64, NaN64)
            continue
        end

        if !isempty(blacklist) && candidate in blacklist
            continue
        end

        if needs_nz_view(candidate, data, test_obj)
            sub_data = @view data[data[:, candidate] .!= 0, :]
        else
            sub_data = data
        end

        if no_red_tests
            if cand_index == length(PC_candidates)
                PC_dict[candidate] = (NaN64, NaN64)
                break
            else
                Z_wanted = @view PC_candidates[cand_index+1:end]
            end
        else
            Z_wanted = Int[]
        end
        
        (test_result, lowest_sig_Zs) = test_subsets(T, candidate, PC_nocand, sub_data, test_obj, max_k, alpha, hps=hps,
                                   n_obs_min=n_obs_min, debug=debug, Z_wanted=Z_wanted, z=z)

        if !issig(test_result, alpha)
            
            if fast_elim
                deleteat!(PC, findin(PC, candidate))
            end

            if track_rejections
                rej_dict[candidate] = (Tuple(lowest_sig_Zs), test_result)
            end

            if debug > 0
                println("\trejected: ", test_result, " through Z ", lowest_sig_Zs)
            end
        else
            PC_dict[candidate] = (test_result.stat, test_result.pval)

            if debug > 0
                println("\taccepted: ", test_result)
            end
        end

        if cand_index < n_candidates && stop_reached(start_time, time_limit)
            TPC_unchecked = PC_candidates[cand_index+1:end]
            return PC_dict, TPC_unchecked
        end
    end

    PC_dict, Int[]
end



function si_HITON_PC{ElType<:Real, DiscType<:Integer, ContType<:AbstractFloat}(T::Int, data::AbstractMatrix{ElType}; test_name::String="mi", max_k::Int=3, alpha::Float64=0.01, hps::Int=5, n_obs_min::Integer=0,
    fast_elim::Bool=true, no_red_tests::Bool=false, FDR::Bool=true, weight_type::String="cond_logpval", whitelist::Set{Int}=Set{Int}(),
        blacklist::Set{Int}=Set{Int}(),
        univar_nbrs::OrderedDict{Int,Tuple{Float64,Float64}}=OrderedDict{Int,Tuple{Float64,Float64}}(), levels::AbstractVector{DiscType}=DiscType[],
    univar_step::Bool=isempty(univar_nbrs), cor_mat::Matrix{ContType}=zeros(ContType, 0, 0),
    prev_state::HitonState{Int}=HitonState{Int}("S", OrderedDict(), OrderedDict(), [], Dict()), debug::Int=0, time_limit::Float64=0.0, track_rejections::Bool=false)

    if debug > 0
        println("Finding neighbors for $T")
    end

    rej_dict = Dict{Int, Tuple{Tuple,TestResult}}()
    
    if isdiscrete(test_name)
        if isempty(levels)
            levels = map(x -> get_levels(data[:, x]), 1:size(data, 2))
        end

        if levels[T] < 2
            phase = "F"
            state_results = OrderedDict{Int,Tuple{Float64,Float64}}()
            inter_results = OrderedDict{Int,Tuple{Float64,Float64}}()
            unchecked_vars = Int[]
            state_rejections = rej_dict

            return HitonState(phase, state_results, inter_results, unchecked_vars, state_rejections)
        end
        
        z = issparse(data) ? ElType[] : fill(-one(ElType), size(data, 1))
    else
        z = ElType[]
    end

    test_obj = make_test_object(test_name, true, max_k=max_k, levels=levels, cor_mat=cor_mat)

    if is_zero_adjusted(test_obj)
        if needs_nz_view(T, data, test_obj)
            data = @view data[data[:, T] .!= 0, :]
        end
    end
    
    
    test_variables = filter(x -> x != T, 1:size(data, 2))
    start_time = time_limit > 0.0 ? time() : 0.0

    # univariate filtering
    if debug > 0
        println("UNIVARIATE")
    end

    if univar_step
        if isdiscrete(test_name)
            univar_test_results = test(T, test_variables, data, test_obj, hps, n_obs_min)
        else
            univar_test_results = test(T, test_variables, data, test_obj, n_obs_min)
        end

        pvals = map(x -> x.pval, univar_test_results)

        # if local FDR was specified, apply it here
        if FDR
            pvals = benjamini_hochberg(pvals)
        end

        empty!(univar_nbrs)
        for (nbr, stat, pval) in zip(test_variables, map(x -> x.stat, univar_test_results), pvals)
            if pval < alpha
                univar_nbrs[nbr] = (stat, pval)
            end
        end        
    end

    if debug > 0
        println("\t", collect(zip(test_variables, univar_nbrs)))
    end
            
                    
    # if conditioning should be performed
    if max_k > 0
        # if the global network has converged
        if prev_state.phase == "C"
            if !isempty(prev_state.inter_results)
                PC_dict = prev_state.state_results
                TPC_dict = prev_state.inter_results
            else
                PC_dict = OrderedDict{Int,Tuple{Float64,Float64}}()
                TPC_dict = OrderedDict{Int,Tuple{Float64,Float64}}()
            end
        else
            # needed for sparse matrices (should stay sparse for univariate computations and then
            # be converted to a view for conditioning)
            if issparse(data) && is_zero_adjusted(test_name)
                if needs_nz_view(T, data, test_obj)
                    data = @view data[data[:, T] .!= 0, :]
                end
            end    

            if prev_state.phase == "I" || prev_state.phase == "S"

                if prev_state.phase == "I"
                    prev_TPC_dict = prev_state.state_results
                    candidates = prev_state.unchecked_vars

                    if track_rejections
                        rej_dict = prev_state.state_rejections
                    end
                else
                    # sort candidates
                    candidate_pval_pairs = [(candidate, univar_nbrs[candidate][2]) for candidate in keys(univar_nbrs)]
                    sort!(candidate_pval_pairs, by=x -> x[2])
                    candidates = map(x -> x[1], candidate_pval_pairs)
                    prev_TPC_dict = OrderedDict{Int,Tuple{Float64,Float64}}()
                end

                if debug > 0
                    println("\tnumber of candidates:", length(candidates), candidates[1:min(length(candidates), 20)])
                    println("\nINTERLEAVING\n")
                end

                if isempty(candidates)
                    phase = "F"
                    state_results = OrderedDict{Int,Tuple{Float64,Float64}}()
                    inter_results = OrderedDict{Int,Tuple{Float64,Float64}}()
                    unchecked_vars = Int[]
                    state_rejections = rej_dict

                    return HitonState(phase, state_results, inter_results, unchecked_vars, state_rejections)
                end

                # interleaving phase
                TPC_dict, candidates_unchecked = interleaving_phase(T, candidates, data, test_obj, max_k,
                                                                    alpha, hps, n_obs_min, prev_TPC_dict, time_limit,
                                                                    start_time, debug, whitelist, blacklist,
                                                                    rej_dict, track_rejections, z)

                # set test stats of the initial candidate to its univariate association results
                if prev_state.phase == "S"
                    TPC_dict[candidates[1]] = univar_nbrs[candidates[1]]
                end

                if !isempty(candidates_unchecked)

                    if debug > 0
                        println("Time limit exceeded, reporting incomplete results")
                    end

                    phase = "I"
                    state_results = TPC_dict
                    inter_results = OrderedDict{Int,Tuple{Float64,Float64}}()
                    unchecked_vars = candidates_unchecked
                    state_rejections = rej_dict

                    return HitonState(phase, state_results, inter_results, unchecked_vars, state_rejections)
                end

                #inter_results = TPC_dict

                if debug > 0
                    println("After interleaving:", length(TPC_dict), " ", collect(keys(TPC_dict)))

                    if debug > 1
                        println(TPC_dict)
                    end

                    println("\nELIMINATION\n")
                end
            end


            # elimination phase
            if prev_state.phase == "E"
                prev_PC_dict = prev_state.state_results

                if no_red_tests || fast_elim
                    TPC_dict = prev_state.inter_results
                end

                PC_unchecked = prev_state.unchecked_vars
                PC_candidates = convert(Vector{Int}, [keys(prev_PC_dict)..., PC_unchecked...])

                if track_rejections
                    rej_dict = prev_state.state_rejections
                end
            else
                prev_PC_dict = OrderedDict{Int,Tuple{Float64,Float64}}()
                PC_unchecked = Int[]
                PC_candidates = convert(Vector{Int}, collect(keys(TPC_dict)))
            end

            PC_dict, TPC_unchecked = elimination_phase(T, PC_candidates, data, test_obj, max_k, alpha,
                                                       hps, n_obs_min, fast_elim, no_red_tests,
                                                       prev_PC_dict, PC_unchecked, time_limit, start_time,
                                                       debug, whitelist, blacklist, rej_dict, track_rejections, z)

            if !isempty(TPC_unchecked)

                if debug > 0
                    println("Time limit exceeded, reporting incomplete results")
                end

                phase = "E"
                state_results = PC_dict
                inter_results = TPC_dict
                unchecked_vars = TPC_unchecked
                state_rejections = rej_dict

                return HitonState(phase, state_results, inter_results, unchecked_vars, state_rejections)
            end
        end
        
        # if redundant tests were skipped in elimination phase, check
        # if lower weights were previously found during interleaving phase
        if no_red_tests || fast_elim
            for nbr in keys(PC_dict)
                if haskey(TPC_dict, nbr) && (TPC_dict[nbr][2] > PC_dict[nbr][2] || isnan(PC_dict[nbr][2]))
                    PC_dict[nbr] = TPC_dict[nbr]
                end
            end
        end

        if debug > 1
            println(PC_dict)
        end
    else
        PC_dict = univar_nbrs
    end


    # if previous state had converged, keep this information
    if prev_state.phase == "C"
        phase = "C"
        unchecked_vars = prev_state.unchecked_vars
        state_rejections = prev_state.state_rejections
    else
        phase = "F"
        unchecked_vars = Int[]
        state_rejections = rej_dict
    end
    
    state_results = PC_dict
    inter_results = TPC_dict

    HitonState(phase, state_results, inter_results, unchecked_vars, state_rejections)
end


function LGL{ElType <: Real}(data::AbstractMatrix{ElType}; test_name::String="mi", max_k::Integer=3, alpha::AbstractFloat=0.01,
                        hps::Integer=5, n_obs_min::Integer=-1, 
    convergence_threshold::AbstractFloat=0.01, FDR::Bool=true, global_univar::Bool=true, parallel::String="single",
        fast_elim::Bool=true, no_red_tests::Bool=true, precluster_sim::AbstractFloat=0.0,
        weight_type::String="cond_logpval", edge_rule::String="OR", nonsparse_cond::Bool=false, 
        verbose::Bool=true, update_interval::AbstractFloat=30.0, edge_merge_fun=maxweight,
    debug::Integer=0, time_limit::AbstractFloat=-1.0, header::AbstractVector{String}=String[],
    recursive_pcor::Bool=true, correct_reliable_only::Bool=true, feed_forward::Bool=true,
    track_rejections::Bool=false, fully_connect_clusters::Bool=false, cluster_mode="greedy")
    """
    time_limit: -1.0 set heuristically, 0.0 no time_limit, otherwise time limit in seconds
    parallel: 'single', 'single_il', 'multi_ep', 'multi_il'
    fast_elim: currently always on
    """           
    
    if time_limit == -1.0
        if parallel == "multi_il"# && feed_forward
            time_limit = round(log2(size(data, 2)))
            println("Setting 'time_limit' to $time_limit s.")
        else
            time_limit = 0.0
        end
    end
    
    #if time_limit != 0.0 && !feed_forward
    #    warn("Time limit is only useful in combination with feed_forward, setting it to 0.")
    #    time_limit = 0.0
    #end
            
    workers_local = workers_all_local()

    if time_limit != 0.0 && parallel != "multi_il"
        warn("Using time_limit without interleaved parallelism is not advised.")
    elseif parallel == "multi_il" && time_limit == 0.0 && feed_forward
        warn("Specify 'time_limit' when using interleaved parallelism to increase speed.")
    end

    if time_limit != 0.0 && !fast_elim
        warn("Setting fast_elim to true because time_limit has been specified")
        fast_elim = true
    end
    
    if recursive_pcor && iscontinuous(test_name)
        warn("setting 'recursive_pcor' to true produces different results in case of perfectly correlated
              variables, caution advised")
    end    
                    
    data_prec = string(eltype(data))[end-1:end]
    disc_type = eval(Symbol("Int$(data_prec)"))
    cont_type = eval(Symbol("Float$(data_prec)"))
    
    if isdiscrete(test_name)
        if verbose
            println("Computing levels..")
        end
        levels = get_levels(data)
        cor_mat = zeros(cont_type, 0, 0)
    else
        levels = disc_type[]

        if recursive_pcor && !is_zero_adjusted(test_name)
            cor_mat = convert(Matrix{cont_type}, cor(data))
        else
            cor_mat = zeros(cont_type, 0, 0)
        end            
    end
    
        
    if n_obs_min < 0 && is_zero_adjusted(test_name)
        if test_name == "mi_nz"
            max_levels = maximum(levels) - 1
            n_obs_min = hps * max_levels^(max_k+2) + 1
        else
            n_obs_min = 20
        end
        
        if verbose
            println("Automatically setting 'n_obs_min' to $n_obs_min to enhance reliability.")
        end
    end
            

    kwargs = Dict(:test_name => test_name, :max_k => max_k, :alpha => alpha, :hps => hps, :n_obs_min => n_obs_min,
                  :fast_elim => fast_elim, :no_red_tests => no_red_tests, :FDR => FDR,
                  :weight_type => weight_type, :univar_step => !global_univar, :debug => debug,
                  :time_limit => time_limit, :track_rejections => track_rejections)


    rej_dict = Dict{Int, Dict{Int, Tuple{Tuple,TestResult}}}()
    unfinished_state_dict = Dict{Int, HitonState{Int}}()

    if global_univar
        # precompute univariate associations and sort variables (fewest neighbors first)
        if verbose
            println("Computing univariate associations..")
            tic()
        end

        all_univar_nbrs = pw_univar_neighbors(data; test_name=test_name, alpha=alpha, hps=hps, n_obs_min=n_obs_min, FDR=FDR,
                                              levels=levels, parallel=parallel, workers_local=workers_local,
                                              cor_mat=cor_mat, correct_reliable_only=correct_reliable_only)
        var_nbr_sizes = [(x, length(all_univar_nbrs[x])) for x in 1:size(data, 2)]
        target_vars = [nbr_size_pair[1] for nbr_size_pair in sort(var_nbr_sizes, by=x -> x[2])]

        if verbose
            println("\nUnivariate degree stats:")
            nbr_nums = map(length, values(all_univar_nbrs))
            println(summarystats(nbr_nums), "\n")
            if mean(nbr_nums) > size(data, 2) * 0.2
                warn("The univariate network is exceptionally dense, computations may be very slow.
                     Check if appropriate normalization was used (employ niche-mode if not yet the case)
                     and try using the AND rule to gain speed.")
            end
            toc()
        end
    else
        target_vars = 1:size(data, 2)
        all_univar_nbrs = Dict([(x, Dict{Int,Tuple{Float64,Float64}}()) for x in target_vars])
    end


    if precluster_sim != 0.0
        if verbose
            println("Clustering..")
            tic()
        end

        univar_matrix = pw_unistat_matrix(data, test_name; pw_stat_dict=all_univar_nbrs)
        clust_repres, clust_dict = cluster_data(data, test_name, cluster_sim_threshold=precluster_sim,
                                    sim_mat=univar_matrix, greedy=cluster_mode == "greedy")

        if verbose
            println("\tfound $(length(clust_repres)) clusters")
            toc()
        end

        #target_vars = clust_repres
        data = data[:, clust_repres]

        if !isempty(cor_mat)
            cor_mat = cor_mat[clust_repres, clust_repres]
        end

        target_vars = collect(1:length(clust_repres))
        var_clust_dict = Dict(zip(clust_repres, 1:length(clust_repres)))
        clust_var_dict = Dict(zip(1:length(clust_repres), clust_repres))
        all_univar_nbrs = map_edge_keys(all_univar_nbrs, var_clust_dict)

        if isdiscrete(test_name)
            levels = levels[clust_repres]
        end
    end


    if max_k == 0 && global_univar
        nbr_dict = all_univar_nbrs
    else
        if recursive_pcor && is_zero_adjusted(test_name)
            cor_mat = zeros(cont_type, size(data, 2), size(data, 2))
        end
                        
        if verbose
            println("Running si_HITON_PC for each variable..")
            tic()
        end

        if nonsparse_cond && !endswith(parallel, "il")
            data = full(data)
        end
                        
        if parallel == "single" || nprocs() == 1                            
            nbr_results = [si_HITON_PC(x, data; univar_nbrs=all_univar_nbrs[x], levels=levels, cor_mat=cor_mat,
                           kwargs...) for x in target_vars]
        else
            # embarassingly parallel
            if parallel == "multi_ep"
                nbr_results = @parallel (vcat) for x in target_vars
                    si_HITON_PC(x, data; univar_nbrs=all_univar_nbrs[x], levels=levels,
                                cor_mat=cor_mat, kwargs...)
                end

            # interleaved parallelism
            elseif endswith(parallel, "il")
                il_dict = interleaved_backend(target_vars, data, all_univar_nbrs, levels, update_interval, kwargs,
                                              convergence_threshold, cor_mat, parallel=parallel, edge_rule=edge_rule,
                                              nonsparse_cond=nonsparse_cond, verbose=verbose, workers_local=workers_local,
                                              feed_forward=feed_forward)
                nbr_results = [il_dict[target_var] for target_var in target_vars]
            else
                error("'$parallel' not a valid parallel mode")
            end

        end

        nbr_dict = Dict([(target_var, nbr_state.state_results) for (target_var, nbr_state) in zip(target_vars, nbr_results)])

        if precluster_sim != 0.0
            for target_var in target_vars
                if !haskey(nbr_dict, target_var)
                    nbr_dict[target_var] = Dict{Int,Float64}()
                end
            end
        end
        
        if time_limit != 0.0 || convergence_threshold != 0.0
            
            unfinished_state_dict = Dict{Int,HitonState{Int}}()
            for(target_var, nbr_state) in zip(target_vars, nbr_results)
                if !isempty(nbr_state.unchecked_vars)
                    unfinished_state_dict[target_var] = nbr_state
                end
            end
        end

        if track_rejections
            for (target_var, nbr_state) in zip(target_vars, nbr_results)
                rej_dict[target_var] = nbr_state.state_rejections
            end
        end
        
        if verbose 
            toc()
        end
    end

    if verbose
        println("Postprocessing..")
        tic()
    end

    if precluster_sim != 0.0
        nbr_dict = map_edge_keys(nbr_dict, clust_var_dict)
        all_univar_nbrs = map_edge_keys(all_univar_nbrs, clust_var_dict)

        if track_rejections
            rej_dict = map_edge_keys(rej_dict, clust_var_dict)
        end
    end

    weights_dict = Dict{Int,Dict{Int,Float64}}()
    for target_var in keys(nbr_dict)
        weights_dict[target_var] = make_weights(nbr_dict[target_var], all_univar_nbrs[target_var], weight_type, test_name)
    end

    graph = make_symmetric_graph(weights_dict, edge_rule)

    if precluster_sim != 0.0 && fully_connect_clusters
        for (clust_repres, clust_members) in clust_dict
            for member in clust_members
                if member != clust_repres
                    #graph_dict[member] = Dict{Int,Float64}()

                    for nbr in keys(graph_dict[clust_repres])
                        #graph_dict[member][nbr] = graph_dict[clust_repres][nbr]
                        if !has_edge(graph, member, nbr)
                            add_edge!(graph, member, nbr)
                            set_prop!(G, member, nbr, :weight, NaN64)
                            set_prop!(G, node1, node2, :dir, '=')
                        end
                    end

                    #graph_dict[member][clust_repres] = NaN64
                    #graph_dict[clust_repres][member] = NaN64
                    add_edge!(graph, member) 
                end
            end
        end
    end

    #return_dict = convert(Dict{Int,Dict{Int, Float64}}, graph_dict)
    result_obj = LGLResult{Int}(graph, rej_dict, unfinished_state_dict)

    if verbose
        println("Complete.")
        toc()
    end

    result_obj
end


# SPECIALIZED FUNCTIONS AND TYPES

function condensed_stats_to_dict(n_vars::Integer, pvals::AbstractVector{Float64}, stats::AbstractVector{Float64}, alpha::AbstractFloat)
    nbr_dict = Dict([(X, OrderedDict{Int,Tuple{Float64,Float64}}()) for X in 1:n_vars])

    for X in 1:n_vars-1, Y in X+1:n_vars
        pair_index = sum(n_vars-1:-1:n_vars-X) - n_vars + Y
        pval = pvals[pair_index]

        if pval < alpha
            stat = stats[pair_index]
            nbr_dict[X][Y] = (stat, pval)
            nbr_dict[Y][X] = (stat, pval)
        end
    end
    nbr_dict
end                


function pw_univar_kernel!{ElType <: Real}(X::Int, Ys_slice::UnitRange{Int}, data::AbstractMatrix{ElType},
                            stats::AbstractVector{Float64}, pvals::AbstractVector{Float64},
                            test_obj::AbstractTest, hps::Integer, n_obs_min::Integer, correct_reliable_only::Bool=false)
    n_vars = size(data, 2)

    if needs_nz_view(X, data, test_obj)
        sub_data = @view data[data[:, X] .!= 0, :]
    else
        sub_data = data
    end

    Ys = collect(Ys_slice)

    if isdiscrete(test_obj)
        test_results = test(X, Ys, sub_data, test_obj, hps, n_obs_min)
    else
        test_results = test(X, Ys, sub_data, test_obj, n_obs_min)
    end

    for (Y, test_res) in zip(Ys, test_results)
        pair_index = sum(n_vars-1:-1:n_vars-X) - n_vars + Y
                                                    
        if correct_reliable_only && !test_res.suff_power
            curr_stat = curr_pval = NaN64
        else
            curr_stat = test_res.stat
            curr_pval = test_res.pval
        end
            
        stats[pair_index] = curr_stat
        pvals[pair_index] = curr_pval
    end
end


function pw_univar_kernel{ElType <: Real}(X::Int, Ys_slice::UnitRange{Int}, data::AbstractMatrix{ElType},
                            test_obj::String, hps::Integer, n_obs_min::Integer)
    n_vars = size(data, 2)

    if needs_nz_view(X, data, test_obj)
        sub_data = @view data[data[:, X] .!= 0, :]
    else
        sub_data = data
    end

    Ys = collect(Ys_slice)

    if isdiscrete(test_obj)
        test_results = test(X, Ys, sub_data, test_obj, hps, n_obs_min)
    else
        test_results = test(X, Ys, sub_data, test_obj, n_obs_min)
    end
end


function pw_univar_neighbors{ElType<:Real, DiscType<:Integer, ContType<:AbstractFloat}(data::AbstractMatrix{ElType};
        test_name::String="mi", alpha::Float64=0.01, hps::Int=5, n_obs_min::Int=0, FDR::Bool=true,
        levels::AbstractVector{DiscType}=DiscType[], parallel::String="single", workers_local::Bool=true,
        cor_mat::Matrix{ContType}=zeros(ContType, 0, 0),
        chunk_size::Int=500, correct_reliable_only::Bool=true)

    if startswith(test_name, "mi") && isempty(levels)
        levels = map(x -> get_levels(data[:, x]), 1:size(data, 2))
    end
    
    test_obj = make_test_object(test_name, false, levels=levels, cor_mat=cor_mat)

    n_vars = size(data, 2)
    n_pairs = convert(Int, n_vars * (n_vars - 1) / 2)

    nz = is_zero_adjusted(test_obj)


    work_items = collect(work_chunker(n_vars, min(chunk_size, div(n_vars, 3))))

    if startswith(parallel, "single")
        pvals = ones(Float64, n_pairs)
        stats = zeros(Float64, n_pairs)

        for (X, Ys_slice) in work_items
            pw_univar_kernel!(X, Ys_slice, data, stats, pvals, test_obj, hps, n_obs_min, correct_reliable_only)
        end

    else
        shuffle!(work_items)
        if startswith(parallel, "multi")
            # if worker processes are on the same machine, use local memory sharing via shared arrays
            if workers_local
                shared_pvals = SharedArray{Float64}(n_pairs)
                shared_stats = SharedArray{Float64}(n_pairs)
                @sync @parallel for work_item in work_items
                    pw_univar_kernel!(work_item[1], work_item[2], data, shared_stats, shared_pvals, test_obj, hps,
                                      n_obs_min, correct_reliable_only)
                end
                stats = shared_stats.s
                pvals = shared_pvals.s

            # otherwise make workers store test results remotely and gather them in the end via network
            else
                all_test_results = @parallel (vcat) for work_item in work_items
                    pw_univar_kernel(work_item[1], work_item[2], data, test_name, hps, n_obs_min)
                end
                
                pvals = ones(Float64, n_pairs)
                stats = zeros(Float64, n_pairs)
                                     
                i = 0
                for (X, Ys_slice) in work_items
                    for Y in Ys_slice
                        i += 1
                        test_res = all_test_results[i]
                        pair_index = sum(n_vars-1:-1:n_vars-X) - n_vars + Y
                        
                        if correct_reliable_only && !test_res.suff_power
                            curr_stat = curr_pval = NaN64
                        else
                            curr_stat = test_res.stat
                            curr_pval = test_res.pval
                        end
            
                        stats[pair_index] = curr_stat
                        pvals[pair_index] = curr_pval
                    end
                end
            end

        elseif startswith(parallel, "threads")
            pvals = ones(Float64, n_pairs)
            stats = zeros(Float64, n_pairs)
            Threads.@threads for work_item in work_items
                pw_univar_kernel!(work_item[1], work_item[2], data, stats, pvals, test_obj, hps, n_obs_min,
                                  correct_reliable_only)
            end
        end
    end

    if FDR
        if correct_reliable_only && any(isnan(x) for x in pvals)
            reliable_mask = .!isnan.(pvals)
            reliable_pvals = pvals[reliable_mask]
            reliable_pvals = benjamini_hochberg(reliable_pvals)
            
            rel_pval_i = 1
            for (i, is_reliable_elem) in enumerate(reliable_mask)
                if is_reliable_elem
                    pvals[i] = reliable_pvals[rel_pval_i]
                    rel_pval_i += 1
                else
                    pvals[i] = NaN64
                end
            end
        else
            pvals = benjamini_hochberg(pvals)
        end
    end

    condensed_stats_to_dict(n_vars, pvals, stats, alpha)
end


function pw_unistat_matrix{T,ElType<:Real}(data::AbstractMatrix{ElType}, test_name::String; parallel::String="single",
        pw_stat_dict::Dict{Int,OrderedDict{Int,Tuple{Float64,Float64}}}=Dict{Int,OrderedDict{Int,Tuple{Float64,Float64}}}(),
    pw_uni_args::Dict{Symbol,T}=Dict{Symbol,Any}(), unsig_is_na::Bool=true)

    if isempty(pw_stat_dict)
        pw_stat_dict = pw_univar_neighbors(data; test_name=test_name, parallel=parallel, pw_uni_args...)
    end

    if unsig_is_na
        stat_mat = repmat([NaN64], size(data, 2), size(data, 2))
    else
        stat_mat = zeros(Float64, size(data, 2), size(data, 2))
    end
        
    for var_A in keys(pw_stat_dict)
        for var_B in keys(pw_stat_dict[var_A])
            (stat, pval) = pw_stat_dict[var_A][var_B]
            stat_mat[var_A, var_B] = stat
        end
    end
    stat_mat
end


function cluster_data{T,ElType<:Real}(data::AbstractMatrix{ElType}, stat_type::String="fz";
        cluster_sim_threshold::AbstractFloat=0.8, parallel="single",
    ordering="size", sim_mat::Matrix{Float64}=zeros(Float64, 0, 0), verbose::Bool=false, greedy::Bool=true,
    pw_uni_args::Dict{Symbol,T}=Dict{Symbol,Any}(), unsig_is_na::Bool=true)
    
    if verbose
        println("Computing pairwise similarities")
    end

    if !greedy && unsig_is_na
        warn("Hierarchical clustering currently doesn't support NA values, assuming them to be max distance.")
        unsig_is_na = false
    end
    
    if isempty(sim_mat)
        sim_mat = pw_unistat_matrix(data, stat_type, parallel=parallel, pw_uni_args=pw_uni_args, unsig_is_na=unsig_is_na)
    end

    if stat_type == "mi"
        if verbose
            println("Computing entropies")
        end

        # can potentially be improved by pre-allocation
        entrs = mapslices(x -> entropy(counts(x) ./ length(x)), data, 1)
    elseif stat_type == "mi_nz"
        nz_mask = data .!= 0
    elseif startswith(stat_type, "fz")
        sim_mat = abs.(sim_mat)
    end

    #greedy_mode = cluster_mode == "greedy"
    unclustered_vars = Set{Int}(1:size(data, 2))
    clust_dict = Dict{Int,Set{Int}}()

    if greedy
        var_order = collect(1:size(data, 2))
        if ordering == "size"
            var_sizes = sum(data, 1)
            sort!(var_order, by=x -> var_sizes[x], rev=true)
        end
    else
        var_order = 1:size(data, 2)
    end

    if verbose
        println("Clustering")
    end

    if !greedy
        if verbose
            println("\tConverting similarities to normalized distances")
        end
        dist_mat = similar(sim_mat)
    end

    n_obs_min::Int = haskey(pw_uni_args, :n_obs_min) ? pw_uni_args[:n_obs_min] : 1
    is_mi_stat = startswith(stat_type, "mi")
    is_fz_stat = startswith(stat_type, "fz")

    for var_A in var_order
        if var_A in unclustered_vars
            pop!(unclustered_vars, var_A)

            clust_members = Set(var_A)
            for var_B in unclustered_vars
                sim = sim_mat[var_A, var_B]

                if greedy && ((sim == 0.0) || isnan(sim))
                    continue
                end

                if is_mi_stat
                    if stat_type == "mi"
                        entr_A = entrs[var_A]
                        entr_B = entrs[var_B]
                    elseif stat_type == "mi_nz"
                        curr_nz_mask = (nz_mask[:, var_A] .& nz_mask[:, var_B])[:]
                        nz_elems = sum(curr_nz_mask)

                        if nz_elems < n_obs_min
                            entr_A = entr_B = norm_term = 0
                        else
                            entr_A = entropy(counts(data[curr_nz_mask, var_A]) ./ nz_elems)
                            entr_B = entropy(counts(data[curr_nz_mask, var_B]) ./ nz_elems)
                            norm_term = sqrt(entr_A * entr_B)
                        end
                    end
                    norm_term = sqrt(entr_A * entr_B)

                    sim = norm_term != 0.0 ? abs(sim) / norm_term : 0.0

                end

                if greedy
                    if sim > cluster_sim_threshold
                        push!(clust_members, var_B)
                        pop!(unclustered_vars, var_B)
                    end
                else
                    dist = 1.0 - sim
                    dist_mat[var_A, var_B] = dist
                    dist_mat[var_B, var_A] = dist
                end
            end

            if greedy
                clust_dict[var_A] = clust_members
            end
        end
    end

    if !greedy
        if verbose
            println("\tComputing hierarchical clusters")
        end

        clust_obj = hclust(dist_mat, :average)
        clusts = cutree(clust_obj, h=1.0 - cluster_sim_threshold)

        var_sizes = sum(data, 1)

        for clust_id in unique(clusts)
            clust_members = findn(clusts .== clust_id)
            if length(clust_members) > 1
                clust_sizes = @view var_sizes[clust_members]
                clust_repres = clust_members[findmax(clust_sizes)[2]]
            else
                clust_repres = clust_members[1]
            end
            clust_dict[clust_repres] = Set(clust_members)
        end
    end

    (sort(collect(keys(clust_dict))), clust_dict)
end


function interleaved_worker{ElType<:Real, DiscType<:Integer, ContType<:AbstractFloat}(data::AbstractMatrix{ElType},
        levels::AbstractVector{DiscType}, cor_mat::Matrix{ContType}, edge_rule::String, nonsparse_cond::Bool,
        shared_job_q::RemoteChannel, shared_result_q::RemoteChannel, GLL_fun, GLL_args::Dict{Symbol,Any})
    
    if nonsparse_cond
        data = full(data)
    end
     
    const converged = false
                                                
    while true
        try
            target_var, univar_nbrs, prev_state, skip_nbrs = take!(shared_job_q)
            # if kill signal
            if target_var == -1
                put!(shared_result_q, (0, myid()))
                return
            end

            if prev_state.phase == "C"
                converged = true
            elseif converged
                prev_state = HitonState("C", prev_state.state_results, prev_state.inter_results, prev_state.unchecked_vars,
                                        prev_state.state_rejections)
            end
                                                        
            if edge_rule == "AND"
                nbr_state = si_HITON_PC(target_var, data; univar_nbrs=univar_nbrs, levels=levels,
                                        prev_state=prev_state, blacklist=skip_nbrs, cor_mat=cor_mat, GLL_args...)
            else
                nbr_state = si_HITON_PC(target_var, data; univar_nbrs=univar_nbrs, levels=levels,
                                        prev_state=prev_state, whitelist=skip_nbrs, cor_mat=cor_mat, GLL_args...)
            end
            put!(shared_result_q, (target_var, nbr_state))
        catch exc
            println("Exception occurred! ", exc)
            println(catch_stacktrace())
            #put!(shared_result_q, (target_var, exc))
            #throw(exc)
        end

    end
end


function interleaved_backend{ElType<:Real, DiscType<:Integer, ContType<:AbstractFloat}(target_vars::AbstractVector{Int}, data::AbstractMatrix{ElType},
        all_univar_nbrs::Dict{Int,OrderedDict{Int,Tuple{Float64,Float64}}}, levels::AbstractVector{DiscType},
        update_interval::Real, GLL_args::Dict{Symbol,Any}, convergence_threshold::AbstractFloat, cor_mat::Matrix{ContType};
        conv_check_start::AbstractFloat=0.1, conv_time_step::AbstractFloat=0.1, parallel::String="multi",
        edge_rule::String="OR", nonsparse_cond::Bool=false, verbose::Bool=true, workers_local::Bool=true,
        feed_forward::Bool=true)
    
    jobs_total = length(target_vars)

    if startswith(parallel, "multi") || startswith(parallel, "threads")
        n_workers = nprocs() - 1
        job_q_buff_size = n_workers * 2
        @assert n_workers > 0 "Need to add workers for parallel processing."
    elseif startswith(parallel, "single")
        n_workers = 1
        job_q_buff_size = 1
    else
        error("$parallel not a valid execution mode.")
    end

    shared_job_q = RemoteChannel(() -> StackChannel{Tuple}(size(data, 2) * 2), 1)
    shared_result_q = RemoteChannel(() -> Channel{Tuple}(size(data, 2)), 1)


    # initialize jobs
    queued_jobs = 0
    waiting_vars = Stack(Int)
    for (i, target_var) in enumerate(reverse(target_vars))
        job = (target_var, all_univar_nbrs[target_var], HitonState{Int}("S", OrderedDict(), OrderedDict(),
                                                                        [], Dict()), Set{Int}())

        if i < jobs_total - n_workers
            push!(waiting_vars, target_var)
        else
            put!(shared_job_q, job)
            queued_jobs += 1
        end
    end


    if verbose
        println("Starting workers and sending data..")
        tic()
    end
    worker_returns = [@spawn interleaved_worker(data, levels, cor_mat, edge_rule, nonsparse_cond,
                                                shared_job_q, shared_result_q, si_HITON_PC, GLL_args) for x in 1:n_workers]
    
    if verbose
        println("Done. Starting inference..")
        toc() 
    end
                                                
    remaining_jobs = jobs_total

    graph_dict = Dict{Int, HitonState{Int}}()

    # this graph is just used for efficiently keeping track of graph stats during the run
    graph = Graph(length(target_vars))

    if edge_rule == "AND"
        blacklist_graph = Graph(length(target_vars))
    end

    edge_set = Set{Tuple{Int,Int}}()
    kill_signals_sent = 0
    start_time = time()
    last_update_time = start_time
    check_convergence = false
    converged = false

    while remaining_jobs > 0
        target_var, nbr_result = take!(shared_result_q)
        queued_jobs -= 1
        if isa(nbr_result, HitonState{Int})
            curr_state = nbr_result

            # node has not yet finished computing
            if curr_state.phase != "F" && curr_state.phase != "C"
                if converged
                    curr_state = HitonState("C", curr_state.state_results, curr_state.inter_results, curr_state.unchecked_vars, curr_state.state_rejections)
                end
                
                if feed_forward
                    skip_nbrs = edge_rule == "AND" ? Set(neighbors(blacklist_graph, target_var)) : Set(neighbors(graph, target_var))
                else
                    skip_nbrs= Set{Int}()
                end
                
                job = (target_var, all_univar_nbrs[target_var], curr_state, skip_nbrs)
                put!(shared_job_q, job)
                queued_jobs += 1

            # node is complete
            else
                graph_dict[target_var] = curr_state

                for nbr in keys(curr_state.state_results)
                    add_edge!(graph, target_var, nbr)
                end

                if feed_forward && edge_rule == "AND"
                    for a_var in target_vars
                        if !haskey(curr_state.state_results, a_var)
                            add_edge!(blacklist_graph, target_var, a_var)
                        end
                    end
                end

                remaining_jobs -= 1

                # kill workers if not needed anymore
                if remaining_jobs < n_workers
                    kill_signal = (-1, Dict{Int,Tuple{Float64,Float64}}(), HitonState{Int}("S", OrderedDict(), OrderedDict(), [], Dict()), Set{Int}())
                    put!(shared_job_q, kill_signal)
                    kill_signals_sent += 1
                end
            end
        elseif isa(nbr_result, Int)
            if !workers_local
                rmprocs(nbr_result)
            end
        else
            println(nbr_result)
            throw(nbr_result)
        end

        if !isempty(waiting_vars) && queued_jobs < job_q_buff_size
            for i in 1:job_q_buff_size - queued_jobs
                next_var = pop!(waiting_vars)
                
                if feed_forward
                    var_nbrs = edge_rule == "AND" ? Set(neighbors(blacklist_graph, next_var)) : Set(neighbors(graph, next_var))
                else
                    var_nbrs = Set{Int}()
                end
                
                job = (next_var, all_univar_nbrs[next_var], HitonState{Int}("S", OrderedDict(), OrderedDict(), [], Dict()), var_nbrs)
                put!(shared_job_q, job)
                queued_jobs += 1

                if isempty(waiting_vars)
                    break
                end
            end
        end


        # print network stats after each update interval
        curr_time = time()
        if curr_time - last_update_time > update_interval
            if verbose
                println("\nTime passed: ", Int(round(curr_time - start_time)), ". Finished nodes: ", length(target_vars) - remaining_jobs, ". Remaining nodes: ", remaining_jobs)
            end

            if check_convergence && verbose
                println("Convergence times: $last_conv_time $(curr_time - last_conv_time - start_time) $((curr_time - last_conv_time - start_time) / last_conv_time) $(ne(graph) - last_conv_num_edges)")
            end
            print_network_stats(graph)
            last_update_time = curr_time
        end


        if convergence_threshold != 0.0 && !converged
            if !check_convergence && remaining_jobs / jobs_total <= conv_check_start
                check_convergence = true
                last_conv_time = curr_time - start_time
                last_conv_num_edges = ne(graph)

                if verbose
                    println("Starting convergence checks at $last_conv_num_edges edges.")
                end
            elseif check_convergence
                delta_time = (curr_time - start_time - last_conv_time) / last_conv_time

                if delta_time > conv_time_step
                    new_num_edges = ne(graph)
                    delta_num_edges = (new_num_edges - last_conv_num_edges) / last_conv_num_edges
                    conv_level = delta_num_edges / delta_time

                    if verbose
                        println("Current convergence level: $conv_level")
                    end

                    if conv_level < convergence_threshold
                        converged = true

                        if verbose
                            println("\tCONVERGED! Waiting for remaining processes to finish their current load.")
                        end
                    end

                    last_conv_time = curr_time - start_time
                    last_conv_num_edges = new_num_edges
                end
            end
        end


    end
                                                
    if !workers_local
        rmprocs(workers())
    end
                                                
    graph_dict
end


function learn_network{ElType <: Real}(data::AbstractArray{ElType}, mode::String="cont"; niche_adjust::Bool=false,
                                       make_sparse::Bool=false, maxk::Integer=3, alpha::AbstractFloat=0.01,
                                       normalize::Bool=true, parallel::Union{Bool,Void}=nothing,
                                       preclust_sim::AbstractFloat=0.0, feed_forward::Bool=true,
                                       join_rule::String="OR", verbose::Bool=true, kwargs...)

    start_time = time()
    if mode == "cont"
        test_name = "fz"
    elseif mode == "disc" || mode == "bin"
        test_name = "mi"
    else
        error("$mode is not a valid testing mode")
    end

    if niche_adjust
        test_name = join([test_name, "_nz"])
    end

    if feed_forward
        if !parallel
            parallel_mode = "single_il"
        else
            parallel_mode = "multi_il"
        end
    else
        parallel_mode = parallel ? "multi_ep" : "single"
    end

    if verbose
        println("Normalizing")
    end

    data_norm = normalize ? preprocess_data_default(data, test_name, make_sparse=make_sparse) : data

    if verbose
        println("Inferring network\n")
        println("\tSettings:")
        println("\t\tmode - $mode")
        println("\t\tniche_adjust - $niche_adjust")
        println("\t\tmax_k - $max_k")
        println("\t\tsparse - $make_sparse")
        println("\t\tfeed_forward - $feed_forward")
        println("\t\tpreclustering - $(preclust_sim != 0.0)")
        println("\t\tworkers - $(nprocs())")
    end

    params_dict = Dict(:test_name=>test_name, :max_k=>max_k, :alpha=>alpha, :preclust_sim=>preclust_sim,
                     :parallel=>parallel_mode, :edge_rule=>join_rule)
    merge!(params_dict, kwargs)
    lgl_results = LGL(data_norm, test_name=test_name, max_k=max_k, alpha=alpha, preclust_sim=preclust_sim, parallel=parallel_mode, edge_rule=join_rule, verbose=verbose; kwargs...)
                                                
    time_taken = time() - start_time()
    stats_dict = Dict(:time_taken=>time_taken, :converged=>!isempty(lgl_results.unfinished_states))
    meta_dict = Dict("params"=>params_dict, "stats"=>stats_dict)
    lgl_results, meta_dict
end

end
