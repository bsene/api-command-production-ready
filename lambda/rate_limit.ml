(* Single global fixed-window limiter (A05, handler-level countermeasure for
   failed-auth floods). Pure, in-memory: [check] is a decision function over
   a mutable bucket — no I/O, no logging — so it is fully unit-testable. The
   handler holds one [t] for the lifetime of the execution environment and
   calls [check] only after an authentication mismatch.

   Caveats (documented, accepted for the prototype):
   - The bucket is per execution environment. It resets on cold start and is
     *not* shared across parallel Lambda instances, so under horizontal scale
     an attacker can exceed the per-instance cap across instances. This is a
     best-effort backstop, not a hard edge limit.
   - [now] is injected so tests advance time without [Unix.gettimeofday]. *)

(* 120 requests / 60s, as settled in grilling round 3. *)
let limit = 120
let window_s = 60.0

type bucket = { mutable count : int; mutable window_start : float }

type t = { bucket : bucket }

let create () = { bucket = { count = 0; window_start = 0.0 } }

(* [check t ~now] decides whether a failed-auth request is allowed under the
   fixed-window cap. Returns [(allowed, retry_after)] where [retry_after] is
   the whole seconds the caller should wait before retrying (0 when allowed, or
   >= 1 when denied). [now] is injected so tests can advance time without
   [Unix.gettimeofday]. *)
let check t ~now =
  let bucket = t.bucket in
  if now -. bucket.window_start >= window_s then begin
    bucket.count <- 0;
    bucket.window_start <- now
  end;
  let allowed = bucket.count < limit in
  let retry_after =
    if allowed then 0
    else
      let remaining = bucket.window_start +. window_s -. now in
      let r = int_of_float (ceil remaining) in
      max r 1
  in
  if allowed then bucket.count <- bucket.count + 1;
  (allowed, retry_after)
