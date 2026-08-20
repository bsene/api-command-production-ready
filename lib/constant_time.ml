(* Constant-time string comparison — port of crypto/subtle.ConstantTimeCompare.
   XOR-fold over all byte pairs plus the length delta; test once at the end so
   no early exit leaks where the first difference lies. *)

let equal a b =
  let la = String.length a and lb = String.length b in
  let acc = ref (la lxor lb) in
  let n = if la < lb then la else lb in
  for i = 0 to n - 1 do
    acc := !acc lor (Char.code a.[i] lxor Char.code b.[i])
  done;
  !acc = 0