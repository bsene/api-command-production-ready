(** Structured logger that writes Go [slog] text-handler-format lines into a
    buffer, so white-box tests can assert on substrings like [level=INFO],
    [products request completed], [status=200], [invalid_count=2].
    Port of the [log/slog] usage in orders_manager.go and main.go (A09). *)

type value =
  | S of string
  | I of int
  | F of float

(** A captured logger. *)
type t

(** [create ()] makes a logger writing into a fresh buffer. *)
val create : unit -> t

(** [contents t] returns the buffered log text. *)
val contents : t -> string

val info : t -> string -> (string * value) list -> unit
val warn : t -> string -> (string * value) list -> unit
val error : t -> string -> (string * value) list -> unit