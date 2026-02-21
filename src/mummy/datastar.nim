import ../mummy
import std/[json, strutils, uri, strformat, options]
#import mimetypes


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
    let encodedValue = req.uri.split('=')[1]
    signals = decodeUrl(encodedValue)
    result = parseJson(signals)

# Datastar 'patchSignals'
proc patchSignals*(sse: SSEConnection, signals: JsonNode, onlyIfMissing=false,  eventId="", retryDuration=0) {.raises: [MummyError].} =
  if isNsBindingAborted(sse): raise newException(MummyError, fmt"NS_BINDING_ABORTED for clientId:{sse.clientId}")

  var data: string
  if onlyIfMissing: data.add("onlyIfMissing true\n")
  data.add("signals " & $signals & "\n")

  var evt: SSEEvent
  evt.event = some("datastar-patch-signals")
  if eventId.len > 0: evt.id = some(eventId)
  if retryDuration > 0: evt.retry = some(retryDuration)
  evt.data = data
  sse.send(evt)


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

  var data: string
  for line in lines:
    data.add(line & "\n")

  var evt: SSEEvent
  evt.event = some("datastar-patch-elements")
  if eventId.len > 0: evt.id = some(eventId)
  if retryDuration > 0: evt.retry = some(retryDuration)
  evt.data = data
  sse.send(evt)


# proc executeScript*(request: Request, script: string) =
#     var sse = request.respondSSE(); defer: sse.close()
#     sse.executeScript(script)

# # Reload /
# proc reload*(request: Request) {.async.} =
#     executeScript(request, "window.location.reload()")

# # Forward to another page
# proc forward*(request: Request, url: string) =
#     let data = readFile(url)
#     patchElements(request, data)


# # Serve static resources (html, css, etc.
# proc serveStatic*(request: Request, file: string, ext: string) =
#     let path = Path("html/" & file & ext)
#     try:
#         let data = readFile($path)
#         request.respond(Http200, data, newHttpHeaders([("Content-Type", getMimeType(ext))]))
#     except:
#         request.respond(Http404, "<h1>File '" & $path & "' not found</h1>", newHttpHeaders([("Content-Type", "text/html")]))