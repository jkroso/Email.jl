@use "../IMAP.jl" parse_message
@use "../types.jl" Mail Attachment BinaryPart
@use Test...

fixture(n) = read(joinpath(@__DIR__, "fixtures", n))

# Collect (filename, mime, bytes) for binary attachments of a parsed message.
bins(m::Mail) = [(a.name, string(a.part.mime), a.part.object)
                 for a in m.attachments if a.part isa BinaryPart]

@testset "simple multipart/mixed PDF" begin
  m = parse_message(IOBuffer(fixture("simple_pdf.eml")))
  bs = bins(m)
  @test length(bs) == 1
  @test bs[1][1] == "invoice-4471.pdf"
  @test bs[1][2] == "application/pdf"
  @test bs[1][3] isa Vector{UInt8}
  @test String(bs[1][3][1:5]) == "%PDF-"
end

@testset "nested alternative + RFC2047 filename" begin
  m = parse_message(IOBuffer(fixture("nested_alt.eml")))
  bs = bins(m)
  @test length(bs) == 1
  @test bs[1][1] == "invoice.png"        # decoded =?UTF-8?B?…?=
  @test bs[1][2] == "image/png"
  @test bs[1][3][1:4] == UInt8[0x89, 0x50, 0x4e, 0x47]
end

@testset "quoted-printable: only the PDF is binary" begin
  m = parse_message(IOBuffer(fixture("qp_encoded.eml")))
  bs = bins(m)
  @test length(bs) == 1
  @test bs[1][1] == "catalogue.pdf"
end

@testset "no attachment" begin
  m = parse_message(IOBuffer(fixture("no_attachment.eml")))
  @test isempty(bins(m))
end
