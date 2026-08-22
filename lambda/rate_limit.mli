(** Per-IP request rate limiter (A05, handler-level countermeasure).

    Pure, in-memory, fixed-window rate limiter. [check] is a decision function
    over a mutable table — no I/O, no logging — so it is fully unit-testable.
    The handler holds one [t] for the lifetime of the execution environment
    and calls [check] before auth (all-requests policy).

    Limits: 120 requests / 60s / IP. The table is bounded by an LRU cap of
    ~1024 IPs.

    Caveats: the table is per execution environment. It resets on cold start
    and is *not* shared across parallel Lambda instances, so under horizontal
    scale an attacker can exceed the per-instance cap across instances. This
    is a best-effort backstop, not a hard edge limit. *)

type t

(** [create ()] makes a fresh, empty rate-limiter table. *)
val create : unit -> t

(** [check t ~now ~ip] decides whether [ip] may proceed under the fixed-window
    cap. Returns [(allowed, retry_after)]:
    - [allowed] is [true] when the IP is under the limit (and the call is
      counted);
    - [retry_after] is the whole seconds the caller should wait before
      retrying (0 when allowed, or ≥1 when denied). [now] is injected so tests
      can advance time without [Unix.gettimeofday]. *)
val check : t -> now:float -> ip:string -> bool * int

(** [limit] is the per-window per-IP request cap (120). *)
val limit : int

(** [window_s] is the fixed-window length in seconds (60). *)
val window_s : float

(** [cap] is the LRU table-size bound (~1024 IPs). *)
val cap : int