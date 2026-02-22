import ../mummy
import std/[json, strutils, uri, strformat, options, os, paths, tables]
import mimetypes

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


proc isNsBindingAborted(sse: SSEConnection): bool =
  let idx = sse.server.nsBindingAborted.find(sse.clientId)
  if idx != -1:
    sse.server.nsBindingAborted.delete(idx)
    result = true


proc getSignals*(req: Request): JsonNode =
    var signals: string
    
    if req.httpMethod == "POST":
      signals = $req.body
    else:
      let encodedValue = req.uri.split('=')[1]
      signals = decodeUrl(encodedValue)

    result = parseJson(signals)


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
proc patchSignals*(sse: SSEConnection, signals: JsonNode, onlyIfMissing=false,  eventId="", retryDuration=0) {.raises: [MummyError].} =
  if isNsBindingAborted(sse): raise newException(MummyError, fmt"NS_BINDING_ABORTED for clientId:{sse.clientId}")

  var data: seq[string]
  if onlyIfMissing: data.add("onlyIfMissing true\n")
  data.add("signals " & $signals & "\n")

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
      lines.add("elements " & elementLine)

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
    let data = readFile(url)
    echo "forward: url:", url, " data:", data
    patchElements(sse, data)


# Serve static resources (html, css, etc.
proc serveStatic*(request: Request) {.gcsafe.} = #, file: string, ext: string) =
    var (dir, fn, ext) = request.path.splitFile()
    if fn.len == 0 and dir == "/": 
        fn = "index"
        ext = ".html"
    let path = Path("html/" & $fn & $ext)
    try:
        let data = readFile($path)
        request.respond(200, @[("Content-Type", getMimeType(ext))], data)
    except:
        request.respond(404, @[("Content-Type", "text/html")], "<h1>File '" & $path & "' not found</h1>")
