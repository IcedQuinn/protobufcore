# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import pbufinternal/varint

type
   WireType* = enum
      wtVarint
      wtSixtyfourBit
      wtLengthDelimited
      wtStartGroup
      wtEndGroup
      wtThirtytwoBit
      wtUnknown

proc tag*(value: int64; dunce: WireType): int64 =
   ## Attaches a wiretype tag to a number.
   result = (value shl 3) + ord(dunce)

proc untag*(value: int64): (int64, WireType) =
   ## Separates a wiretype tag and number.
   let wt = value and 7
   var k {.noinit.}: WireType
   case wt
   of ord(wtVarint):          k = wtVarint
   of ord(wtSixtyfourBit):    k = wtSixtyfourBit
   of ord(wtLengthDelimited): k = wtLengthDelimited
   of ord(wtStartGroup):      k = wtStartGroup
   of ord(wtEndGroup):        k = wtEndGroup
   of ord(wtThirtytwoBit):    k = wtThirtytwoBit
   else: k = wtUnknown
   return (value shr 3, k)

static:
   assert ord(wtVarint) == 0
   assert ord(wtSixtyfourBit) == 1
   assert ord(wtLengthDelimited) == 2
   assert ord(wtStartGroup) == 3
   assert ord(wtEndGroup) == 4
   assert ord(wtThirtytwoBit) == 5

when is_main_module:
   block:
      let a = b128enc(1)
      assert a[0] == 1
      assert b128dec(a) == 1

      let b = b128enc(300)
      assert b[0] == 172
      assert b[1] == 2
      assert b128dec(b) == 300

      assert zigzag32( 0) == 0
      assert zigzag32(-1) == 1
      assert zigzag32( 1) == 2
      assert zigzag32(-2) == 3

      assert unzigzag32(zigzag32(1337)) == 1337
      assert unzigzag32(zigzag32(-1337)) == -1337

      let t = untag(tag(1337, wtSixtyfourBit))
      assert t[0] == 1337
      assert t[1] == wtSixtyfourBit

#######################################################################

proc read_varint*(source: string; here: var int; ok: var bool): int64 =
   ## Reads a variable length integer from a string by moving a cursor.
   let valid = 0..source.high

   ok = false
   if here notin valid: return

   var bundle: array[10, byte]
   for i in 0..9:
      if (here notin valid) or ((source[here].int and 0x80) == 0): break
      bundle[i] = source[here].byte
      inc here

   result = b128dec(bundle)
   ok = true

proc read_zigvarint*(source: string; here: var int; ok: var bool): int64 =
   ## Reads a zigzag encoded variable length integer from a string by moving a cursor.
   result = unzigzag64(read_varint(source, here, ok))

proc read_tag*(source: string; here: var int; ok: var bool): (int64, WireType) =
   ## Reads a field tag from a string by moving a cursor.
   result = untag(read_varint(source, here, ok))

type
   WireEvent* = object
      ## A union to support stream decoding.
      field*: int64
      case kind: WireType:
      of wtUnknown, wtStartGroup, wtEndGroup:
         discard
      of wtVarint, wtLengthDelimited:
         vdata*: int64
      of wtSixtyfourBit:
         sixtyfour*: array[8, byte]
      of wtThirtytwoBit:
         thirtytwo*: array[8, byte]

proc read_event*(source: string; here: var int; ok: var bool): WireEvent =
   ## Reads a field tag and the subsequent data (or at least length of
   ## the data) and returns it as an event.

   let valid = 0..source.high
   let mark = here
   defer:
      if not ok: here = mark

   let header = read_tag(source, here, ok)
   if not ok: return

   # XXX I would like to avoid copymem since it breaks compile-time and
   # javascript targets but whats a better way to do it?

   ok = true
   case header[1]
   of wtUnknown:
      ok = false
      return
   of wtStartGroup, wtEndGroup:
      result = WireEvent(kind: header[1], field: header[0])
   of wtSixtyfourBit:
      if here+8 notin valid:
         ok = false
         return
      result = WireEvent(kind: header[1], field: header[0])
      copymem(addr result.sixtyfour[0], unsafeaddr source[here], 8)
      inc here, 8
   of wtThirtytwoBit:
      if here+4 notin valid:
         ok = false
         return
      result = WireEvent(kind: header[1], field: header[0])
      copymem(addr result.thirtytwo[0], unsafeaddr source[here], 4)
      inc here, 4
   of wtLengthDelimited:
      let value = read_varint(source, here, ok)
      if not ok: return
      result = WireEvent(kind: wtLengthDelimited, field: header[0], vdata: value)
   of wtVarint:
      let value = read_varint(source, here, ok)
      if not ok: return
      result = WireEvent(kind: wtVarint, field: header[0], vdata: value)

iterator events*(source: string; here: var int; ok: var bool): WireEvent =
   ## Iterates over every event and returns it.
   ## Allows you to reframe the read_event loop as `for x in events(...)`.
   let valid = 0..source.high
   var ok = true
   while true:
      var k = read_event(source, here, ok)
      if ok and here in valid: yield k
      else: break

