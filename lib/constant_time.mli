(** Constant-time string comparison — OCaml port of [crypto/subtle.ConstantTimeCompare].
    Used by the API-key auth check so key verification leaks no timing signal. *)

(** [equal a b] is true iff [a] and [b] have equal length and every byte matches.
    The comparison accumulates an XOR fold over all byte pairs (and the length
    delta) and tests the accumulator once at the end, so it does not short-circuit
    on the first mismatch. *)
val equal : string -> string -> bool