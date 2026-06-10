@use "github.com/jkroso/Prospects.jl" @abstract @mutable @struct @field_str
@use "github.com/jkroso/URI.jl" @uri_str URI decode ["FS.jl" @fs_str FSPath]
@use TimeZones: ZonedDateTime, localzone, now
@use MIMEs: mime_from_extension, contenttype_from_mime
@use Dates: format, @dateformat_str
@use Base64: base64encode

const CRLF = "\r\n"
const rfc2822 = dateformat"e, dd u yyyy HH:MM:SS zzzz"

@abstract struct Part end
@struct Attachment(name::String, part::Part) <: Part
@struct PlainText(object) <: Part
@struct HTMLPart(object) <: Part
@struct BinaryPart(mime, object) <: Part
@struct Alternatives(options::Vector{Part}) <: Part
Base.convert(::Type{Attachment}, p::FSPath) = Attachment(p.name, BinaryPart(mime_from_extension(p.extension), read(p)))
Base.convert(::Type{Attachment}, path::AbstractString) = convert(Attachment, FSPath(path))
Base.convert(::Type{Part}, s::AbstractString) = PlainText(s)
Base.isempty(p::Part) = false
Base.isempty(p::PlainText) = isempty(p.object)

@struct Contact(name="", email::URI)
Base.convert(::Type{Contact}, p::AbstractString) = begin
  m = match(r"^((?:\w+\s)*)<?([^>]+)>?$", p)
  isnothing(m) && return Contact("", uri"")
  Contact(name=rstrip(m[1]), email=URI(m[2]))
end
Base.show(io::IO, c::Contact) = isempty(c.name) ? print(io, c.email) : print(io, c.name, " <", c.email, '>')

@mutable struct Mail
  id::Union{Nothing,String}=string(rand(UInt128), base=62)
  date::ZonedDateTime=now(localzone())
  from::Contact=""
  to::Contact=""
  cc=Contact[]
  replyto::Union{Nothing,Contact}=nothing
  subject=""
  body::Part=""
  attachments=Attachment[]
end

Base.show(io::IO, m::Mail) = print(io, "Mail(", m.from, " → ", m.to, ": \"", m.subject, "\")")

"The plain text body of the mail, or `nothing` if it doesn't have one"
text(m::Mail) = text(m.body)
text(p::PlainText) = string(p.object)
text(p::Part) = nothing
text(a::Alternatives) = firstof(text, a.options)

"The HTML body of the mail, or `nothing` if it doesn't have one"
html(m::Mail) = html(m.body)
html(p::HTMLPart) = string(p.object)
html(p::Part) = nothing
html(a::Alternatives) = firstof(html, a.options)

firstof(f, parts) = begin
  for p in parts
    x = f(p)
    isnothing(x) || return x
  end
end

"Serialize in RFC 2822 format. `write(\"saved.eml\", mail)` produces a standard .eml file"
Base.write(io::IO, msg::Mail) = begin
  write(io, """
            Date: $(format(msg.date, rfc2822))\r
            From: $(msg.from)\r
            Subject: $(msg.subject)\r
            To: $(msg.to)\r
            MIME-Version: 1.0\r\n""")
  isempty(msg.cc) || write(io, "Cc: $(join(map(field"email", msg.cc), ", "))\r\n")
  isnothing(msg.replyto) || write(io, "Reply-To: $(msg.replyto.email)\r\n")
  if isempty(msg.attachments)
    writepart(io, msg.body)
  else
    boundary = string(rand(UInt128), base=62)
    write(io, "Content-Type: multipart/mixed; boundary=\"$boundary\"\r\n\r\n")
    parts = isempty(msg.body) ? msg.attachments : [msg.body, msg.attachments...]
    for p in parts
      write(io, "--$boundary$CRLF")
      writepart(io, p)
    end
    write(io, "--$boundary--$CRLF")
  end
end

writepart(io::IO, p::PlainText) = begin
  write(io, "Content-Type: text/plain; charset=UTF-8\r\n")
  write(io, "Content-Disposition: inline\r\n\r\n")
  write(io, p.object, CRLF)
end

writepart(io::IO, p::HTMLPart) = begin
  write(io, "Content-Type: text/html; charset=UTF-8\r\n")
  write(io, "Content-Disposition: inline\r\n\r\n")
  write(io, p.object, CRLF)
end

writepart(io::IO, p::BinaryPart) = begin
  write(io, "Content-Type: $(contenttype_from_mime(p.mime))\r\n")
  write(io, "Content-Transfer-Encoding: base64\r\n\r\n")
  writefolded(io, base64encode(p.object))
  write(io, CRLF)
end

writepart(io::IO, p::Alternatives) = begin
  boundary = string(rand(UInt128), base=62)
  write(io, "Content-Type: multipart/alternative; boundary=\"$boundary\"\r\n\r\n")
  for option in p.options
    write(io, "--$boundary$CRLF")
    writepart(io, option)
  end
  write(io, "--$boundary--$CRLF")
end

writepart(io::IO, a::Attachment) = begin
  write(io, "Content-Disposition: attachment; filename=\"$(a.name)\"\r\n")
  writepart(io, a.part)
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
