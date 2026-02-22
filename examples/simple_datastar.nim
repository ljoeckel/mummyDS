## Minimal "Datastar" (https://data-star.dev/) patchSignals / patchElements example for mummyDS
import ../src/mummy
import ../src/mummy/routers
import ../src/mummy/datastar
import std/[json, options, os, strutils, strformat, times]

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
    let tm = $now()
    try:
      patchElements(sse, fmt"<h3 id='clock'>{tm}</h3>")
    except:
      echo "Leaving handleUpdateClock: ", getCurrentExceptionMsg()
      break
    sleep(1000)


proc handleRunScript(request: Request) =
    var sse = request.respondSSE(); defer: sse.close()
    executeScript(sse, fmt"console.log('Script erfolgreich von Nim ausgeführt!'); alert('Hallo von Nim after {count} clicks!');")


# Look at html/index.html
when isMainModule:
  let (host, port) = ("192.168.1.159", 8080)
  var router = Router()
  router.get("/increment", handleIncrement)
  router.get("/update-clock", handleUpdateClock)
  router.get("/run-script", handleRunScript)
  router.notFoundHandler = serveStatic

  let server = newServer(router)
  echo fmt"Simple SSE / Datastar server - Open http://{host}:{port} in your browser"
  server.serve(Port(port), host)
