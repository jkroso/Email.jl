@use "github.com/jkroso/URI.jl" @uri_str URI decode ["FS.jl" @fs_str FSPath]
@use "./types.jl" Attachment PlainText HTMLPart BinaryPart Alternatives Mail
@use "github.com/jkroso/Prospects.jl" @mutable @struct assoc @field_str
@use "github.com/jkroso/Buffer.jl" Buffer
@use Dates: format, now, Date, DateTime, @dateformat_str
@use Base64: base64encode, Base64DecodePipe
@use TimeZones: ZonedDateTime, localzone
@use ProgressMeter: @showprogress
@use Sockets: connect, TCPSocket
@use OpenSSL
@use DotEnv

const env = DotEnv.config()

const CRLF = "\r\n"

parse_date(str) = begin
  date = match(r"(?:\w+, )?(\d+ \w+ \d+ \d+:\d+:\d+ [+-]\d+)", str)[1]
  parse(ZonedDateTime, date, dateformat"dd u yyyy HH:MM:SS zzzz")
end

mutable struct IMAPServer
  uri::URI
  sock::Union{OpenSSL.SSLStream, TCPSocket}
end

connect(uri::URI{:imap}) = hello(IMAPServer(uri, connect(uri.host, uri.port)))

connect(uri::URI{:imaps}) = begin
  sock = OpenSSL.SSLStream(connect(uri.host, uri.port))
  OpenSSL.hostname!(sock, uri.host)
  OpenSSL.connect(sock)
  hello(IMAPServer(uri, sock))
end

hello(s::IMAPServer) = begin
  status = String(readchunk(s.sock))
  @assert startswith(status, "* OK")
  haslogin(s.uri) && login(s)
  s
end

haslogin(uri::URI) = !isempty(uri.username) && !isempty(uri.password)

login((;sock,uri)::IMAPServer) = command(sock, "LOGIN $(uri.username) $(uri.password)")
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
      @assert startswith(status, expectation) status
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

folders(server::IMAPServer) = begin
  folders = command(server.sock, "LIST \"\" *")
  map(eachline(IOBuffer(folders))) do line
    m = match(r"^\* LIST \((?<attributes>[^)]*)\) \"/\" \"?(?<name>[^\"]+)\"?$", strip(line))
    @assert !isnothing(m) "Invalid line: $line"
    attributes = map(s->s[2:end], split(m[:attributes]))
    Folder(m[:name], attributes, server)
  end
end

select((;name,server,attributes)::Folder) = begin
  @assert !("Noselect" in attributes)
  str = command(server.sock, "SELECT \"$name\"")
  m = match(r"\* (\d+) EXISTS", str)
  isnothing(m) && return NaN
  parse(Int, m[1])
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

toEmail(header, ::Union{MIME"multipart/alternative",MIME"multipart/mixed"}, parts) = begin
  (body, attachments...) = parts
  Mail(from=header["From"],
       to=header["To"],
       date=parse_date(header["Date"]),
       subject=header["Subject"],
       body=toPart(body.headers, body.mime, body.body),
       replyto=get(header, "Reply-To", nothing),
       id=get(header, "Message-Id", nothing),
       attachments=map(p->toAttachment(p[1], p[2], p[3]), attachments))
end

toEmail(headers, mime, body) = begin
  Mail(from=headers["From"],
       to=headers["To"],
       date=parse_date(headers["Date"]),
       subject=headers["Subject"],
       body=toPart(headers, mime, body),
       replyto=get(headers, "Reply-To", nothing),
       id=get(headers, "Message-Id", nothing))
end

toPart(headers, mime::MIME, data) = BinaryPart(mime, data)
toPart(headers, mime::MIME"multipart/alternative", parts) = Alternatives(map(p->toPart(p[1],p[2],p[3]), parts))
toPart(headers, mime::MIME"text/plain", body) = PlainText(body)
toPart(headers, mime::MIME"text/html", body) = HTMLPart(body)

toAttachment(headers, mime::MIME, body) = Attachment(filename(headers), toPart(headers, mime, body))

filename(headers) = begin
  cd = get(headers, "Content-Disposition", nothing)
  isnothing(cd) && return ""
  match(r"filename=\"?([^\"]+)\"?", cd)[1]
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

Base.write(io::IO, part::PlainText) = write(sock, part.object)
Base.write(io::IO, msg::Mail) = begin
  write(io, """
            Date: $(format(msg.date, zdt))\r
            From: $(msg.from.name) <$(msg.from.email)>\r
            Subject: $(msg.subject)\r
            To: $(msg.to.email)\r
            MIME-Version: 1.0\r\n""")
  if !isempty(msg.cc)
    write(sock, "Cc: $(join(map(field"email", msg.cc), ", "))\r\n")
  end
  if !isnothing(msg.replyto)
    write(sock, "Reply-To: $(msg.replyto.email)\r\n")
  end
  if isempty(msg.attachments)
    write_attachment(sock, msg.body)
  else
    write(sock, "Content-Type: multipart/mixed; boundary=\"$boundary\"\r\n\r\n")
    attachments = isempty(msg.body) ? msg.attachments : [msg.body, msg.attachments...]
    for a in attachments
      write(sock, "--$boundary$CRLF")
      write_attachment(sock, a)
    end
    write(sock, "--$boundary--$CRLF")
  end
end

write_attachment(io::IO, a::PlainText) = begin
  write(io::IO, "Content-Type: text/plain; charset=UTF-8\r\n")
  write(io::IO, "Content-Disposition: inline\r\n\r\n")
  write(io::IO, a.object)
  write(io::IO, "\r\n")
end

write_attachment(io::IO, a::BinaryPart) = begin
  write(io, "Content-Type: $(contenttype_from_mime(a.mime))\r\n")
  write(io, "Content-Transfer-Encoding: base64\r\n\r\n")
  writefolded(io, base64encode(a.object))
  write(io, "\r\n")
end

write_attachment(io::IO, a::Attachment) = begin
  write(io, "Content-Disposition: attachment; filename=\"$(a.name)\"\r\n")
  write_attachment(io, a.part)
end

"email's have a soft line limit of 78"
writefolded(io::IO, data, sizelimit=78) = begin
  range = 1:sizelimit:length(data)
  start = 1
  for i in 2:length(range)
    stop = range[i]
    write(io, @view(data[start:stop]), CRLF)
    start = stop+1
  end
  write(io, @view(data[start:length(data)]), CRLF)
end

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

download(uri, dir=fs"~/Desktop/$(uri.username)") = begin
  server = connect(uri)::IMAPServer
  login(server)
  download(server, dir)
end

download(server::IMAPServer, dir) = begin
  mkpath(string(dir))
  @showprogress desc="Downloading all folders" for folder in folders(server)
    "Noselect" in folder.attributes && continue
    download(folder, dir * folder.name)
  end
end

download(folder::Folder, dir) = begin
  mkpath(string(dir))
  n = select(folder)
  io = fetch(folder)
  @showprogress desc=folder.name for i in 1:n
    write(dir * "$i.eml", read_message(io))
  end
end

Base.getindex(s::IMAPServer, folder::AbstractString) = begin
  for f in folders(s)
    f.name == folder && return f
  end
  error("No such folder: $folder")
end
