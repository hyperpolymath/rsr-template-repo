-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
--
-- ABI Proof: Non-null pointer safety
-- Template proof — customise for your project's pointer types.
-- All proofs MUST be constructive and total; proof escape hatches are forbidden.

module ABI.Pointers

import Data.So

%default total

||| A pointer value that has been proven non-null.
||| The `So` constraint carries a compile-time witness that `ptr /= 0`.
public export
record SafePtr where
  constructor MkSafePtr
  ptr : Bits64
  {auto 0 nonNull : So (ptr /= 0)}

||| `So b` and `So (not b)` cannot both hold. Only the second is needed at
||| run time, so the first may be the erased field of a `SafePtr`.
soExclusive : {b : Bool} -> (0 _ : So b) -> So (not b) -> Void
soExclusive {b = True}  _  Oh impossible
soExclusive {b = False} Oh _ impossible

||| Any two proofs of `So b` are equal (`So` has one constructor).
0 soUnique : (x, y : So b) -> x = y
soUnique Oh Oh = Refl

||| Proof that SafePtr can never hold a null (zero) value.
||| The record's `nonNull` field is erased (quantity 0), so it cannot be
||| returned as it stands. The test `ptr /= 0` is decidable: rerun it, and
||| refute the `False` branch with the erased witness. No escape hatch.
export
safePtrNeverNull : (sp : SafePtr) -> So (sp.ptr /= 0)
safePtrNeverNull (MkSafePtr p {nonNull}) = case choose (p /= 0) of
  Left yes => yes
  Right no => absurd (soExclusive nonNull no)

||| Wrap a raw pointer with a runtime null check.
||| Returns Nothing if the pointer is null.
export
checkPtr : (raw : Bits64) -> Maybe SafePtr
checkPtr 0 = Nothing
checkPtr raw = case choose (raw /= 0) of
  Left prf => Just (MkSafePtr raw)
  Right _ => Nothing

||| Proof that checkPtr 0 always returns Nothing.
export
checkPtrZeroIsNothing : checkPtr 0 = Nothing
checkPtrZeroIsNothing = Refl

||| Two `SafePtr`s with equal pointers are equal: the erased witnesses are
||| proofs of the same `So`, and those are unique.
export
safePtrEq : {0 p, q : Bits64} -> p = q
         -> (0 n1 : So (p /= 0)) -> (0 n2 : So (q /= 0))
         -> MkSafePtr p {nonNull = n1} = MkSafePtr q {nonNull = n2}
safePtrEq Refl n1 n2 = rewrite soUnique n1 n2 in Refl

||| An opaque handle backed by a non-null pointer.
||| Use this for FFI resource handles (file descriptors, sockets, etc.).
public export
record Handle (tag : String) where
  constructor MkHandle
  safePtr : SafePtr

||| Proof that two handles with equal pointers are equal.
export
handlePtrEq : (h1, h2 : Handle tag) -> h1.safePtr.ptr = h2.safePtr.ptr -> h1 = h2
handlePtrEq (MkHandle (MkSafePtr p {nonNull = n1}))
            (MkHandle (MkSafePtr q {nonNull = n2})) prf =
  cong MkHandle (safePtrEq prf n1 n2)
