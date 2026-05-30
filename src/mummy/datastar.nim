import ../mummy
import std/[json, strutils, uri, strformat, options, os, paths, tables]
import mimetypes
import yottadb

type
  EventType* = enum
    PatchElements = "datastar-patch-elements"
    PatchSignals = "datastar-patch-signals"

type
  ElementPatchMode* = enum
    Outer = "outer"
    Inner = "inner"
    Replace = "replace"
    Prepend = "prepend"
    Append = "append"
    Before = "before"
    After = "after"
    Remove = "remove"


template SSE*(req: Request, body: untyped) =
    var sse {.inject.} = req.respondSSE() # sse for body
    defer: sse.close()
    body


proc isNsBindingAborted(sse: SSEConnection): bool =
  # Remove a disconnected clientId entry from the list
  let idx = sse.server.nsBindingAborted.find(sse.clientId)
  if idx != -1:
    sse.server.nsBindingAborted.delete(idx)
    result = true


proc getSignals*(req: Request): JsonNode =
  var signals: string
  if req.httpMethod == "POST":
    signals = $req.body
  else:
    if req.uri.contains("?datastar="): # Datastar request
      let encodedValue = req.uri.split('=')[1]
      signals = decodeUrl(encodedValue)
    elif req.uri.contains("?"): # parameter(s) from GET request
      signals = "{"
      let encodedValue = req.uri.split('?')[1]
      if encodedValue.contains('&'):
        for param in encodedValue.split('&'): # multiple params
          let subs = param.split('=')
          signals.add(fmt""" "{subs[0]}": "{subs[1]}", """)
      else: # single param
        let subs = encodedValue.split('=')
        signals.add(fmt""" "{subs[0]}": "{subs[1]}" """)
      signals.add("}")
    else:
      signals = "{}"
  result = parseJson(signals) # convert to json

proc getSignals*(sse: SSEConnection): JsonNode =
  getSignals(sse.request)

proc getSignal(sse: SSEConnection, name: string): string =
    let signals = getSignals(sse)
    if signals.contains(name):
        return $signals[name]


proc rawSend(sse: SSEConnection, evttype: EventType, lines:seq[string], eventId="", retryDuration=0) =
    var evt: SSEEvent
    evt.event = some($evttype)
    if eventId.len > 0: evt.id = some(eventId)
    if retryDuration > 0: evt.retry = some(retryDuration)

    for i in 0..<lines.len:
        evt.data.add(lines[i])
        if i < lines.len-1: evt.data.add('\n')

    sse.send(evt)


# Datastar 'patchSignals'
proc patchSignals*(sse: SSEConnection, signals: JsonNode, onlyIfMissing=false, eventId="", retryDuration=0) {.raises: [MummyError].} =
  # Check if a client was prior disconnected (Tab closed, Browser closed, etc.)
  # Then raise exception that the client-program can cleanup
  if isNsBindingAborted(sse): raise newException(MummyError, fmt"NS_BINDING_ABORTED for clientId:{sse.clientId}")

  var data: seq[string]
  if onlyIfMissing: data.add("onlyIfMissing true")
  data.add("signals " & strip($signals))
  rawSend(sse, PatchSignals, data, eventId, retryDuration)


# Datastar 'patchElements'
proc patchElements*(sse: SSEConnection, elements: string, selector="", mode=Outer, useViewTransition=false, eventId="", retryDuration=0) {.raises: [MummyError].} =
  if isNsBindingAborted(sse): raise newException(MummyError, fmt"NS_BINDING_ABORTED for clientId:{sse.clientId}")

  var lines: seq[string]
  if mode == Remove and elements.len == 0:
    # Special ordering for remove mode without elements
    if useViewTransition:
      # With useViewTransition: selector, mode, useViewTransition
      lines.add("selector " & selector)
      lines.add("mode " & $mode)
      lines.add("useViewTransition true")
    else:
      # Without useViewTransition: mode, selector
      lines.add("mode " & $mode)
      lines.add("selector " & selector)
  else:
    # Standard ordering: selector, mode, useViewTransition, elements
    if selector.len > 0: lines.add("selector " & selector)
    if mode != Outer: lines.add("mode " & $mode)
    if useViewTransition: lines.add("useViewTransition true")
    # Split multiline elements into separate data lines
    for elementLine in elements.split('\n'):
      let line = strip(elementLine)
      if line.len > 0:
        lines.add("elements " & strip(elementLine))

  rawSend(sse, PatchElements, lines, eventId, retryDuration)


proc executeScript*(sse: SSEConnection, script: string, autoRemove=true, attributes=initTable[string, string](), eventId="", retryDuration=0) =
  ## Execute a script by generating a <script> tag and using patchElements
  ## Order for executeScript: mode, selector, elements
  var scriptTag = "<script"
  for key, val in attributes:
    scriptTag.add " " & key & "=\"" & val & "\""
  if autoRemove:
    scriptTag.add " data-effect=\"el.remove()\""
  scriptTag.add ">" & script & "</script>"

  # executeScript always uses mode=append, selector=body with specific order
  var lines: seq[string]
  lines.add("mode " & $Append)
  lines.add("selector body")
  for elementLine in scriptTag.split('\n'):
    lines.add("elements " & elementLine)
  
  rawSend(sse, PatchElements, lines, eventId, retryDuration)


# Forward to another page
proc forward*(sse: SSEConnection, url: string) =
    try:
      let data = readFile(url)
      patchElements(sse, data)
    except:
      echo(fmt"[mummyDS/datastar] IOError: {url} not found")

proc forward*(req: Request, url: string) =
    var sse = req.respondSSE() # sse for body
    defer: sse.close()
    forward(sse, url)

# Serve static resources (html, css, etc.
proc serveStatic*(request: Request) {.gcsafe.} =
    var (dir, fn, ext) = request.path.splitFile()
    if fn.len == 0 and dir == "/": 
        fn = "index"
        ext = ".html"
    let path = Path(fmt"html/{fn}{ext}")
    try:
        let data = readFile($path)
        request.respond(200, @[("Content-Type", getMimeType(ext))], data)
    except:
        if not ext.isEmptyOrWhitespace:
            echo(fmt"[mummyDS/datastar:169] 404 {path} not found")
            request.respond(404, @[("Content-Type", "text/html")], fmt"<h1>File '{path}' not found</h1>")
        else:
            echo(fmt"[mummyDS/datastar:172] 404 {path} (Token missmatch?)")
            let data = readFile("html/login.html")
            request.respond(200, @[("Content-Type", "text/html")], data)
