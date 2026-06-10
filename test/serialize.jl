@use "../types.jl" Mail Attachment PlainText HTMLPart BinaryPart Alternatives Contact text html
@use "../IMAP.jl" parse_message
@use Test...

roundtrip(m::Mail) = begin
  io = IOBuffer()
  write(io, m)
  parse_message(seekstart(io))
end

@testset "plain text round trip" begin
  m = roundtrip(Mail(from="Jake <jake@gmail.com>",
                     to="Elon <e@x.com>",
                     subject="hi",
                     body="Thank you for your business"))
  @test m.from.name == "Jake"
  @test occursin("jake@gmail.com", string(m.from.email))
  @test m.subject == "hi"
  @test strip(text(m)) == "Thank you for your business"
  @test html(m) === nothing
end

@testset "string paths convert to attachments" begin
  m = Mail(attachments=[joinpath(@__DIR__, "invoice.pdf")])
  @test m.attachments[1] isa Attachment
  @test m.attachments[1].name == "invoice.pdf"
  @test m.attachments[1].part isa BinaryPart
  @test String(m.attachments[1].part.object[1:5]) == "%PDF-"
end

@testset "attachment round trip" begin
  m = roundtrip(Mail(from="Jake <jake@gmail.com>",
                     to="Elon <e@x.com>",
                     subject="invoice",
                     body="see attached",
                     attachments=[joinpath(@__DIR__, "invoice.pdf")]))
  @test strip(text(m)) == "see attached"
  @test length(m.attachments) == 1
  @test m.attachments[1].name == "invoice.pdf"
  @test String(m.attachments[1].part.object[1:5]) == "%PDF-"
end

@testset "html mail with plain text fallback" begin
  m = roundtrip(Mail(from="Jake <jake@gmail.com>",
                     to="Elon <e@x.com>",
                     subject="hi",
                     body=Alternatives([PlainText("Hello"), HTMLPart("<h1>Hello</h1>")])))
  @test strip(text(m)) == "Hello"
  @test strip(html(m)) == "<h1>Hello</h1>"
end

@testset "show" begin
  m = Mail(from="Jake <jake@gmail.com>", to="e@x.com", subject="hi")
  @test occursin("→", sprint(show, m))
  @test sprint(show, m.from) == "Jake <jake@gmail.com>"
end
