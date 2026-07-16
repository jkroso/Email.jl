@use "github.com/jkroso/URI.jl" URI decode
@use "./types.jl" Mail Attachment PlainText HTMLPart BinaryPart Alternatives Part Contact text html CRLF
@use "./read.jl" READ_TIMEOUT readchunk
@use Sockets: connect, TCPSocket
@use Base64: base64encode
@use OpenSSL

struct SMTPError <: Exception
  msg::String
end
Base.showerror(io::IO, e::SMTPError) = print(io, "SMTPError: ", e.msg)

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

"Connect, run `f(server)`, and always close the connection afterwards"
connect(f::Function, uri::Union{URI{:smtp},URI{:smtps}}) = begin
  server = connect(uri)
  try f(server) finally close(server) end
end

hello(s::SMTPServer) = begin
  @assert startswith(readresponse(s.sock), "220")
  write(s.sock, "EHLO $(s.uri.host)\r\n")
  @assert startswith(readresponse(s.sock), "250")
  haslogin(s.uri) && login(s, s.uri.username, s.uri.password)
  s
end

# Timed read (read.jl): a silent socket throws SMTPError after READ_TIMEOUT
# instead of blocking in eof() until the server closes the connection.  SMTP
# replies are single short lines, so any silence beyond the timeout means the
# peer or network is gone.
readresponse(sock) = String(readchunk(sock, SMTPError))

haslogin(uri::URI) = !isempty(uri.username) && !isempty(uri.password)

login((;sock)::SMTPServer, id, password) = begin
  write(sock, "AUTH PLAIN $(base64encode("\0$id\0$password"))\r\n")
  @assert startswith(readresponse(sock), "235")
end

Base.write((;sock)::SMTPServer, msg::Mail) = begin
  write(sock, "MAIL FROM:<$(msg.from.email)>\r\n")
  @assert startswith(readresponse(sock), "250")
  for c in [msg.to, msg.cc...]
    write(sock, "RCPT TO:<$(c.email)>\r\n")
    @assert startswith(readresponse(sock), "250")
  end
  write(sock, "DATA\r\n")
  @assert startswith(readresponse(sock), "354")
  write(sock, msg)
  write(sock, ".$CRLF") # SSLStream has no byte I/O, so the terminator must be one String write not write(sock, '.', CRLF)
  @assert startswith(readresponse(sock), "250")
end

Base.close((;sock)::SMTPServer) = begin
  isopen(sock) || return
  try write(sock, "QUIT\r\n") catch end # best-effort: don't wait for the 221, mid-DATA the server won't ack and we'd hang
  close(sock)
end

"""
Send one or more `Mail`s. Opens a connection, sends, and closes it again:

    send(uri"smtps://user:pass@smtp.gmail.com:465", mail)

Or send over an already open connection:

    connect(uri) do server
      send(server, mail)
    end

For one-off mails you can skip constructing the `Mail` yourself and pass
its fields as keyword arguments:

    send(uri, from="Jake <jake@gmail.com>", to="elon@x.com", subject="hi", body="...")
"""
send(uri::URI, mails::Mail...) = connect(server->send(server, mails...), uri)
send(uri::URI; kw...) = send(uri, Mail(;kw...))
send(server::SMTPServer, mails::Mail...) = foreach(m->write(server, m), mails)
