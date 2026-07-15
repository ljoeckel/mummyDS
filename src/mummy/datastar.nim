import ../mummy
import std/[json, strutils, uri, strformat, options, os, paths, tables, enumerate]
import mimetypes
import yottadb

proc trim(s: string): string =
    # remove all leading, trailing and double spaces from a string " abc  def " -> "abc def"
    result = strip(s).replace("\n", "")
    var idx = result.find("  ")
    while idx > 0:
        result = result.replace("  ", " ")
        idx = result.find("  ")
   

type
    Context* = object
        userid*: string

# -- Context Getter --
proc getStr*(userid: string, key: string): string =
    Get ^Session(userid, key)

proc getStr*(unused: Context, userid: string, key: string): string =
# Allow access to another context getStr("rsscollector", "info")
    Get ^Session(userid, key)

proc getStr*(ctx: Context, key: string): string =
    getStr(ctx.userid, key)


proc getInt*(userid: string, key: string): int =
    Get ^Session(userid, key).int

proc getInt*(unused: Context, userid: string, key: string): int =
# Allow access to another context getInt("rsscollector", "lastRun")
    getInt(userid, key)

proc getInt*(ctx: Context, key: string): int =
    getInt(ctx.userid, key)


proc getFloat*(userid: string, key: string): float =
    Get ^Session(userid, key).float

proc getFloat*(unused: Context, userid: string, key: string): float =
    Get ^Session(userid, key).float

proc getFloat*(ctx: Context, key: string): float =
    getFloat(ctx.userid, key)


proc getBool*(unused: Context, userid: string, key: string): bool =
    Get ^Session(userid, key).bool

proc getBool*(userid: string, key: string): bool =
    Get ^Session(userid, key).bool

proc getBool*(ctx: Context, key: string): bool =
    getBool(ctx.userid, key)

proc getSeq*(ctx: Context, key: string, T: type = string): seq[T] =
#[Must be called as 'getSeq[string](ctx, "subscripts_low")'
In HTML:
data-signals="{
   mnemonics: ['GET', 'SET', 'ORD'],
   ints: [1,2,3],
   floats: [1.1, 2.2, 3.3],
   bools: [true, false, false], 
]#
    for k in QueryItr ^Session(ctx.userid, key).keys:
        if k[1] == key:
            when T is string:
                result.add(Get ^Session(k))
            elif T is int:
                result.add(Get ^Session(k).int)
            elif T is float:                
                result.add(Get ^Session(k).float)
            elif T is bool:
                result.add(Get ^Session(k).bool)
            else:
                echo "ERROR: Type ", T, " not supported in toSeq"
        else:
            break


proc getJson*(ctx: Context, key: string): JsonNode =
    let str = Get ^Session(ctx.userid, key)
    try:
        result = parseJson(str)
    except:
        result = parseJson("{}")


proc save*[T](ctx: Context, key: string, value: T) =
    when T is seq:
        Kill ^Session(ctx.userid, key)
        for idx in 0..<value.len:
            Set: ^Session(ctx.userid, key, idx) = $value[idx]
    else:
        Set: ^Session(ctx.userid, key) = $value

proc isAdmin*(ctx: Context): bool =
    ctx.userid == "admin"

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


func stripSignal*(signal: string): string =
    result = strip(signal)
    if result.startsWith("\"") and result.endsWith("\""): # Remove "xxxx" -> xxxx
        result = result[1..^2]


proc isNsBindingAborted(sse: SSEConnection): bool =
  # Remove a disconnected clientId entry from the list
  let idx = sse.server.nsBindingAborted.find(sse.clientId)
  if idx != -1:
    sse.server.nsBindingAborted.delete(idx)
    result = true


proc syncSignalsToDb*(signals: JsonNode) =
    let userid = if "userid" in signals: signals["userid"].getStr() else: ""
    if userid.isEmptyOrWhitespace:
        return

    for (name, value) in signals.pairs:
        case value.kind
        of JArray:
            for (idx, node) in enumerate(value):
                let val = stripSignal($node)
                if val != Get ^Session(userid, name, idx):
                    Set: ^Session(userid, name, idx) = val
        else:
            let val = stripSignal($value)
            if val != Get ^Session(userid, name):
                Set: ^Session(userid, name) = val


proc getSignals*(req: Request): JsonNode =
  var signals: string
  try:
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
              if subs.len > 1:
                signals.add(fmt""" "{subs[0]}": "{subs[1]}", """)
              else:
                echo "ERROR: Malformed signal: ", subs
          else: # single param
            let subs = encodedValue.split('=')
            if subs.len > 1:
                signals.add(fmt""" "{subs[0]}": "{subs[1]}" """)
            else:
                echo "ERROR: Malformed signal: ", subs
          signals.add("}")
        else:
          signals = "{}"
  except:
    echo "ERROR getting signals: signals=", $signals
    echo "Exception: ", getCurrentExceptionMsg()
    signals = "{}"

  result = parseJson(signals) # convert to json


proc getContext*(req: Request): Context =
    let signals = getSignals(req)
    if "userid" in signals:
        result.userid = signals["userid"].getStr()

proc getContext*(sse: SSEConnection): Context =
    getContext(sse.request)


proc rawSend(sse: SSEConnection, evttype: EventType, lines:seq[string], eventId="", retryDuration=0) {.raises: [MummyError].} =
    var evt: SSEEvent
    evt.event = some($evttype)
    if eventId.len > 0: evt.id = some(eventId)
    if retryDuration > 0: evt.retry = some(retryDuration)

    for i in 0..<lines.len:
        evt.data.add(lines[i])
        if i < lines.len-1: evt.data.add('\n')

    try:
        sse.send(evt)
    except:
        raise newException(MummyError, fmt"{getCurrentExceptionMsg()} for clientId:{sse.clientId}")


# Datastar 'patchSignals'
proc patchSignals*(sse: SSEConnection, signals: JsonNode, onlyIfMissing=false, eventId="", retryDuration=0) {.raises: [MummyError, KeyError, TpRestart, TpRollback, YdbError].} =
  # Check if a client was prior disconnected (Tab closed, Browser closed, etc.)
  # Then raise exception that the client-program can cleanup
  if isNsBindingAborted(sse): raise newException(MummyError, fmt"NS_BINDING_ABORTED for clientId:{sse.clientId}")

  var data: seq[string]
  if onlyIfMissing: data.add("onlyIfMissing true")
  data.add("signals " & strip($signals))
  rawSend(sse, PatchSignals, data, eventId, retryDuration)
  var userid: string
  try:
    syncSignalsToDb(signals)
  except:
    echo "ERROR: Could not parse userid"
    

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
    #let ln = elements.replace("\n", "")
    lines.add("elements " & trim(elements))
    # for elementLine in elements.split('\n'):
    #   let line = strip(elementLine)
    #   if line.len > 0:
    #     lines.add("elements " & strip(elementLine))

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
      patchElements(sse, data, mode=Replace)
    except:
      echo(fmt"[mummyDS/datastar:forward] IOError: {url} not found")

proc forward*(req: Request, url: string) =
    var sse = req.respondSSE() # sse for body
    defer: sse.close()
    forward(sse, url)


# Serve static resources (html, css, etc.
proc serveStatic*(request: Request) {.gcsafe.} =
    var (dir, fn, ext) = request.path.splitFile()
    if dir.startsWith("/"):
        if fn.len == 0:  # /
            (fn, ext) = ("index", ".html")        
        elif ext.len == 0:
            forward(request, fmt"{dir}/{fn}")  # /api/list-globals
           
    
    let path = Path(fmt"html/{fn}{ext}")
    try:
        let data = readFile($path)
        request.respond(200, @[("Content-Type", getMimeType(ext))], data)
    except:
        if not ext.isEmptyOrWhitespace:
            echo(fmt"[mummyDS/datastar:serveStatic.319] 404 {path} not found")
            request.respond(404, @[("Content-Type", "text/html")], fmt"<h1>File '{path}' not found</h1>")
        else:
            echo(fmt"[mummyDS/datastar:serveStatic.322] 404 {path} (Token missmatch?)")
            let data = readFile("html/login.html")
            request.respond(200, @[("Content-Type", "text/html")], data)
