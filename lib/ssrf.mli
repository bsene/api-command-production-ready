(** SSRF protection — OCaml port of the IP-classification and base-URL validation
    in orders_manager.go and the listen-address check in main.go (A04/A10/A01). *)

(** [check_ssrf_ip ip allow_local_dev] rejects IPs that must never be the target
    of an outbound request: link-local (cloud metadata), unspecified, multicast
    (always); loopback and private (unless [allow_local_dev], the local-dev
    fixture mode). Returns [Ok ()] or [Error msg]. *)
val check_ssrf_ip : Ipaddr.t -> bool -> (unit, string) result

(** [validate_base_url base_url allow_insecure_http] enforces scheme + SSRF
    constraints on an OrdersManager base URL. https is always allowed; http only
    with [allow_insecure_http]; any other scheme rejected. IP-literal hosts are
    checked immediately (hostnames are checked at dial time). *)
val validate_base_url : string -> bool -> (unit, string) result

(** [is_loopback host] reports whether [host] names a loopback address. *)
val is_loopback : string -> bool

(** [validate_listen_addr addr allow_external] rejects a non-loopback bind unless
    [allow_external] is set (prevents accidental 0.0.0.0 exposure, A01). *)
val validate_listen_addr : string -> bool -> (unit, string) result