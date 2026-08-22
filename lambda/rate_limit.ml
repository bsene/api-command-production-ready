(* Per-IP request rate limiter (A05 rate-limiting, handler-level
   countermeasure). Pure, in-memory, fixed-window: [check] is a decision
   function over a mutable table — no I/O, no logging — so it is fully
   unit-testable. The handler holds one [t] for the lifetime of the
   execution environment and calls [check] before auth (all-requests policy).

   Caveats (documented, accepted for the prototype):
   - The table is per execution environment. It resets on cold start and is
     *not* shared across parallel Lambda instances, so under horizontal scale
     an attacker can exceed the per-instance cap across instances. This is a
     best-effort backstop, not a hard edge limit.
   - [now] is injected so tests advance time without [Unix.gettimeofday]. *)

(* 120 requests / 60s / IP, as settled in grilling round 3. *)
let limit = 120
let window_s = 60.0
(* Bounded LRU so a flood of distinct IPs cannot grow the table unboundedly. *)
let cap = 1024

(* One bucket per IP: a request count plus the start of its current window. *)
type bucket = { mutable count : int; mutable window_start : float }

(* Insertion-ordered assoc list acts as a simple LRU: the head is the most
   recently checked IP. Eviction happens from the tail when [cap] is
   exceeded, and a checked IP is promoted to the head. *)
type t = { mutable entries : (string * bucket) list }

let create () = { entries = [] }

let remove_ip t ip =
  t.entries <- List.filter (fun (k, _) -> k <> ip) t.entries

(* [check t ~now ~ip] decides whether [ip] is allowed under the fixed-window
   cap. Returns [(allowed, retry_after)] where [retry_after] is the whole
   seconds the caller should wait before retrying (0 when allowed or when the
   current window has already expired and resets). *)
let check t ~now ~ip =
  (* Find and promote the IP's bucket to the head (most-recent). *)
  let bucket =
    match List.find_opt (fun (k, _) -> k = ip) t.entries with
    | Some (_, b) ->
      remove_ip t ip;
      b
    | None ->
      { count = 0; window_start = now }
  in
  (* Expire the window: if [now] is past the window, reset the bucket. *)
  if now -. bucket.window_start >= window_s then begin
    bucket.count <- 0;
    bucket.window_start <- now
  end;
  let allowed = bucket.count < limit in
  let retry_after =
    if allowed then 0
    else
      (* Seconds remaining in the current window, rounded up to whole seconds. *)
      let remaining = bucket.window_start +. window_s -. now in
      let r = int_of_float (ceil remaining) in
      max r 1
  in
  if allowed then bucket.count <- bucket.count + 1;
  (* Promote to head; evict the LRU tail if over cap. *)
  let new_entries = (ip, bucket) :: List.filter (fun (k, _) -> k <> ip) t.entries in
  let new_entries =
    if List.length new_entries > cap then
      (* Drop the last (least-recent) entry. *)
      let rec drop_last = function
        | [] -> []
        | [_] -> []
        | x :: xs -> x :: drop_last xs
      in
      drop_last new_entries
    else new_entries
  in
  t.entries <- new_entries;
  (allowed, retry_after)