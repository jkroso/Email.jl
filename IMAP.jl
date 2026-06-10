@use "github.com/jkroso/URI.jl" @uri_str URI decode ["FS.jl" @fs_str FSPath]
@use "./types.jl" Attachment PlainText HTMLPart BinaryPart Alternatives Mail Contact text html
@use "github.com/jkroso/Prospects.jl" @mutable @struct assoc @field_str
@use "github.com/jkroso/Buffer.jl" Buffer
@use Dates: format, now, Date, DateTime, @dateformat_str
@use Base64: base64encode, Base64DecodePipe, base64decode
@use TimeZones: ZonedDateTime, localzone
@use ProgressMeter: @showprogress
@use Sockets: connect, TCPSocket
@use OpenSSL

const CRLF = "\r\n"

struct IMAPError <: Exception
  msg::String
end
Base.showerror(io::IO, e::IMAPError) = print(io, "IMAPError: ", e.msg)

_search_cmd(; since::Union{Nothing,Date}=nothing, before::Union{Nothing,Date}=nothing,
              uid_after::Union{Nothing,Integer}=nothing) = begin
  if since !== nothing || before !== nothing
    parts = String[]
    since !== nothing  && push!(parts, "SINCE "  * format(since,  dateformat"dd-u-yyyy"))
    before !== nothing && push!(parts, "BEFORE " * format(before, dateformat"dd-u-yyyy"))
    return "UID SEARCH " * join(parts, " ")
  end
  uid_after !== nothing && return "UID SEARCH UID $(Int(uid_after)+1):*"
  "UID SEARCH ALL"
end

_parse_search(out::AbstractString)::Vector{Int} = begin
  for line in split(out, r"\r?\n")
    m = match(r"^\*\s+SEARCH(.*)$"i, line)
    m === nothing && continue
    return [parse(Int, t) for t in split(strip(m.captures[1])) if !isempty(t)]
  end
  Int[]
end

_fetch_cmd(uid::Integer; peek::Bool=true, section::AbstractString="") =
  "UID FETCH $(Int(uid)) (BODY$(peek ? ".PEEK" : "")[$section])"

# Compress sorted UIDs into the RFC 3501 sequence-set syntax ("1:3,7,9:10") so a
# batched FETCH of thousands of mostly-consecutive UIDs stays within command-line
# length limits.  Input need not be sorted or unique.
_uid_set(uids) = begin
  ids = sort!(unique(Int.(uids)))
  isempty(ids) && return ""
  parts = String[]
  lo = hi = ids[1]
  for uid in @view ids[2:end]
    if uid == hi + 1
      hi = uid
    else
      push!(parts, lo == hi ? string(lo) : "$lo:$hi")
      lo = hi = uid
    end
  end
  push!(parts, lo == hi ? string(lo) : "$lo:$hi")
  join(parts, ",")
end

# Parse a multi-message UID FETCH response into uid => literal-bytes pairs.  Each
# message arrives as an untagged line "* n FETCH (UID x BODY[…] {N}" followed by
# N payload bytes.  Assumes the UID attribute precedes the literal opener on its
# line (true of Gmail and every mainstream server — UID FETCH always echoes UID).
# Lines that aren't literal openers (closing parens etc.) are skipped.
_parse_fetch_literals(out::AbstractVector{UInt8})::Vector{Pair{Int,Vector{UInt8}}} = begin
  io = IOBuffer(Vector{UInt8}(out))
  results = Pair{Int,Vector{UInt8}}[]
  while !eof(io)
    line = readline(io)
    m = match(r"\bUID (\d+)\b.*\{(\d+)\}$", line)
    m === nothing && continue
    uid = parse(Int, m.captures[1])
    n = parse(Int, m.captures[2])
    push!(results, uid => read(io, n))
  end
  results
end

# A FETCH response wraps its payload in an IMAP literal "... {N}\r\n<N bytes>".
# Return those N bytes; fall back to the whole buffer when no literal is present.
_parse_literal(out::AbstractVector{UInt8})::Vector{UInt8} = begin
  s = String(copy(out))
  m = match(r"\{(\d+)\}\r?\n", s)
  m === nothing && return Vector{UInt8}(out)
  n = parse(Int, m.captures[1])
  start = m.offset + length(m.match)   # first payload byte follows the match
  bytes = Vector{UInt8}(out)
  stop = min(start + n - 1, length(bytes))
  bytes[start:stop]
end

parse_date(str) = begin
  date = match(r"(?:\w+, )?(\d+ \w+ \d+ \d+:\d+:\d+ [+-]\d+)", str)[1]
  parse(ZonedDateTime, date, dateformat"dd u yyyy HH:MM:SS zzzz")
end

_h(hdrs, k) = something(get(hdrs, k, nothing), get(hdrs, lowercase(k), nothing), "")

_date_or_now(hdrs) = begin
  d = get(hdrs, "Date", nothing)
  d === nothing && return now(localzone())
  try; parse_date(d); catch; now(localzone()); end
end

mutable struct IMAPServer
  uri::URI
  sock::Union{OpenSSL.SSLStream, TCPSocket}
  selected::Union{Nothing,String}   # currently-SELECTed folder, nothing if none
end

connect(uri::URI{:imap}) = hello(IMAPServer(uri, connect(uri.host, uri.port), nothing))

connect(uri::URI{:imaps}) = begin
  sock = OpenSSL.SSLStream(connect(uri.host, uri.port))
  OpenSSL.hostname!(sock, uri.host)
  OpenSSL.connect(sock)
  hello(IMAPServer(uri, sock, nothing))
end

"Connect, run `f(server)`, and always close the connection afterwards"
connect(f::Function, uri::Union{URI{:imap},URI{:imaps}}) = begin
  server = connect(uri)
  try f(server) finally close(server) end
end

hello(s::IMAPServer) = begin
  status = String(readchunk(s.sock))
  startswith(status, "* OK") || throw(IMAPError("server did not greet with OK: $status"))
  haslogin(s.uri) && login(s)
  s
end

haslogin(uri::URI) = !isempty(uri.username) && !isempty(uri.password)

# IMAP quoted-string (RFC 3501): wrap in quotes, backslash-escape " and \.  This
# is essential for credentials containing spaces (e.g. Gmail app passwords) or
# special characters — an unquoted LOGIN would split "app pw" into two args.
_imap_quote(s) = '"' * replace(string(s), "\\" => "\\\\", "\"" => "\\\"") * '"'
login((;sock,uri)::IMAPServer) = command(sock, "LOGIN $(_imap_quote(uri.username)) $(_imap_quote(uri.password))")
logout((;sock)::IMAPServer) = command(sock, "LOGOUT")

readchunk(sock) = begin
  @assert !eof(sock)
  readavailable(sock)
end

gentag() = string(rand(UInt32), base=62)

command(sock, cmd, expectation="OK") = begin
  out = Buffer()
  command(sock, cmd, out, expectation)
  close(out)
  String(read(out))
end

command(sock::IO, cmd, out::IO, expectation="OK") = begin
  tag = gentag()
  write(sock, "$tag $cmd\r\n")
  while true
    buffer = readchunk(sock)
    if hasstatusline(buffer, tag)
      range = status_split(buffer)
      status = String(@view(buffer[range.stop + length(tag) + 2:end]))
      startswith(status, expectation) || throw(IMAPError(strip(status)))
      write(out, resize!(buffer, range.start))
      break
    else
      write(out, buffer)
    end
  end
end

const bCRLF = Vector{UInt8}(CRLF)

status_split(buf) = begin
  i = findlast(bCRLF, @view(buf[1:end-1]))
  isnothing(i) ? (0:0) : i
end

hasstatusline(buffer::Vector{UInt8}, tag) = begin
  range = status_split(buffer)
  startswith(String(@view(buffer[range.stop+1:end])), tag)
end

struct Folder
  name::AbstractString
  attributes::Vector{String}
  server::IMAPServer
end

Base.show(io::IO, f::Folder) = print(io, "Folder(\"", f.name, "\")")

folders(server::IMAPServer) = begin
  folders = command(server.sock, "LIST \"\" *")
  map(eachline(IOBuffer(folders))) do line
    m = match(r"^\* LIST \((?<attributes>[^)]*)\) \"/\" \"?(?<name>[^\"]+)\"?$", strip(line))
    @assert !isnothing(m) "Invalid line: $line"
    attributes = map(s->s[2:end], split(m[:attributes]))
    Folder(m[:name], attributes, server)
  end
end

Base.getindex(s::IMAPServer, folder::AbstractString) = begin
  available = folders(s)
  for f in available
    f.name == folder && return f
  end
  error("No such folder: $folder. Available folders: $(join(map(field"name", available), ", "))")
end

select((;name,server,attributes)::Folder) = begin
  @assert !("Noselect" in attributes)
  str = command(server.sock, "SELECT \"$name\"")
  server.selected = name
  m = match(r"\* (\d+) EXISTS", str)
  isnothing(m) && return NaN
  parse(Int, m[1])
end

ensure_selected(f::Folder) = begin
  f.server.selected == f.name && return
  @assert !("Noselect" in f.attributes)
  command(f.server.sock, "SELECT \"$(f.name)\"")
  f.server.selected = f.name
  nothing
end

"""
UIDs matching the search. Pass `since::Date` and/or `before::Date` (internal-date
bounds; SINCE is inclusive, BEFORE exclusive), or `uid_after::Integer` (defaults
to ALL).
"""
search(f::Folder; kw...) = begin
  ensure_selected(f)
  _parse_search(command(f.server.sock, _search_cmd(; kw...)))
end

"Lowercased-key header dict for one message (BODY.PEEK[HEADER] by default)."
fetchheaders(f::Folder, uid::Integer; peek::Bool=true) = begin
  ensure_selected(f)
  out = Buffer()
  command(f.server.sock, _fetch_cmd(uid; peek, section="HEADER"), out)
  close(out)
  hdrs = parse_headers(IOBuffer(_parse_literal(read(out))))
  Dict{String,String}(lowercase(k) => v for (k, v) in hdrs)
end

"""
Header dicts for many messages in a handful of round trips — one `UID FETCH`
per `chunk` UIDs instead of one per message, which is the difference between
seconds and tens of minutes on a multi-thousand-message range.

Returns `Dict{Int,Dict{String,String}}` keyed by UID (header keys lowercased).
UIDs the server doesn't answer for (expunged mid-fetch) are simply absent, as
is any message whose headers fail to parse — bulk callers want the rest of the
batch, not an exception.
"""
fetchheaders(f::Folder, uids::AbstractVector{<:Integer}; peek::Bool=true, chunk::Integer=500) = begin
  ensure_selected(f)
  result = Dict{Int,Dict{String,String}}()
  isempty(uids) && return result
  for batch in Iterators.partition(sort!(unique(Int.(uids))), chunk)
    out = Buffer()
    command(f.server.sock, "UID FETCH $(_uid_set(batch)) (BODY$(peek ? ".PEEK" : "")[HEADER])", out)
    close(out)
    for (uid, payload) in _parse_fetch_literals(read(out))
      hdrs = try parse_headers(IOBuffer(payload)) catch; continue end
      result[uid] = Dict{String,String}(lowercase(k) => v for (k, v) in hdrs)
    end
  end
  result
end

"Full parsed Mail for one message (BODY.PEEK[] by default)."
fetch(f::Folder, uid::Integer; peek::Bool=true) = begin
  ensure_selected(f)
  out = Buffer()
  command(f.server.sock, _fetch_cmd(uid; peek, section=""), out)
  close(out)
  parse_message(IOBuffer(_parse_literal(read(out))))
end

"`folder[uid]` fetches one message. `folder[end]` fetches the most recent one."
Base.getindex(f::Folder, uid::Integer) = fetch(f, uid)
Base.lastindex(f::Folder) = last(search(f))
Base.firstindex(f::Folder) = first(search(f))

"""
Lazily fetch the messages matching a search. Takes the same keyword
arguments as `search` (`since::Date`, `uid_after::Integer`, default ALL):

    for mail in messages(inbox, since=Date(2026, 6, 1))
      println(mail.subject)
    end
"""
messages(f::Folder; kw...) = (fetch(f, uid) for uid in search(f; kw...))

"Round-trip a NOOP; throws IMAPError on failure. Cheap liveness/credential check."
noop(s::IMAPServer) = (command(s.sock, "NOOP"); nothing)

Base.close(s::IMAPServer) = begin
  try; command(s.sock, "LOGOUT"); catch; end
  try; close(s.sock); catch; end
  nothing
end

fetch((;name,server,attributes)::Folder) = begin
  out = Buffer()
  errormonitor(@async begin
    command(server.sock, "FETCH 1:* (RFC822)", out)
    close(out)
  end)
  out
end

read_message(io) = begin
  line = readline(io)
  len = @view line[findlast('{', line)+1:end-1]
  msg = read(io, parse(Int, len))
  readline(io) # consume closing bracket
  IOBuffer(msg)
end

parse_headers(io) = begin
  headers = Dict{String,String}()
  attr,value = "",""
  while !eof(io)
    line = readline(io)
    isempty(line) && break # end of headers
    if startswith(line, r"\s")
      @assert !isempty(attr) "Malformed header"
      value *= line
    else
      i = findfirst(':', line)
      @assert !isnothing(i) "Malformed header"
      attr,value = line[1:i-1], lstrip(line[i+1:end])
    end
    headers[attr] = value
  end
  headers
end

parse_message(io) = toEmail(parse_part(io)...)

toEmail(header, ::MIME"multipart/mixed", parts) = begin
  (body, attachments...) = parts
  Mail(from=_h(header, "From"),
       to=_h(header, "To"),
       date=_date_or_now(header),
       subject=_h(header, "Subject"),
       body=toPart(body.headers, body.mime, body.body),
       replyto=let r=_h(header,"Reply-To"); isempty(r) ? nothing : r end,
       id=let i=_h(header,"Message-Id"); isempty(i) ? nothing : i end,
       attachments=map(p->toAttachment(p[1], p[2], p[3]), attachments))
end

toEmail(headers, mime, body) = begin
  Mail(from=_h(headers, "From"),
       to=_h(headers, "To"),
       date=_date_or_now(headers),
       subject=_h(headers, "Subject"),
       body=toPart(headers, mime, body),
       replyto=let r=_h(headers,"Reply-To"); isempty(r) ? nothing : r end,
       id=let i=_h(headers,"Message-Id"); isempty(i) ? nothing : i end)
end

toPart(headers, mime::MIME, data) = BinaryPart(mime, data isa IO ? read(data) : Vector{UInt8}(data))
toPart(headers, mime::MIME"multipart/alternative", parts) = Alternatives(map(p->toPart(p[1],p[2],p[3]), parts))
toPart(headers, mime::MIME"text/plain", body) = PlainText(asstring(body))
toPart(headers, mime::MIME"text/html", body) = HTMLPart(asstring(body))

asstring(io::IO) = read(io, String)
asstring(s) = String(s)

toAttachment(headers, mime::MIME, body) = Attachment(filename(headers), toPart(headers, mime, body))

filename(headers) = begin
  cd = get(headers, "Content-Disposition", "")
  ct = get(headers, "Content-Type", "")
  m = match(r"filename\*?=\"?([^\";]+)\"?", cd)
  m === nothing && (m = match(r"\bname=\"?([^\";]+)\"?", ct))
  m === nothing ? "" : _decode_2047(strip(m.captures[1]))
end

# Minimal RFC 2047 "=?charset?B/Q?…?=" decode for filenames.
_decode_2047(s::AbstractString) = begin
  occursin("=?", s) || return s
  replace(s, r"=\?[^?]+\?([BbQq])\?([^?]*)\?=" => function(whole)
    mm = match(r"=\?[^?]+\?([BbQq])\?([^?]*)\?=", whole)
    enc = uppercase(mm.captures[1]); payload = mm.captures[2]
    if enc == "B"
      try; return String(base64decode(payload)); catch; return payload; end
    else
      return replace(payload, "_" => " ", r"=([0-9A-Fa-f]{2})" => m2 -> String(hex2bytes(m2[2:3])))
    end
  end)
end

parse_part(io) = begin
  headers = parse_headers(io)
  mime = parse_mime(get(headers, "Content-Type", "text/plain"))
  body = if mime isa MIME"multipart/mixed" || mime isa MIME"multipart/alternative"
    parse_parts(io, match(r"boundary=\"?([^\s\"]+)\"?", headers["Content-Type"])[1])
  else
    encoding = lowercase(get(headers, "Content-Transfer-Encoding", "binary"))
    decode_content(Val(Symbol(encoding)), io)
  end
  (headers=headers, mime=mime, body=body)
end

parse_parts(io, marker) = begin
  parts = Any[]
  @assert all(isspace, readuntil(io, "--"))
  @assert readline(io) == marker
  while !eof(io)
    part = readuntil(io, "--$marker")
    push!(parts, parse_part(IOBuffer(part)))
    line = readline(io)
    line == "--" && return parts
  end
  error("Unexpected end of file")
end

decode_content(::Val{Symbol("7bit")}, io) = io
decode_content(::Val{Symbol("8bit")}, io) = io
decode_content(::Val{:binary}, io) = io

decode_content(::Val{:base64}, io) = begin
  input = PipeBuffer()
  decoded = Base64DecodePipe(input)
  while !eof(io)
    c = read(io, Char)
    c == '\n' && continue
    if c == '\r'
      @assert read(io, Char) == '\n'
    else
      write(input, c)
    end
  end
  decoded
end

decode_content(::Val{Symbol("quoted-printable")}, io) = begin
  out = PipeBuffer()
  while !eof(io)
    c = read(io, Char)
    if c == '='
      c = read(io, Char)
      c == '\n' && continue
      if c == '\r'
        @assert read(io, Char) == '\n'
      else
        write(out, hex2bytes((c, read(io, Char))))
      end
    else
      write(out, c)
    end
  end
  out
end

parse_mime(str) = MIME(lowercase(match(r"^([^; ]+)", str)[1]))

Base.iterate(f::Folder) = begin
  n = select(f)
  iterate(f, fetch(f))
end
Base.iterate(f::Folder, io) = begin
  eof(io) && return nothing
  (parse_message(read_message(io)), io)
end
Base.length(f::Folder) = select(f)
Base.eltype(f::Folder) = Mail

"""
Save every message as a .eml file under `dir` (defaults to
`~/Desktop/<username>`), one subdirectory per folder:

    download(uri"imaps://user:pass@imap.gmail.com:993")
"""
download(uri::URI, dir=fs"~/Desktop/$(uri.username)"; verbose::Bool=false) =
  connect(server->download(server, dir; verbose), uri)

download(server::IMAPServer, dir=fs"~/Desktop/$(server.uri.username)"; verbose::Bool=false) = begin
  mkpath(string(dir))
  if verbose
    @showprogress desc="Downloading all folders" for folder in folders(server)
      "Noselect" in folder.attributes && continue
      download(folder, dir * folder.name; verbose)
    end
  else
    for folder in folders(server)
      "Noselect" in folder.attributes && continue
      download(folder, dir * folder.name; verbose)
    end
  end
end

download(folder::Folder, dir; verbose::Bool=false) = begin
  mkpath(string(dir))
  n = select(folder)
  io = fetch(folder)
  if verbose
    @showprogress desc=folder.name for i in 1:n
      write(dir * "$i.eml", read_message(io))
    end
  else
    for i in 1:n
      write(dir * "$i.eml", read_message(io))
    end
  end
end
