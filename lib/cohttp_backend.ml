(* Cohttp_backend — the production SSRF-safe HTTP backend for Orders_manager.
   Implements Orders_manager.HTTP_BACKEND over cohttp-lwt-unix. The crux is the
   dial-time SSRF check: cohttp-lwt-unix resolves hostnames via Conduit's
   default Resolver_lwt_unix.system (the OS resolver), which would dial whatever
   IP DNS returns. We replace it with a custom Resolver_lwt.t whose rewrite_fn
   resolves the host, runs Ssrf.check_ssrf_ip on EVERY resolved IP (so a
   DNS-rebinding answer mixing safe and unsafe IPs is refused), and returns the
   first safe IP. *)

open Lwt.Infix

let make ~allow_local_dev () =
  let module B : Orders_manager.HTTP_BACKEND = struct
    type response = { status : int; body : string }

    (* Resolve [host] to a concrete TCP endpoint, refusing to dial any IP that
       Ssrf.check_ssrf_ip rejects. [svc.port] is the scheme default (80/443);
       an explicit port in the URI wins. The TLS wrapper is added by
       Resolver_lwt.resolve_uri from [svc.tls], so we return a bare [`TCP]. *)
    let rewrite_fn (svc : Resolver_lwt.svc) uri =
      match Uri.host uri with
      | None -> Lwt.return (`Unknown "URL has no host")
      | Some host ->
        let port = match Uri.port uri with Some p -> p | None -> svc.port in
        Lwt_unix.getaddrinfo host (string_of_int port)
          [ Lwt_unix.AI_SOCKTYPE Lwt_unix.SOCK_STREAM ]
        >>= fun addrs ->
        let ips =
          List.filter_map
            (fun ai ->
              match ai.Lwt_unix.ai_addr with
              | Lwt_unix.ADDR_INET (inet, _) -> Some (Ipaddr_unix.of_inet_addr inet)
              | _ -> None)
            addrs
        in
        (match ips with
         | [] -> Lwt.return (`Unknown ("name resolution failed for " ^ host))
         | first :: _ ->
           let rec check_all = function
             | [] -> Ok ()
             | ip :: rest ->
               (match Ssrf.check_ssrf_ip ip allow_local_dev with
                | Error e -> Error e
                | Ok () -> check_all rest)
           in
           (match check_all ips with
            | Error e -> Lwt.return (`Unknown e)
            | Ok () -> Lwt.return (`TCP (first, port))))

    let resolver =
      Resolver_lwt.init
        ~service:Resolver_lwt_unix.system_service
        ~rewrites:[ ("", rewrite_fn) ]
        ()

    let ctx = Cohttp_lwt_unix.Net.init ~resolver ()

    let request ~method_ ~url ~headers =
      Lwt.catch
        (fun () ->
          let uri = Uri.of_string url in
          let meth = Cohttp.Code.method_of_string method_ in
          let hdrs = Cohttp.Header.of_list headers in
          Cohttp_lwt_unix.Client.call ~ctx ~headers:hdrs meth uri
          >>= fun (resp, body) ->
          let status = Cohttp.Code.code_of_status (Cohttp.Response.status resp) in
          Cohttp_lwt.Body.to_string body >>= fun body_str ->
          Lwt.return (Ok { status; body = body_str }))
        (fun exn -> Lwt.return (Error (Printexc.to_string exn)))

    let status r = r.status
    let body r = r.body
  end in
  (module B : Orders_manager.HTTP_BACKEND)
