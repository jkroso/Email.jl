# Timed socket reads, shared by the IMAP and SMTP transports.

# Seconds a single read may stay silent before the connection is declared
# dead.  Healthy responses stream continuously (inter-chunk gaps are
# sub-second even on slow links — bandwidth stretches the transfer, not the
# gaps), so a minute of silence means the peer or network is gone.  Without
# this, a read blocks until the server closes the socket — Gmail takes ~10
# minutes.  A timed-out connection is mid-response and unusable: close it.
# One knob for both protocols.  Set to 0 (or Inf) to disable.
const READ_TIMEOUT = Ref(60.0)

"""
Read the next chunk from `sock`, throwing instead of blocking forever on a
socket that has gone quiet.  `mkerr(msg)::Exception` shapes the failure so
each protocol reports its own error type (`IMAPError`/`SMTPError`).
"""
readchunk(sock, mkerr) = begin
  timeout = READ_TIMEOUT[]
  if !(0 < timeout < Inf)
    eof(sock) && throw(mkerr("connection closed by server"))
    return readavailable(sock)
  end
  # Race the blocking read against a timer.  Size-2 channel: both producers
  # can complete without blocking, whichever loses is dropped with the channel.
  # On timeout the reader task stays parked in eof() until the socket closes —
  # which is fine, because timing out means the caller must close it anyway.
  results = Channel{Any}(2)
  @async try
    put!(results, eof(sock) ? :closed : readavailable(sock))
  catch e
    try put!(results, e) catch end
  end
  timer = Timer(_ -> (try put!(results, :timeout) catch end), timeout)
  result = take!(results)
  close(timer)
  result === :timeout &&
    throw(mkerr("no data for $(timeout)s — connection presumed dead"))
  result === :closed && throw(mkerr("connection closed by server"))
  result isa Exception && throw(result)
  result
end
