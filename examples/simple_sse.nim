## Simple Server-Sent Events (SSE) example for Mummy (copied from mummyx, by Göran Krampe)
## Run with: nim c --threads:on --mm:orc -r examples/simple_sse.nim

import std/times, ../src/mummy, std/os

var sseConnection: SSEConnection

proc handleRequest(request: Request) =
  if request.path == "/events":
    echo "[SSE] New connection from: ", request.remoteAddress

    sseConnection = request.respondSSE()

    # Send initial event
    sseConnection.send(SSEEvent(
      data: """{"message": "Connected to SSE stream", "time": """ & $now() & """""""
    ))

    # Send a few events with delay
    for i in 1 .. 5:
      sleep(1000)
      sseConnection.send(SSEEvent(
        data: """{"count": """ & $i & """, "time": """ & $now() & """""""
      ))

    # Send final event and close
    sleep(1000)
    sseConnection.send(SSEEvent(
      data: """{"message": "Stream complete"}"""
    ))
    close(sseConnection)

  elif request.path == "/":
    request.respond(200, @[
      ("Content-Type", "text/html")
    ], """
<!DOCTYPE html>
<html>
<head>
  <title>Mummy SSE Example</title>
  <style>
    body { font-family: Arial; max-width: 800px; margin: 50px auto; }
    #events { background: #f5f5f5; padding: 20px; border-radius: 5px; }
    .event { margin: 10px 0; padding: 10px; background: white; }
  </style>
</head>
<body>
  <h1>Mummy SSE Example</h1>
  <button onclick="startSSE()">Start SSE Stream</button>
  <div id="events"></div>

  <script>
    function startSSE() {
      const events = document.getElementById('events');
      events.innerHTML = '<p>Connecting...</p>';

      const evtSource = new EventSource('/events');

      evtSource.onmessage = function(e) {
        const eventDiv = document.createElement('div');
        eventDiv.className = 'event';
        eventDiv.textContent = e.data;
        events.appendChild(eventDiv);
      };

      evtSource.onerror = function() {
        events.innerHTML += '<p>Connection closed</p>';
        evtSource.close();
      };
    }
  </script>
</body>
</html>
""")

  else:
    request.respond(404)

when isMainModule:
  let server = newServer(handleRequest)
  echo "SSE Example Server running on http://localhost:8080"
  echo "Open http://localhost:8080 in your browser"
  server.serve(Port(8080))
