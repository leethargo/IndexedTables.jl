# getindex

using IntervalSets

export ClosedInterval, ..

getindex(t::IndexedTable, idxs...) = (flush!(t); _getindex(t, idxs))

_getindex{T,D<:Tuple}(t::IndexedTable{T,D}, idxs::D) = _getindex_scalar(t, idxs)
_getindex(t::IndexedTable, idxs::Tuple{Vararg{Real}}) = _getindex_scalar(t, idxs)

function _getindex_scalar(t, idxs)
    i = searchsorted(t.index, idxs)
    length(i) != 1 && throw(KeyError(idxs))
    t.data[first(i)]
end

# branch instead of diagonal dispatch to avoid ambiguities
_in(x, y) = isa(x,typeof(y)) ? isequal(x, y) : in(x, y)
_in(x, ::Colon) = true
_in(x, v::AbstractVector) = (idx=searchsortedfirst(v, x); idx<=length(v) && v[idx]==x)
_in(x, v::ClosedInterval) = x >= v.left && x <= v.right
_in(x, v::Range) = x in v
_in(x, v::AbstractString) = x == v
_in(x, v::Symbol) = x === v
_in(x, v::Number) = isequal(x, v)

import Base: tail
# test whether row r is within product(idxs...)
@inline row_in(cs, r::Integer, idxs) = _row_in(cs[1], r, idxs[1], tail(cs), tail(idxs))
@inline _row_in(c1, r, i1, rI, ri) = _in(c1[r],i1) & _row_in(rI[1], r, ri[1], tail(rI), tail(ri))
@inline _row_in(c1, r, i1, rI::Tuple{}, ri) = _in(c1[r],i1)

range_estimate(col, idx) = 1:length(col)
range_estimate{T}(col::AbstractVector{T}, idx::T) = searchsortedfirst(col, idx):searchsortedlast(col,idx)
range_estimate(col, idx::AbstractArray) = searchsortedfirst(col,first(idx)):searchsortedlast(col,last(idx))
range_estimate(col, idx::ClosedInterval) = searchsortedfirst(col, idx.left):searchsortedlast(col, idx.right)

const _fwd = Base.Order.ForwardOrdering()

range_estimate(col, idx, lo, hi) = 1:length(col)
range_estimate{T}(col::AbstractVector{T}, idx::T, lo, hi) =
    searchsortedfirst(col, idx, lo, hi, _fwd):searchsortedlast(col, idx, lo, hi, _fwd)
range_estimate(col, idx::AbstractArray, lo, hi) =
    searchsortedfirst(col, first(idx), lo, hi, _fwd):searchsortedlast(col, last(idx), lo, hi, _fwd)

isconstrange(col, idx) = false
isconstrange{T}(col::AbstractVector{T}, idx::T) = true
isconstrange(col, idx::AbstractArray) = isequal(first(idx), last(idx))

function range_estimate(I::Columns, idxs)
    r = range_estimate(I.columns[1], idxs[1])
    i = 1; n = length(idxs)
    while i < n && isconstrange(I.columns[i], idxs[i])
        i += 1
        r = intersect(r, range_estimate(I.columns[i], idxs[i], first(r), last(r)))
    end
    return r
end

function _getindex(t::IndexedTable, idxs)
    I = t.index
    cs = astuple(I.columns)
    if length(idxs) != length(I.columns)
        error("wrong number of indices")
    end
    for idx in idxs
        isa(idx, AbstractVector) && (issorted(idx) || error("indices must be sorted for ranged/vector indexing"))
    end

    estimate = range_estimate(I, idxs)
    # Columns that need a second look to narrow down indices in estimated range
    second_lookup = []
    if !isa(idxs[1], Union{Colon, ClosedInterval})
        push!(second_lookup, 1)
    end
    for i in 2:length(idxs)
        !isa(idxs[i], Colon) && push!(second_lookup, i)
    end

    if !isempty(second_lookup)
        out = convert(Vector{Int32}, estimate)
        filter_idxs_in!(cs[second_lookup], idxs[second_lookup], out)
        IndexedTable(Columns(map(x->x[out], I.columns)), t.data[out], presorted=true)
    else
        IndexedTable(Columns(map(x->x[estimate], I.columns)), t.data[estimate], presorted=true)
    end
end

function filter_idxs_in!(cols, idxs, out)
    filter!(i->row_in(cols, i, idxs), out)
end

# iterators over indices - lazy getindex

"""
`where(arr::IndexedTable, indices...)`

Returns an iterator over data items where the given indices match. Accepts the
same index arguments as `getindex`.
"""
function where{N}(d::IndexedTable, idxs::Vararg{Any,N})
    I = d.index
    cs = astuple(I.columns)
    data = d.data
    rng = range_estimate(I, idxs)
    (data[i] for i in Compat.Iterators.Filter(r->row_in(cs, r, idxs), rng))
end

"""
`update!(f::Function, arr::IndexedTable, indices...)`

Replace data values `x` with `f(x)` at each location that matches the given
indices.
"""
function update!{N}(f::Union{Function,Type}, d::IndexedTable, idxs::Vararg{Any,N})
    I = d.index
    cs = astuple(I.columns)
    data = d.data
    rng = range_estimate(I, idxs)
    for r in rng
        if row_in(cs, r, idxs)
            data[r] = f(data[r])
        end
    end
    d
end

pairs(d::IndexedTable) = (d.index[i]=>d.data[i] for i in 1:length(d))

"""
`pairs(arr::IndexedTable, indices...)`

Similar to `where`, but returns an iterator giving `index=>value` pairs.
`index` will be a tuple.
"""
function pairs{N}(d::IndexedTable, idxs::Vararg{Any,N})
    I = d.index
    cs = astuple(I.columns)
    data = d.data
    rng = range_estimate(I, idxs)
    (I[i]=>data[i] for i in Compat.Iterators.Filter(r->row_in(cs, r, idxs), rng))
end

# setindex!

setindex!(t::IndexedTable, rhs, idxs...) = _setindex!(t, rhs, idxs)

# assigning to an explicit set of indices --- equivalent to merge!

setindex!(t::IndexedTable, rhs, I::Columns) = setindex!(t, fill(rhs, length(I)), I) # TODO avoid `fill`

setindex!(t::IndexedTable, rhs::AbstractVector, I::Columns) = merge!(t, IndexedTable(I, rhs, copy=false))

# assigning a single item

_setindex!{T,D}(t::IndexedTable{T,D}, rhs::AbstractArray, idxs::D) = _setindex_scalar!(t, rhs, idxs)
_setindex!(t::IndexedTable, rhs::AbstractArray, idxs::Tuple{Vararg{Real}}) = _setindex_scalar!(t, rhs, idxs)
_setindex!{T,D}(t::IndexedTable{T,D}, rhs, idxs::D) = _setindex_scalar!(t, rhs, idxs)
#_setindex!(t::IndexedTable, rhs, idxs::Tuple{Vararg{Real}}) = _setindex_scalar!(t, rhs, idxs)

function _setindex_scalar!(t, rhs, idxs)
    push!(t.index_buffer, idxs)
    push!(t.data_buffer, rhs)
    t
end

# vector assignment: works like a left join

_setindex!(t::IndexedTable, rhs::IndexedTable, idxs::Tuple{Vararg{Real}}) = _setindex!(t, rhs.data, idxs)
_setindex!(t::IndexedTable, rhs::IndexedTable, idxs) = _setindex!(t, rhs.data, idxs)

function _setindex!{T,D}(d::IndexedTable{T,D}, rhs::AbstractArray, idxs)
    for idx in idxs
        isa(idx, AbstractVector) && (issorted(idx) || error("indices must be sorted for ranged/vector indexing"))
    end
    flush!(d)
    I = d.index
    data = d.data
    ll = length(I)
    p = product(idxs...)
    s = start(p)
    done(p, s) && return d
    R, s = next(p, s)
    i = j = 1
    L = I[i]
    while i <= ll
        c = cmp(L, R)
        if c < 0
            i += 1
            L = I[i]
        elseif c == 0
            data[i] = rhs[j]
            i += 1
            L = I[i]
            j += 1
            done(p, s) && break
            R, s = next(p, s)
        else
            j += 1
            done(p, s) && break
            R, s = next(p, s)
        end
    end
    return d
end

# broadcast assignment of a single value into all matching locations

function _setindex!{T,D}(d::IndexedTable{T,D}, rhs, idxs)
    for idx in idxs
        isa(idx, AbstractVector) && (issorted(idx) || error("indices must be sorted for ranged/vector indexing"))
    end
    flush!(d)
    I = d.index
    cs = astuple(I.columns)
    data = d.data
    rng = range_estimate(I, idxs)
    for r in rng
        if row_in(cs, r, idxs)
            data[r] = rhs
        end
    end
    d
end

"""
`flush!(arr::IndexedTable)`

Commit queued assignment operations, by sorting and merging the internal temporary buffer.
"""
function flush!(t::IndexedTable)
    if !isempty(t.data_buffer)
        # 1. form sorted array of temp values, preferring values added later (`right`)
        temp = IndexedTable(t.index_buffer, t.data_buffer, copy=false, agg=right)

        # 2. merge in
        _merge!(t, temp, right)

        # 3. clear buffer
        empty!(t.index_buffer)
        empty!(t.data_buffer)
    end
    nothing
end
