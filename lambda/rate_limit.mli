(** Single global fixed-window limiter (A05, handler-level countermeasure).

    Pure, in-memory fixed-window rate limiter. [check] is a decision function
    over a mutable bucket — no I/O, no logging — so it is fully unit-testable.
    The handler holds one [t] for the lifetime of the execution environment and
    calls [check] only after a failed authentication comparison.

    Limit: 120 requests / 60s, counting only unauthenticated (missing or
    wrong-key) traffic. Authenticated requests do not consume budget.

    Caveats: the bucket is per execution environment. It resets on cold start
    and is *not* shared across parallel Lambda instances, so under horizontal
    scale an attacker can exceed the per-instance cap across instances. This is
    a best-effort backstop, not a hard edge limit. *)

type t

(** [create ()] makes a fresh, empty global rate-limiter bucket. *)
val create : unit -> t

(** [check t ~now] decides whether a failed-auth request may proceed under the
    fixed-window cap. Returns [(allowed, retry_after)]:
    - [allowed] is [true] when the bucket is under the limit (and the call is
      counted);
    - [retry_after] is the whole seconds the caller should wait before
      retrying (0 when allowed, or >= 1 when denied). [now] is injected so
      tests can advance time without [Unix.gettimeofday]. *)
val check : t -> now:float -> bool * int

(** [limit] is the per-window request cap (120). *)
val limit : int

(** [window_s] is the fixed-window length in seconds (60). *)
val window_s : float
