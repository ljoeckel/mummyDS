#when (NimMajor, NimMinor, NimPatch) < (2, 0, 0):
--threads:on
--mm:orc
--passL:"-L/usr/local/lib/yottadb/r206 -lyottadb"
# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
