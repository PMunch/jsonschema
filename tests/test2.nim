import sequtils
import json
import options
import "../src/jsonschema"

type E = enum
  a,b,c
jsonSchema:
  A:
    a:E{int} # set
  B:
    b:E{.int.} # specific base type
