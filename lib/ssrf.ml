(* SSRF protection — IP classification and base-URL/listen-address validation.
   IP classification via Ipaddr; URL parsing via Uri. *)

let check_ssrf_ip ip allow_local_dev =
  let scope = Ipaddr.scope ip in
  if scope = Ipaddr.Link then
    Error "SSRF protection: link-local address (cloud metadata risk, A10)"
  else if scope = Ipaddr.Point then
    Error "SSRF protection: unspecified address"
  else if Ipaddr.is_multicast ip then
    Error "SSRF protection: multicast address"
  else if allow_local_dev then Ok ()
  else if scope = Ipaddr.Interface then
    Error "SSRF protection: loopback address"
  else if Ipaddr.is_private ip then
    Error "SSRF protection: private address"
  else Ok ()

let validate_base_url base_url allow_insecure_http =
  if base_url = "" then Error "base URL is empty"
  else
    let uri = Uri.of_string base_url in
    let scheme = Uri.scheme uri in
    let host = Uri.host uri in
    let scheme_ok () =
      match host with
      | None | Some "" -> Error "base URL has no host"
      | Some h ->
          (* IP-literal hosts are checked now; hostnames at dial time. *)
          (match Ipaddr.of_string h with
           | Ok ip -> check_ssrf_ip ip allow_insecure_http
           | Error _ -> Ok ())
    in
    match scheme with
    | Some "https" -> scheme_ok ()
    | Some "http" ->
        if allow_insecure_http then scheme_ok ()
        else Error "base URL must use https; pass allow_insecure_http only for local dev"
    | _ -> Error "base URL must use http or https scheme"

let is_loopback host =
  host = "localhost"
  || (match Ipaddr.of_string host with
      | Ok ip -> Ipaddr.scope ip = Ipaddr.Interface
      | Error _ -> false)

let split_host_port addr =
  match String.rindex_opt addr ':' with
  | None -> None
  | Some i ->
      let host = String.sub addr 0 i in
      let port = String.sub addr (i + 1) (String.length addr - i - 1) in
      Some (host, port)

let validate_listen_addr addr allow_external =
  match split_host_port addr with
  | None -> Error "split host:port"
  | Some (host, _) ->
      if allow_external then Ok ()
      else if is_loopback host then Ok ()
      else Error "non-loopback bind refused; pass allow_external to override"