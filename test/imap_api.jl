@use "../IMAP.jl" IMAPError _search_cmd _parse_search _fetch_cmd _parse_literal _imap_quote _uid_set _parse_fetch_literals command
@use Dates: Date
@use Test...

@testset "IMAP command builders" begin
  @test _search_cmd(since=Date(2026,6,5)) == "UID SEARCH SINCE 05-Jun-2026"
  @test _search_cmd(before=Date(2026,6,5)) == "UID SEARCH BEFORE 05-Jun-2026"
  @test _search_cmd(since=Date(2026,1,1), before=Date(2026,6,5)) == "UID SEARCH SINCE 01-Jan-2026 BEFORE 05-Jun-2026"
  @test _search_cmd(uid_after=42) == "UID SEARCH UID 43:*"
  @test _fetch_cmd(7; peek=true,  section="HEADER") == "UID FETCH 7 (BODY.PEEK[HEADER])"
  @test _fetch_cmd(7; peek=false, section="HEADER") == "UID FETCH 7 (BODY[HEADER])"
  @test _fetch_cmd(7; peek=true,  section="")       == "UID FETCH 7 (BODY.PEEK[])"
end

@testset "UID sequence-set compression" begin
  @test _uid_set([1,2,3]) == "1:3"
  @test _uid_set([3,1,2,7,10,9]) == "1:3,7,9:10"     # unsorted input
  @test _uid_set([5]) == "5"
  @test _uid_set([5,5,6]) == "5:6"                    # duplicates collapse
  @test _uid_set(Int[]) == ""
end

@testset "parse multi-message FETCH literals" begin
  raw = "* 1 FETCH (UID 7 BODY[HEADER] {12}\r\nHello\r\nWorld)\r\n" *
        "* 2 FETCH (UID 9 BODY[HEADER] {5}\r\nHELLO)\r\n"
  pairs = _parse_fetch_literals(Vector{UInt8}(raw))
  @test length(pairs) == 2
  @test pairs[1] == (7 => Vector{UInt8}("Hello\r\nWorld"))
  @test pairs[2] == (9 => Vector{UInt8}("HELLO"))
  # payload containing a line that LOOKS like a fetch opener must not desync
  tricky = "* 1 FETCH (UID 3 BODY[HEADER] {26}\r\nX: * 9 FETCH (UID 4 {99}\r\n)\r\n"
  p = _parse_fetch_literals(Vector{UInt8}(tricky))
  @test length(p) == 1 && p[1].first == 3
  @test _parse_fetch_literals(Vector{UInt8}("A1 OK\r\n")) == []
end

@testset "parse * SEARCH" begin
  @test _parse_search("* SEARCH 3 7 19\r\nA1 OK done\r\n") == [3, 7, 19]
  @test _parse_search("* SEARCH\r\nA1 OK done\r\n") == Int[]
  @test _parse_search("A1 OK done\r\n") == Int[]
end

@testset "strip IMAP literal off a FETCH" begin
  raw = "* 1 FETCH (UID 7 BODY[HEADER] {12}\r\nHello\r\nWorld)\r\nA1 OK\r\n"
  @test String(_parse_literal(Vector{UInt8}(raw))) == "Hello\r\nWorld"
  lf = "* 1 FETCH (UID 7 BODY[HEADER] {5}\nHELLO)\r\nA1 OK\r\n"
  @test String(_parse_literal(Vector{UInt8}(lf))) == "HELLO"
  @test _parse_literal(Vector{UInt8}("no literal here")) == Vector{UInt8}("no literal here")
end

@testset "IMAPError" begin
  @test IMAPError("boom") isa Exception
end

@testset "LOGIN credential quoting" begin
  @test _imap_quote("app pw") == "\"app pw\""              # space survives
  @test _imap_quote("plain") == "\"plain\""
  @test _imap_quote("a\"b\\c") == "\"a\\\"b\\\\c\""        # escape " and \
end

# Scripted socket: hands the response back in pre-cut chunks, the way TLS
# records arrive off a real server.  eof() turns true once the script runs dry,
# so a command loop that misses its status line dies loudly (AssertionError)
# here instead of blocking forever like it would on a live socket.
mutable struct ChunkedSock <: IO
  make::Function                  # tag::String -> Vector{Vector{UInt8}}
  chunks::Vector{Vector{UInt8}}
  i::Int
end
ChunkedSock(make::Function) = ChunkedSock(make, Vector{UInt8}[], 1)
Base.unsafe_write(s::ChunkedSock, p::Ptr{UInt8}, n::UInt) = begin
  s.chunks = s.make(String(first(split(unsafe_string(p, n)))))
  s.i = 1
  Int(n)
end
Base.eof(s::ChunkedSock) = s.i > length(s.chunks)
Base.readavailable(s::ChunkedSock) = (c = s.chunks[s.i]; s.i += 1; c)

@testset "command: status line split across chunk boundaries" begin
  payload = "* 1 FETCH (UID 7 BODY[] {11}\r\nhello world)\r\n"
  # Cut the full response in two at every byte position.  Gmail can land a TLS
  # record boundary anywhere — including inside "<tag> OK Success\r\n", which
  # used to leave the reader blocked forever waiting for bytes that had already
  # arrived (the field bug: mail scans wedging mid-"Scanning…").
  reference = nothing
  for cut in 1:(length(payload) + 20 - 1)   # tag length varies; cover past the OK line
    sock = ChunkedSock(tag -> begin
      resp = Vector{UInt8}(payload * "$tag OK Success\r\n")
      c = clamp(cut, 1, length(resp) - 1)
      [resp[1:c], resp[c+1:end]]
    end)
    out = IOBuffer()
    command(sock, "UID FETCH 7 (BODY.PEEK[])", out)   # must return, not starve
    got = String(take!(out))
    @test occursin("{11}\r\nhello world", got)
    @test !occursin("OK Success", got)
    reference === nothing && (reference = got)
  end
  # Status line dribbling in across three chunks must also complete.
  sock3 = ChunkedSock(tag -> begin
    resp = Vector{UInt8}(payload * "$tag OK Success\r\n")
    n = length(resp)
    [resp[1:n-12], resp[n-11:n-6], resp[n-5:end]]
  end)
  out3 = IOBuffer()
  command(sock3, "UID FETCH 7 (BODY.PEEK[])", out3)
  @test occursin("hello world", String(take!(out3)))
  # A NO/BAD status must still throw IMAPError even when split mid-line.
  sockbad = ChunkedSock(tag -> begin
    resp = Vector{UInt8}("$tag NO [NONEXISTENT] Unknown Mailbox\r\n")
    [resp[1:3], resp[4:end]]
  end)
  @test_throws IMAPError command(sockbad, "SELECT \"nope\"", IOBuffer())
end
