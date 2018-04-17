
pointformats = Dict(
    0x00 => LasPoint0,
    0x01 => LasPoint1,
    0x02 => LasPoint2,
    0x03 => LasPoint3,
    0x04 => LasPoint4,
    0x05 => LasPoint5,
    0x06 => LasPoint6,
    0x07 => LasPoint7,
    0x08 => LasPoint8,
    0x09 => LasPoint9,
    0x10 => LasPoint10
)

function pointformat(header::LasHeader)
    id = header.data_format_id
    if id in keys(pointformats)
        return pointformats[id]
    else
        error("unsupported point format $(Int(id))")
    end
end

# skip the LAS file's magic four bytes, "LASF"
skiplasf(s::Union{Stream{format"LAS"}, Stream{format"LAZ"}, IO}) = read(s, UInt32)

function load(f::File{format"LAS"}; mmap=false)
    open(f) do s
        load(s; mmap=mmap)
    end
end

# Load pipe separately since it can't be memory mapped
function load(s::Pipe)
    skiplasf(s)
    header = read(s, LasHeader)
    lv = VersionNumber(header.version_major, header.version_minor)

    n = lv >= v"1.4" ? header.records_count_new : header.records_count
    println("# points $n")
    pointtype = pointformat(header)
    pointdata = Vector{pointtype}(n)
    for i=1:n
        pointdata[i] = read(s, pointtype)
    end
    header, pointdata
end

function load(s::Stream{format"LAS"}; mmap=false)
    skiplasf(s)
    header = read(s, LasHeader)
    println(header)
    lv = VersionNumber(header.version_major, header.version_minor)

    n = header.records_count_new
    println("# points $n")
    pointtype = pointformat(header)
    println("type $pointtype")

    if mmap
        pointsize = Int(header.data_record_length)
        pointbytes = Mmap.mmap(s.io, Vector{UInt8}, n*pointsize, position(s))
        pointdata = PointVector{pointtype}(pointbytes, pointsize)
    else
        pointdata = Vector{pointtype}(n)
        for i=1:n
            pointdata[i] = read(s, pointtype)
        end
    end

    # Extended Variable Length Records
    evlrs = Vector{ExtendedLasVariableLengthRecord}()
    println("Current pos: $(position(s))")
    println("Start of wav pos: $(header.waveform_offset)")
    if lv == v"1.3" && header.waveform_offset > 0
        println(header.waveform_offset)
        evlr = read(s, ExtendedLasVariableLengthRecord)
        push!(evlrs, evlr)

        # Read waveform packets
        # pwaves = Vector{Array{Float32}}(length(pointdata))


        # @show pwaves

    elseif lv == v"1.4" && header.n_evlr > 0
        println(header.evlr_offset)
        for i=1:header.n_evlr
            push!(evlrs, read(s, ExtendedLasVariableLengthRecord))
        end
    else
        nothing
    end

    @show eof(s)

    #


    header, pointdata, evlrs
end

function load(f::File{format"LAZ"})
    # read las from laszip, which decompresses to stdout
    open(`laszip -olas -stdout -i $(filename(f))`) do s
        load(s)
    end
end

function read_header(f::AbstractString)
    open(f) do s
        skiplasf(s)
        read(s, LasHeader)
    end
end

function read_header(s::IO)
    skiplasf(s)
    read(s, LasHeader)
end

function save(f::File{format"LAS"}, header::LasHeader, pointdata::AbstractVector{<:LasPoint})
    open(f, "w") do s
        save(s, header, pointdata)
    end
end

function save(s::Stream{format"LAS"}, header::LasHeader, pointdata::AbstractVector{<:LasPoint})
    # checks
    header_n = header.records_count
    n = length(pointdata)
    msg = "number of records in header ($header_n) does not match data length ($n)"
    @assert header_n == n msg

    # write header
    write(s, magic(format"LAS"))
    write(s, header)

    # write points
    for p in pointdata
        write(s, p)
    end
end

function save(f::File{format"LAZ"}, header::LasHeader, pointdata::AbstractVector{<:LasPoint})
    # pipes las to laszip to write laz
    open(`laszip -olaz -stdin -o $(filename(f))`, "w") do s
        savebuf(s, header, pointdata)
    end
end

# Uses a buffered write to the stream.
# For saving to LAS this does not increase speed,
# but it speeds up a lot when the result is piped to laszip.
function savebuf(s::IO, header::LasHeader, pointdata::AbstractVector{<:LasPoint})
    # checks
    header_n = header.records_count
    n = length(pointdata)
    msg = "number of records in header ($header_n) does not match data length ($n)"
    @assert header_n == n msg

    # write header
    write(s, magic(format"LAS"))
    write(s, header)

    # 2048 points seemed to be an optimum for the libLAS_1.2.las testfile
    npoints_buffered = 2048
    bufsize = header.data_record_length * npoints_buffered
    buf = IOBuffer(bufsize)
    # write points
    for (i, p) in enumerate(pointdata)
        write(buf, p)
        if rem(i, npoints_buffered) == 0 || i == n
            write(s, take!(buf))
        end
    end
end
