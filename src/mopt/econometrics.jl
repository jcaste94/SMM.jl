




function get_simple_std(f::String)
	x = readAlgoBGP(f)
	nms = setdiff(names(x["params"]),[:chain_id,:iter])
	m = colwise(mean,@where(x["params"],:chain_id.==1)[nms])
	s = colwise(std,@where(x["params"],:chain_id.==1)[nms])
	m = Float64[m[im][1] for im in 1:length(m)]
	s = Float64[s[im][1] for im in 1:length(s)]
	out = DataFrame(param=string.(nms),estimate=m,sd=s)
end


"""
	FD_gradient(m::MProb,p::Dict;step_perc=0.005,diff_method=:forward)

Get the gradient of the moment function wrt to some parameter vector via finite difference approximation. 
The output is a (k,n) matrix, where ``k`` is the number of `m.params_to_sample` and where ``m`` is the number of moments.

* `step_perc`: step size in percent of parameter
* `diff_method`: `:forward` or `:central` differencing
* `use_range`: compute the step as a percentage of the parameter range (`true`), or not

The default step size is 1% of the parameter range.
"""
function FD_gradient(m::MProb,p::Union{Dict,OrderedDict};step_perc=0.01,diff_method=:forward,use_range=true)

	# get g(p)
    ev = evaluateObjective(m,p)
    mnames = collect(keys(m.moments))
    smm = filter(x->!in(x,mnames),ev.simMoments)
	gp = collect(values(smm))
	D = zeros(length(p),length(gp))

	# optimal step size depends on range of param bounds
	rs = range_length(m)

	# compute each partial derivative
	rows = pmap( [(k,v) for (k,v) in p ] ) do ip 
		k = ip[1]
		v = ip[2]
		h = 0.0
		pp = deepcopy(p)
		
		if use_range
			h = rs[k] * step_perc
		else
			h = v * step_perc
		end
		
		if diff_method == :forward
			pp[k] = v + h
			xx = evaluateObjective(m,pp)
			smm = collect(values(filter(x->!in(x,mnames),xx.simMoments)))
			Dict(:p => k, :smm => (smm .- gp) / h)
		elseif diff_method == :central
			pp[k] = v + 0.5*h
			xx = evaluateObjective(m,pp)
			fw = collect(values(filter(x->!in(x,mnames),xx.simMoments)))
			println(fw)

			pp[k] = v - 0.5*h
			xx = evaluateObjective(m,pp)
			bw = collect(values(filter(x->!in(x,mnames),xx.simMoments)))
			println(bw)

			Dict(:p => k, :smm => (fw .- bw) / h)
		else 
			error("only :central and :foward implemented")
		end
	end
	
	d = Dict()
	for e in rows
       d[e[:p]] = e[:smm]
    end
	
	row = 0
	for (k,v) in d
		row += 1
		D[row,:] = v
	end

	return D

end

"""
	get_stdErrors(m::MProb,p::Union{Dict,OrderedDict};reps=300)

Computes standard errors according to standard sandwich formula:

```math
S = (J W J')^{-1} (J W \\Sigma W J') (J W J')^{-1}
```
where 

1. ``\\Sigma`` is the *data* var-cov matrix generated by drawing H samples of simulated data using p. each draw has a different shock sequence here. this is done in function [`getSigma`](@ref).
1. ``J`` is the gradient of the objective function obtained with [`FD_gradient`](@ref)
1. ``W`` is the weighting matrix.
"""
function get_stdErrors(m::MProb,p::Union{Dict,OrderedDict};reps=300)

	# compute "Data" var-cov matrix Σ by generating H samples of simulated data using p 
	Σ = getSigma(m,p,reps)

	# compute score of moment function
	J = FD_gradient(m,p)
	println("size of gradient J = $(size(J))")

	# put all together to get standard errors
	# first get weighting matrix 
	W = Diagonal([v[:weight] for (k,v) in m.moments])
	println("size of Weight W = $(size(W))")
	
	SE = pinv(J *  W * J') * (J * W * Σ * W * J') * pinv(J * W * J') 
	
	return OrderedDict(zip(collect(keys(p)),sqrt.(diag(SE))))

end


"""
	getSigma(m::MProb,p::Union{Dict,OrderedDict},reps::Int)

Computes var-cov matrix of simulated data. This requires to *unseed* the random shock sequences in the objective function (to generate randomly different moments in each run). Argument `reps` controls how many samples of different moment functions should be taken.
"""
function getSigma(m::MProb,p::Union{Dict,OrderedDict},reps::Int)
    
	ev = [Eval(m,p) for i in 1:reps]
    mnames = collect(keys(m.moments))
    
	for e in ev
        e.options[:noseed] = true
    end
    
	if length(workers()) > 1
        evs = pmap(x->evaluateObjective(m,x),ev)
    else
        evs = map(x->evaluateObjective(m,x),ev)
    end
   
	d = DataFrame()
    for (k,v) in filter(x->!in(x,mnames),evs[1].simMoments)
        d[k] = eltype(v)[evs[i].simMoments[k] for i in 1:reps]
    end
    
    Σ = cov(convert(Matrix,d))
    return Σ
end



