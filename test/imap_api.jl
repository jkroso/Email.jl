@use "../IMAP.jl" IMAPError _search_cmd _parse_search _fetch_cmd _parse_literal _imap_quote _uid_set _parse_fetch_literals
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
