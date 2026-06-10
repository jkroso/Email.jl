# Email.jl

Send and receive email in Julia (SMTP + IMAP)

## Sending mail

For a one-off mail just pass the fields of the message straight to `send`:

```julia
@use "github.com/jkroso/Email.jl/SMTP.jl" send connect Mail @uri_str

const gmail = uri"smtps://user:app-password@smtp.gmail.com:465"

send(gmail, from="Jake <user@gmail.com>",
            to="elon@x.com",
            subject="Invoice",
            body="Thank you for your business",
            attachments=["~/Documents/invoice.pdf"])
```

Contacts (`from`, `to`, `cc`, `replyto`) are plain strings, either `"Jake <jake@gmail.com>"`
or just `"jake@gmail.com"`. Attachments are file paths (`String` or `FSPath`) and infer
their MIME type from the file extension.

To send several mails over one connection use the do-block form of `connect`, which
always closes the connection when the block exits:

```julia
connect(gmail) do server
  send(server, Mail(from="Jake <user@gmail.com>", to="elon@x.com", subject="one", body="..."),
               Mail(from="Jake <user@gmail.com>", to="sam@openai.com", subject="two", body="..."))
end
```

To send HTML mail provide a plain text fallback with `Alternatives`:

```julia
@use "github.com/jkroso/Email.jl/SMTP.jl" PlainText HTMLPart Alternatives

send(gmail, from="Jake <user@gmail.com>",
            to="elon@x.com",
            subject="hi",
            body=Alternatives([PlainText("Hello"), HTMLPart("<h1>Hello</h1>")]))
```

## Receiving mail

```julia
@use "github.com/jkroso/Email.jl/IMAP.jl" connect messages text html @uri_str
@use Dates: Date

connect(uri"imaps://user:app-password@imap.gmail.com:993") do server
  inbox = server["INBOX"]

  for mail in inbox                 # iterate over every message, oldest first
    println(mail.subject)
  end

  println(text(inbox[end]))         # plain text body of the most recent message

  for mail in messages(inbox, since=Date(2026, 6, 1))  # lazily fetch matches
    println(mail)                   # Mail(Jake <jake@gmail.com> → you@x.com: "hi")
  end
end
```

A `Mail` has `from`, `to`, `cc`, `replyto`, `date`, `subject`, `body` and `attachments`.
`text(mail)` and `html(mail)` pull the body out as a `String`, returning `nothing` if
the mail doesn't have a version in that format.

When you want finer control, work with UIDs directly:

```julia
@use "github.com/jkroso/Email.jl/IMAP.jl" search fetchheaders

uids = search(inbox, since=Date(2026, 6, 1))  # or uid_after=1234, defaults to ALL
headers = fetchheaders(inbox, uids[1])        # cheap peek: a Dict of the headers
mail = inbox[uids[1]]                         # full download + parse
```

## Backing up

Save every message as a standard .eml file, one directory per folder
(defaults to `~/Desktop/<username>`):

```julia
@use "github.com/jkroso/Email.jl/IMAP.jl" download @uri_str

download(uri"imaps://user:app-password@imap.gmail.com:993")
```

Individual `Mail`s can also be serialized: `write("mail.eml", mail)`.
