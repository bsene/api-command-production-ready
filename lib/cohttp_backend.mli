(** Cohttp_backend — the production SSRF-safe HTTP backend for
    [Orders_manager]. Implements [Orders_manager.HTTP_BACKEND] over
    [cohttp-lwt-unix], replacing the OS default resolver with a custom
    [Resolver_lwt.t] that resolves hostnames, runs [Ssrf.check_ssrf_ip] on every
    resolved IP, and refuses to dial any unsafe address (A04/A10). *)

(** [make ~allow_local_dev ()] builds a backend whose dial-time SSRF check
    allows loopback/private addresses only when [allow_local_dev] is true (the
    local-dev fixture mode). The returned first-class module satisfies
    [Orders_manager.HTTP_BACKEND]; pass it to [Orders_manager.create] via
    [~http_client].

    [allow_local_dev] is the same "local dev / insecure transport" opt-in as
    [Orders_manager.create]'s [~allow_insecure_http]: when injecting this
    backend into a manager, the two flags MUST be kept consistent. Passing
    [allow_local_dev:true] while creating the manager with
    [~allow_insecure_http:false] would let a hostname URL resolve to a
    loopback/private IP and be dialed, silently bypassing the construction-time
    SSRF check. *)
val make : allow_local_dev:bool -> unit -> (module Orders_manager.HTTP_BACKEND)
