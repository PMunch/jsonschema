import sequtils
import json
import unittest
import options
import "../src/jsonschema"

type MarkupKind {.pure.} = enum
  plaintext = 0
  markdown = 1

type CompletionItemKindEnum* {.pure.} = enum
    Text = 1,
    Method = 2,
    Function = 3

jsonSchema:
  A:
    a:CompletionItemKindEnum{int} # set
  B:
    b:MarkupKind{.int.} # specific base type

test "enum basic type annotation":
  var b = create(B,MarkupKind.plaintext)
  check b.JsonNode.isValid(B) == true

test "enum basic type in seq annotation":
  var a = create(A,@[CompletionItemKindEnum.Text,CompletionItemKindEnum.Method])
  check a.JsonNode.isValid(A) == true