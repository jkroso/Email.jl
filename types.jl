@use "github.com/jkroso/Prospects.jl" @abstract @mutable @struct @field_str
@use "github.com/jkroso/URI.jl" @uri_str URI decode ["FS.jl" @fs_str FSPath]
@use TimeZones: ZonedDateTime, localzone, now
@use MIMEs: mime_from_extension

@abstract struct Part end
@struct Attachment(name::String, part::Part) <: Part
@struct PlainText(object) <: Part
@struct HTMLPart(object) <: Part
@struct BinaryPart(mime, object) <: Part
@struct Alternatives(options::Vector{Part}) <: Part
Base.convert(::Type{Attachment}, p::FSPath) = Attachment(p.name, BinaryPart(mime_from_extension(p.extension), read(p)))
Base.convert(::Type{Part}, s::AbstractString) = PlainText(s)

@struct Contact(name="", email::URI)
Base.convert(::Type{Contact}, p::AbstractString) = begin
  m = match(r"^((?:\w+\s)*)<?([^>]+)>?$", p)
  isnothing(m) && return Contact("", uri"")
  Contact(name=rstrip(m[1]), email=URI(m[2]))
end

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
