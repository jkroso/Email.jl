@use "github.com/jkroso/Prospects.jl" @field_str
@use "github.com/jkroso/URI.jl" URI decode
@use "./types.jl" Mail Attachment PlainText BinaryPart Part
@use Dates: format, @dateformat_str
@use MIMEs: contenttype_from_mime
@use Sockets: connect, TCPSocket
@use Base64: base64encode
@use OpenSSL
@use DotEnv

const zdt = dateformat"e, dd u yyyy HH:MM:SS zzzz"
const boundary = string(rand(UInt128), base=62)
const env = DotEnv.config()
const CRLF = "\r\n"

mutable struct SMTPServer
  uri::URI
  sock::Union{OpenSSL.SSLStream, TCPSocket}
end

connect(uri::URI{:smtp}) = hello(SMTPServer(uri, connect(uri.host, uri.port)))

connect(uri::URI{:smtps}) = begin
  (;host,port) = uri
  sock = OpenSSL.SSLStream(connect(host, port))
  OpenSSL.hostname!(sock, host)
  OpenSSL.connect(sock)
  hello(SMTPServer(uri, sock))
end

hello(s::SMTPServer) = begin
  @assert startswith(readresponse(s.sock), "220")
  write(s.sock, "EHLO $(s.uri.host)\r\n")
  @assert startswith(readresponse(s.sock), "250")
  haslogin(s.uri) && login(s, s.uri.username, s.uri.password)
  s
end

readresponse(ctx) = eof(ctx) ? "" : String(readavailable(ctx))

haslogin(uri::URI) = !isempty(uri.username) && !isempty(uri.password)

login((;sock)::SMTPServer, id=env["EMAIL_ID"], password=env["EMAIL_PASS"]) = begin
  write(sock, "AUTH PLAIN $(base64encode("\0$id\0$password"))\r\n")
  @assert startswith(readresponse(sock), "235")
end

Base.isempty(part::PlainText) = isempty(part.object)
Base.write((;sock)::SMTPServer, part::PlainText) = write(sock, part.object)
Base.write((;sock)::SMTPServer, msg::Mail) = begin
  write(sock, "MAIL FROM:<$(msg.from.email)>\r\n")
  @assert startswith(readresponse(sock), "250")
  for c in [msg.to, msg.cc...]
    write(sock, "RCPT TO:<$(c.email)>\r\n")
    @assert startswith(readresponse(sock), "250")
  end
  write(sock, "DATA\r\n")
  @assert startswith(readresponse(sock), "354")
  write(sock, """
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
    write(sock, '.', CRLF)
  else
    write(sock, "Content-Type: multipart/mixed; boundary=\"$boundary\"\r\n\r\n")
    attachments = isempty(msg.body) ? msg.attachments : [msg.body, msg.attachments...]
    for a in attachments
      write(sock, "--$boundary$CRLF")
      write_attachment(sock, a)
    end
    write(sock, "--$boundary--$CRLF.$CRLF")
  end
  @assert startswith(readresponse(sock), "250")
end

write_attachment(sock, a::PlainText) = begin
  write(sock, "Content-Type: text/plain; charset=UTF-8\r\n")
  write(sock, "Content-Disposition: inline\r\n\r\n")
  write(sock, a.object)
  write(sock, "\r\n")
end

write_attachment(sock, a::BinaryPart) = begin
  write(sock, "Content-Type: $(contenttype_from_mime(a.mime))\r\n")
  write(sock, "Content-Transfer-Encoding: base64\r\n\r\n")
  writefolded(sock, base64encode(a.object))
  write(sock, "\r\n")
end

write_attachment(sock, a::Attachment) = begin
  write(sock, "Content-Disposition: attachment; filename=\"$(a.name)\"\r\n")
  write_attachment(sock, a.part)
end

"email's have a soft line limit of 78"
writefolded(io, data, sizelimit=78) = begin
  range = 1:sizelimit:length(data)
  start = 1
  for i in 2:length(range)
    stop = range[i]
    write(io, @view(data[start:stop]), CRLF)
    start = stop+1
  end
  write(io, @view(data[start:length(data)]), CRLF)
end

Base.close((;sock)::SMTPServer) = begin
  isopen(sock) || return
  write(sock, "QUIT\r\n")
  @assert startswith(readresponse(sock), "221")
  close(sock)
end

send(uri::URI, email::Mail) = begin
  server = connect(uri)
  try
    write(server, email)
  finally
    close(server)
  end
end
