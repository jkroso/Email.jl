# Email.jl

Provides the ability to send and receive email (SMTP, and IMAP)

To send an email:

```julia
@use "github.com/jkroso/Email.jl/SMTP.jl" Mail send @uri_str @fs_str

send(uri"smtps://user:pass@smtp.gmail.com:465", Mail(
  from="user@gmail.com",
  to="to@gmail.com",
  subject="example",
  body="This is a simple body",
  attatchments=[fs"~/somefile.pdf"]
))
```

To get all messages in a folder

```julia
@use "github.com/jkroso/Email.jl/IMAP.jl" download @uri_str
@use Sockets: connect

email = connect(uri"imaps://user:pass@imap.gmail.com:993")
for msg in email["INBOX"]
  @show msg
end
```

to download all mail to your desktop.

```julia
download(email)
```
