@use "github.com/jkroso/Rutherford.jl/test.jl" @test testset
@use "github.com/jkroso/URI.jl" @uri_str ["FSPath.jl" @fs_str]
@use "github.com/jkroso/HTTP.jl/client" GET
@use "github.com/jkroso/JSON.jl/read.jl"
@use "../SMTP.jl" send Mail
@use "../IMAP.jl"
@use Sockets: connect

cd(@dirname)
const maildev = open(`maildev`)
const tameimap = open(`$(homedir())/.gocode/bin/tameimap -d -`)

testset("IMAP") do
  server = connect(uri"imap://bob:pass@localhost:1143")
  inbox=server["INBOX"]
  @test collect(inbox) isa Vector{Mail}
  @test length(collect(inbox)) == 2
  @test collect(inbox)[1].subject == "Welcome to tameimap"
  @test collect(inbox)[2].subject == "Test"
end

testset("SMTP") do
  send(uri"smtp://0.0.0.0:1025",
   Mail(from="Jake <jake@gmail.com>",
        to="Elon <e@gmail.com>",
        subject="test",
        body="Thank you for your business"))

  send(uri"smtp://0.0.0.0:1025",
   Mail(from="Jake <jake@gmail.com>",
        to="Elon <e@gmail.com>",
        subject="PDF test",
        body="Thank you for your business",
        attachments=[fs"$(@dirname)/invoice.pdf"]))

  send(uri"smtp://0.0.0.0:1025",
   Mail(from="Jake <jake@gmail.com>",
        to="Elon <e@gmail.com>",
        subject="Multi attatchment test",
        body="Thank you for your business",
        attachments=[fs"$(@dirname)/invoice.pdf", fs"$(@dirname)/../Readme.md"]))

  (a,b,c) = parse(GET("http://0.0.0.0:1080/email"))

  @test a["from"][1]["name"] == "Jake"
  @test a["to"][1]["address"] == "e@gmail.com"
  @test a["text"]|>strip == "Thank you for your business"

  @test b["attachments"][1]["generatedFileName"] == "invoice.pdf"
  @test b["attachments"][1]["contentType"] == "application/pdf"

  @test length(c["attachments"]) == 2
  @test c["attachments"][2]["generatedFileName"] == "Readme.md"
  @test c["attachments"][2]["contentType"] == "text/markdown"
  @test c["attachments"][2]["length"] == sizeof(read(fs"$(@dirname)/../Readme.md"))
end

kill(maildev)
kill(tameimap)
