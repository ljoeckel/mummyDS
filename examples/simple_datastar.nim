## Minimal "Datastar" (https://data-star.dev/) patchSignals / patchElements example for mummyDS
import ../src/mummy
import ../src/mummy/routers
import ../src/mummy/datastar
import std/[json, options, os, uri, strutils, strformat, times]

var count = 0
# /increment (Close the connection after patchSignals)
proc handleIncrement(request: Request) =
    let sgnl = getSignals(request)
    var info = sgnl["info"].getStr()
    echo fmt"-> '{info}'"

    inc count
    let update = %*{
        "value": count,
        "info": fmt"Click {count}"
    }
    var sse = request.respondSSE(); defer: sse.close()
    patchSignals(sse, update)
  

# /update-clock (Do not close the connection)
proc handleUpdateClock(request: Request) =
  var sse = request.respondSSE()
  while true:
    sleep(1000)
    let tm = $now()
    try:
      patchElements(sse, fmt"<h3 id='clock'>{tm}</h3>")
    except:
      echo "Leaving handleUpdateClock: ", getCurrentExceptionMsg()
      break

# /
proc handleRoot(request: Request) =
  let html = """
<!DOCTYPE html>
<html>
<head data-init="@get('/update-clock')">
    <meta charset="UTF-8">
    <script type="module"
        src="https://cdn.jsdelivr.net/gh/starfederation/datastar@1.0.0-RC.7/bundles/datastar.js"></script>
</head>
<body data-signals="{value: 0, info: ''}">
    <h3 id="clock">2026-01-01T00:00:00+00:00</h3>
    <button type="button" data-text="$value" data-on:click="@get('/increment')"></button>
    <input name="info" placeholder="Click button.." data-bind="info">
</body>
</html>
"""
  request.respond(200, @[("Content-Type", "text/html")], html)

   
when isMainModule:
  let (host, port) = ("192.168.1.159", 8080)

  var router = Router()
  router.get("/", handleRoot)
  router.get("/increment", handleIncrement)
  router.get("/update-clock", handleUpdateClock)

  let server = newServer(router)
  echo fmt"Simple SSE / Datastar server - Open http://{host}:{port} in your browser"
  server.serve(Port(port), host)
