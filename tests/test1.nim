import unittest
import json
import options
import sequtils
import "../src/jsonschema"

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

suite "basic tests":
  test "create and verify":
    var wcp = create(WrapsCancelParams,
      create(CancelParams, some(10), none(float)), "Hello"
    )
    check wcp.isValid(WrapsCancelParams) == true
    var ecp = create(ExtendsCancelParams, some(10), some(5.3), "Hello")
    check ecp.isValid(ExtendsCancelParams) == true
    var war = create(WithArrayAndAny, some(@[
      create(CancelParams, some(10), some(1.0)),
      create(CancelParams, some("hello"), none(float))
    ]), 2.0, %*{"hello": "world"}, none(NilType))
    check war.isValid(WithArrayAndAny) == true

  test "edit and verify":
    var wcp = create(WrapsCancelParams,
      create(CancelParams, some(10), none(float)), "Hello"
    )
    check wcp.isValid(WrapsCancelParams) == true
    wcp["cp"] = %*{"notcancelparams": true}
    check wcp.isValid(WrapsCancelParams, false) == true
