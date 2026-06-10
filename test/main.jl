@use "../SMTP.jl" send connect Mail PlainText HTMLPart Alternatives
@use "../IMAP.jl" messages search fetchheaders text html
@use "github.com/jkroso/URI.jl" @uri_str
@use "github.com/jkroso/HTTP.jl/client" GET
@use "github.com/jkroso/JSON.jl/read.jl"
@use Test...

const maildev = open(`maildev`)
const tameimap = open(Cmd(`$(homedir())/.gocode/bin/tameimap -d -`, dir=@__DIR__))
sleep(2)

try
  @testset "IMAP" begin
    connect(uri"imap://bob:pass@localhost:1143") do server
      inbox = server["INBOX"]
      mails = collect(inbox)
      @test mails isa Vector{Mail}
      @test length(mails) == 2
      @test mails[1].subject == "Welcome to tameimap"
      @test mails[2].subject == "Test"
      @test text(mails[1]) isa AbstractString

      uids = search(inbox)
      @test length(uids) == 2
      @test inbox[uids[1]].subject == "Welcome to tameimap"
      @test inbox[end] isa Mail
      @test [m.subject for m in messages(inbox)] == [m.subject for m in mails]
      @test fetchheaders(inbox, uids[1])["subject"] == "Welcome to tameimap"
    end
  end

  @testset "SMTP" begin
    smtp = uri"smtp://0.0.0.0:1025"

    send(smtp, Mail(from="Jake <jake@gmail.com>",
                    to="Elon <e@gmail.com>",
                    subject="test",
                    body="Thank you for your business"))

    send(smtp, from="Jake <jake@gmail.com>",
               to="Elon <e@gmail.com>",
               subject="PDF test",
               body="Thank you for your business",
               attachments=[joinpath(@__DIR__, "invoice.pdf")])

    send(smtp, from="Jake <jake@gmail.com>",
               to="Elon <e@gmail.com>",
               subject="Multi attachment test",
               body="Thank you for your business",
               attachments=[joinpath(@__DIR__, "invoice.pdf"), joinpath(@__DIR__, "..", "Readme.md")])

    send(smtp, from="Jake <jake@gmail.com>",
               to="Elon <e@gmail.com>",
               subject="HTML test",
               body=Alternatives([PlainText("plain version"), HTMLPart("<b>bold version</b>")]))

    connect(smtp) do server
      send(server, Mail(from="Jake <jake@gmail.com>", to="Elon <e@gmail.com>", subject="one", body="1"),
                   Mail(from="Jake <jake@gmail.com>", to="Elon <e@gmail.com>", subject="two", body="2"))
    end

    (a, b, c, d, e, f) = parse(GET("http://0.0.0.0:1080/email"))

    @test a["from"][1]["name"] == "Jake"
    @test a["to"][1]["address"] == "e@gmail.com"
    @test strip(a["text"]) == "Thank you for your business"

    @test b["attachments"][1]["fileName"] == "invoice.pdf"
    @test b["attachments"][1]["contentType"] == "application/pdf"

    @test length(c["attachments"]) == 2
    @test c["attachments"][2]["fileName"] == "Readme.md"
    @test c["attachments"][2]["contentType"] == "text/markdown"
    @test c["attachments"][2]["length"] == sizeof(read(joinpath(@__DIR__, "..", "Readme.md")))

    @test d["subject"] == "HTML test"
    @test occursin("<b>bold version</b>", d["html"])
    @test strip(d["text"]) == "plain version"

    @test e["subject"] == "one"
    @test f["subject"] == "two"
  end
finally
  kill(maildev)
  kill(tameimap)
end
