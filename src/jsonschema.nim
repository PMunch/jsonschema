import macros
import ast_pattern_matching
import json
import sequtils
import options
import strutils
import tables

const ManglePrefix {.strdefine.}: string = "the"

type NilType* = enum Nil

proc extractKinds(node: NimNode): seq[tuple[name: string, isArray: bool]] =
  if node.kind == nnkIdent:
    return @[(name: $node, isArray: false)]
  elif node.kind == nnkInfix and node[0].kind == nnkIdent and $node[0] == "or":
    result = node[2].extractKinds
    result.insert(node[1].extractKinds)
  elif node.kind == nnkBracketExpr and node[0].kind == nnkIdent:
    return @[(name: $node[0], isArray: true)]
  elif node.kind == nnkNilLit:
    return @[(name: "nil", isArray: false)]
  elif node.kind == nnkBracketExpr and node[0].kind == nnkNilLit:
    raise newException(AssertionError, "Array of nils not allowed")
  else:
    raise newException(AssertionError, "Unknown node kind: " & $node.kind)

proc matchDefinition(pattern: NimNode):
  tuple[
    name: string,
    kinds: seq[tuple[name: string, isArray: bool]],
    optional: bool,
    mangle: bool
  ] {.compileTime.} =
  matchAst(pattern):
  of nnkCall(
    `name` @ nnkIdent,
    nnkStmtList(
      `kind`
    )
  ):
    return (
      name: $name,
      kinds: kind.extractKinds,
      optional: false,
      mangle: false
    )
  of nnkInfix(
    ident"?:",
    `name` @ nnkIdent,
    `kind`
  ):
    return (
      name: $name,
      kinds: kind.extractKinds,
      optional: true,
      mangle: false
    )
  of nnkCall(
    `name` @ nnkStrLit,
    nnkStmtList(
      `kind`
    )
  ):
    return (
      name: $name,
      kinds: kind.extractKinds,
      optional: false,
      mangle: true
    )
  of nnkInfix(
    ident"?:",
    `name` @ nnkStrLit,
    `kind`
  ):
    return (
      name: $name,
      kinds: kind.extractKinds,
      optional: true,
      mangle: true
    )

proc matchDefinitions(definitions: NimNode):
  seq[
    tuple[
      name: string,
      kinds: seq[
        tuple[
          name: string,
          isArray: bool
        ]
      ],
      optional: bool,
      mangle: bool
    ]
  ] {.compileTime.} =
  result = @[]
  for definition in definitions:
    result.add matchDefinition(definition)

macro jsonSchema*(pattern: untyped): untyped =
  var types: seq[
    tuple[
      name: string,
      extends: string,
      definitions:seq[
        tuple[
          name: string,
          kinds: seq[
            tuple[
              name: string,
              isArray: bool
            ]
          ],
          optional: bool,
          mangle: bool
        ]
      ]
    ]
  ] = @[]
  for part in pattern:
    matchAst(part):
    of nnkCall(
      `objectName` @ nnkIdent,
      `definitions` @ nnkStmtList
    ):
      let defs = definitions.matchDefinitions
      types.add (name: $objectName, extends: "", definitions: defs)
    of nnkCommand(
      `objectName` @ nnkIdent,
      nnkCommand(
        ident"extends",
        `extends` @ nnkIdent
      ),
      `definitions` @ nnkStmtList
    ):
      let defs = definitions.matchDefinitions
      types.add (name: $objectName, extends: $extends, definitions: defs)

  var
    typeDefinitions = newStmtList()
    validationBodies = initOrderedTable[string, NimNode]()
    creatorBodies = initOrderedTable[string, NimNode]()
    createArgs  = initOrderedTable[string, NimNode]()
  let
    data = newIdentNode("data")
    fields = newIdentNode("fields")
    traverse = newIdentNode("traverse")
    ret = newIdentNode("ret")
  for t in types:
    let
      name = newIdentNode(t.name)
      objname = newIdentNode(t.name & "Obj")
    creatorBodies[t.name] = newStmtList()
    typeDefinitions.add quote do:
      type
        `objname` = distinct JsonNodeObj
        `name` = ref `objname`
      converter toJsonNode(input: `name`): JsonNode = input.JsonNode

    var
      requiredFields = 0
      validations = newStmtList()
    createArgs[t.name] = nnkFormalParams.newTree(name)
    for field in t.definitions:
      let
        fname = field.name
        aname = if field.mangle: newIdentNode(ManglePrefix & field.name) else: newIdentNode(field.name)
        cname = quote do:
          `data`[`fname`]
      var
        checks: seq[NimNode] = @[]
        argumentChoices: seq[NimNode] = @[]
      for kind in field.kinds:
        let
          tKind = if kind.name == "any":
              if kind.isArray:
                nnkBracketExpr.newTree(
                  newIdentNode("seq"),
                  newIdentNode("JsonNode")
                )
              else:
                newIdentNode("JsonNode")
            elif kind.isArray:
              nnkBracketExpr.newTree(
                newIdentNode("seq"),
                newIdentNode(kind.name)
              )
            else:
              newIdentNode(kind.name)
          isBaseType = kind.name.toLowerASCII in
            ["int", "string", "float", "bool"]
        if kind.name != "nil":
          if kind.isArray:
            if argumentChoices.len == 0:
              argumentChoices.add tkind
          else:
            argumentChoices.add tkind
        else:
          argumentChoices.add newIdentNode("NilType")
        if isBaseType:
          let
            jkind = newIdentNode("J" & kind.name)
          if kind.isArray:
            checks.add quote do:
              `cname`.kind != JArray or `cname`.anyIt(it.kind != `jkind`)
          else:
            checks.add quote do:
              `cname`.kind != `jkind`
        elif kind.name == "any":
          if kind.isArray:
            checks.add quote do:
              `cname`.kind != JArray
          else:
            checks.add newLit(false)
        elif kind.name == "nil":
          checks.add quote do:
            `cname`.kind != JNull
        else:
          let kindNode = newIdentNode(kind.name)
          if kind.isArray:
            checks.add quote do:
              `cname`.kind != JArray or
                (`traverse` and not `cname`.allIt(it.isValid(`kindNode`)))
          else:
            checks.add quote do:
              (`traverse` and not `cname`.isValid(`kindNode`))
        if kind.name == "nil":
          if field.optional:
            creatorBodies[t.name].add quote do:
              when `aname` is Option[NilType]:
                if `aname`.isSome:
                  `ret`[`fname`] = newJNull()
          else:
            creatorBodies[t.name].add quote do:
              when `aname` is NilType:
                `ret`[`fname`] = newJNull()
        elif kind.isArray:
          let
            i = newIdentNode("i")
            accs = if isBaseType:
                quote do:
                  %`i`
              else:
                quote do:
                  `i`.JsonNode
          if field.optional:
            creatorBodies[t.name].add quote do:
              when `aname` is Option[`tkind`]:
                if `aname`.isSome:
                  `ret`[`fname`] = newJArray()
                  for `i` in `aname`.unsafeGet:
                    `ret`[`fname`].add `accs`
          else:
            creatorBodies[t.name].add quote do:
              when `aname` is `tkind`:
                `ret`[`fname`] = newJArray()
                for `i` in `aname`:
                  `ret`[`fname`].add `accs`
        else:
          if field.optional:
            let accs = if isBaseType:
                quote do:
                  %`aname`.unsafeGet
              else:
                quote do:
                  `aname`.unsafeGet.JsonNode
            creatorBodies[t.name].add quote do:
              when `aname` is Option[`tkind`]:
                if `aname`.isSome:
                  `ret`[`fname`] = `accs`
          else:
            let accs = if isBaseType:
                quote do:
                  %`aname`
              else:
                quote do:
                  `aname`.JsonNode
            creatorBodies[t.name].add quote do:
              when `aname` is `tkind`:
                `ret`[`fname`] = `accs`
      while checks.len != 1:
        let newFirst = nnkInfix.newTree(
          newIdentNode("and"),
          checks[0],
          checks[1]
        )
        checks = checks[2..^1]
        checks.insert(newFirst)
      if field.optional:
        argumentChoices[0] = nnkBracketExpr.newTree(
            newIdentNode("Option"),
            argumentChoices[0]
          )
      while argumentChoices.len != 1:
        let newFirst = nnkInfix.newTree(
          newIdentNode("or"),
          argumentChoices[0],
          if not field.optional: argumentChoices[1]
          else: nnkBracketExpr.newTree(
            newIdentNode("Option"),
            argumentChoices[1]
          )
        )
        argumentChoices = argumentChoices[2..^1]
        argumentChoices.insert(newFirst)
      createArgs[t.name].add nnkIdentDefs.newTree(
        aname,
        argumentChoices[0],
        newEmptyNode()
      )
      let check = checks[0]
      if field.optional:
        validations.add quote do:
          if `data`.hasKey(`fname`):
            `fields` += 1
            if `check`: return false
      else:
        requiredFields += 1
        validations.add quote do:
          if not `data`.hasKey(`fname`): return false
          if `check`: return false

    if t.extends.len == 0:
      validationBodies[t.name] = quote do:
        var `fields` = `requiredFields`
        `validations`
    else:
      let extends = validationBodies[t.extends]
      validationBodies[t.name] = quote do:
        `extends`
        `fields` += `requiredFields`
        `validations`
      for i in countdown(createArgs[t.extends].len - 1, 1):
        createArgs[t.name].insert(1, createArgs[t.extends][i])
      creatorBodies[t.name].insert(0, creatorBodies[t.extends])

  var forwardDecls = newStmtList()
  var validators = newStmtList()
  for kind, body in validationBodies.pairs:
    let kindIdent = newIdentNode(kind)
    validators.add quote do:
      proc isValid(`data`: JsonNode, schemaType: typedesc[`kindIdent`],
        `traverse` = true): bool =
        if `data`.kind != JObject: return false
        `body`
        if `fields` != `data`.len: return false
        return true
    forwardDecls.add quote do:
      proc isValid(`data`: JsonNode, schemaType: typedesc[`kindIdent`],
        `traverse` = true): bool
  var creators = newStmtList()
  for t in types:
    let
      creatorBody = creatorBodies[t.name]
      kindIdent = newIdentNode(t.name)
    var creatorArgs = createArgs[t.name]
    creatorArgs.insert(1, nnkIdentDefs.newTree(
      newIdentNode("schemaType"),
      nnkBracketExpr.newTree(
        newIdentNode("typedesc"),
        kindIdent
      ),
      newEmptyNode()
    ))
    var createProc = quote do:
      proc create() =
        var `ret` = newJObject()
        `creatorBody`
        return `ret`.`kindIdent`
    createProc[3] = creatorArgs
    creators.add createProc
    var forwardCreateProc = quote do:
      proc create()
    forwardCreateProc[3] = creatorArgs
    forwardDecls.add forwardCreateProc

  result = quote do:
    `typeDefinitions`
    `forwardDecls`
    `validators`
    `creators`
  when defined(jsonSchemaDebug):
    echo result.repr

when isMainModule:
  jsonSchema:
    CancelParams:
      id?: int or string or float
      something?: float

    WrapsCancelParams:
      cp: CancelParams
      name: string

    ExtendsCancelParams extends CancelParams:
      name: string

    WithArrayAndAny:
      test?: CancelParams[]
      ralph: int[] or float
      bob: any
      john?: int or nil

    NameTest:
      "method": string
      "result": int
      "if": bool
      "type": float

  var wcp = create(WrapsCancelParams,
    create(CancelParams, some(10), none(float)), "Hello"
  )
  echo wcp.isValid(WrapsCancelParams) == true
  wcp["cp"] = %*{"notcancelparams": true}
  echo wcp.isValid(WrapsCancelParams) == false
  echo wcp.isValid(WrapsCancelParams, false) == true
  var ecp = create(ExtendsCancelParams, some(10), some(5.3), "Hello")
  echo ecp.isValid(ExtendsCancelParams) == true
  var war = create(WithArrayAndAny, some(@[
    create(CancelParams, some(10), some(1.0)),
    create(CancelParams, some("hello"), none(float))
  ]), 2.0, %*{"hello": "world"}, none(NilType))
  echo war.isValid(WithArrayAndAny) == true

