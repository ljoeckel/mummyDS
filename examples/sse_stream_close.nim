# Minimal headless SSE demo: POST /stream streams 2 integers in JSON then closes (copied from mummyx, by Jory Schossau)
import ../src/mummy, ../src/mummy/routers
import std/[times, options, os]

proc handleStream(req: Request) {.gcsafe.} =
  if req.httpMethod != "POST":
    req.respond(405, @[ ("Content-Type", "text/plain") ], "Method Not Allowed\n")
    return

  var connection = req.respondSSE()
  for i in 1..2:
    let payload = "{\"n\": " & $i & "}"
    connection.send(SSEEvent(
      event: none(string),
      data: $payload,
      id: none(string)
    ))
    sleep(600)
  connection.close()

proc main() =
  var router = Router()
  router.post("/stream", handleStream)
  let server = newServer(router)
  echo "POST /stream for SSE events at http://localhost:8080"
  server.serve(Port(8080))

when isMainModule:
  main()
