@use "../SMTP.jl" SMTPError readresponse READ_TIMEOUT
@use Test...

# Socket that goes permanently quiet once its scripted chunks run out — eof
# blocks the way a live TLS socket does when the peer just stops talking.
mutable struct QuietSock <: IO
  chunks::Vector{Vector{UInt8}}
  i::Int
  gate::Channel{Nothing}   # never filled: a dry read parks here
end
QuietSock(chunks) = QuietSock(chunks, 1, Channel{Nothing}(1))
Base.unsafe_write(s::QuietSock, p::Ptr{UInt8}, n::UInt) = Int(n)
Base.eof(s::QuietSock) = s.i <= length(s.chunks) ? false : (take!(s.gate); true)
Base.readavailable(s::QuietSock) = (c = s.chunks[s.i]; s.i += 1; c)

# eof=true immediately: the server closed the connection.
struct ClosedSock <: IO end
Base.unsafe_write(::ClosedSock, ::Ptr{UInt8}, n::UInt) = Int(n)
Base.eof(::ClosedSock) = true
Base.readavailable(::ClosedSock) = UInt8[]

@testset "readresponse delivers a healthy reply" begin
  sock = QuietSock([Vector{UInt8}("220 smtp.gmail.com ESMTP ready\r\n")])
  @test readresponse(sock) == "220 smtp.gmail.com ESMTP ready\r\n"
  close(sock.gate)
end

@testset "read timeout: a dry socket throws instead of blocking" begin
  old = READ_TIMEOUT[]
  try
    READ_TIMEOUT[] = 0.2
    # Silence before any reply (server accepts the connection but never answers).
    sock = QuietSock(Vector{UInt8}[])
    secs = @elapsed @test_throws SMTPError readresponse(sock)
    @test secs < 5   # an order of magnitude of headroom over the 0.2s timeout
    close(sock.gate) # release the parked reader task
  finally
    READ_TIMEOUT[] = old
  end
end

@testset "server-closed socket throws SMTPError, not an empty string" begin
  @test_throws SMTPError readresponse(ClosedSock())
  old = READ_TIMEOUT[]
  try
    READ_TIMEOUT[] = 0.0   # timeout disabled must preserve the same error type
    @test_throws SMTPError readresponse(ClosedSock())
  finally
    READ_TIMEOUT[] = old
  end
end

println("smtp_api tests passed")
