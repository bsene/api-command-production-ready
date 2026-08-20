(* Alcotest port of the SSRF + base-URL + listen-addr tests (L1b, T1).
   Mirrors orders_manager_test.go TestCheckSSRFIP* and TestNewOrdersManager_*
   (the SSRF/scheme/empty/insecure/https/invalid-scheme cases, which exercise
   validate_base_url + check_ssrf_ip directly). *)

open Apicommand.Ssrf

let ip s = match Ipaddr.of_string s with Ok i -> i | Error _ -> Alcotest.fail (s ^ ": bad ip")

let is_error name r =
  match r with Ok _ -> Alcotest.fail (name ^ ": expected error") | Error _ -> ()

let is_ok name r =
  match r with Ok () -> () | Error m -> Alcotest.fail (name ^ ": expected ok, got " ^ m)

(* --- TestCheckSSRFIP_blocksMetadataAlways --- *)
let blocks_metadata_always () =
  List.iter (fun s ->
    let i = ip s in
    is_error ("link-local " ^ s ^ " local-dev") (check_ssrf_ip i true);
    is_error ("link-local " ^ s ^ " prod") (check_ssrf_ip i false))
    [ "169.254.169.254"; "fe80::1" ]

(* --- TestCheckSSRFIP_allowsLoopbackInLocalDevOnly --- *)
let loopback_local_dev_only () =
  let i = ip "127.0.0.1" in
  is_ok "loopback local-dev" (check_ssrf_ip i true);
  is_error "loopback prod" (check_ssrf_ip i false)

(* --- TestCheckSSRFIP_allowsPublicIP --- *)
let allows_public_ip () =
  is_ok "public ip" (check_ssrf_ip (ip "93.184.216.34") false)

(* --- base URL: scheme + empty + insecure + https + invalid --- *)
let rejects_http_by_default () =
  is_error "http by default" (validate_base_url "http://products.com" false)

let rejects_empty () =
  is_error "empty base url" (validate_base_url "" false)

let allows_http_with_insecure () =
  is_ok "http with insecure" (validate_base_url "http://127.0.0.1:18080" true)

let accepts_https () =
  is_ok "https" (validate_base_url "https://products.com" false)

let rejects_invalid_scheme () =
  is_error "ftp scheme" (validate_base_url "ftp://products.com" false)

(* --- SSRF via base URL --- *)
let rejects_metadata_ip () =
  is_error "metadata ip" (validate_base_url "https://169.254.169.254" false)

let rejects_metadata_over_http_insecure () =
  is_error "metadata over http insecure" (validate_base_url "http://169.254.169.254" true)

let rejects_private_ip () =
  List.iter (fun u -> is_error ("private " ^ u) (validate_base_url u false))
    [ "https://10.0.0.1"; "https://172.16.0.1"; "https://192.168.1.1" ]

let rejects_loopback_https () =
  is_error "loopback https" (validate_base_url "https://127.0.0.1" false)

let rejects_unspecified_ip () =
  is_error "unspecified" (validate_base_url "https://0.0.0.0" false)

let allows_loopback_with_insecure_http () =
  is_ok "loopback insecure" (validate_base_url "http://127.0.0.1:18080" true)

(* --- listen address --- *)
let listen_loopback_ok () =
  is_ok "loopback bind" (validate_listen_addr "127.0.0.1:18080" false)

let listen_external_refused () =
  is_error "non-loopback refused" (validate_listen_addr "0.0.0.0:18080" false)

let listen_external_allowed () =
  is_ok "external with opt-in" (validate_listen_addr "0.0.0.0:18080" true)

let () =
  Alcotest.run "ssrf"
    [ ("check_ssrf_ip",
       [ Alcotest.test_case "blocks metadata always" `Quick blocks_metadata_always
       ; Alcotest.test_case "loopback local-dev only" `Quick loopback_local_dev_only
       ; Alcotest.test_case "allows public ip" `Quick allows_public_ip ])
    ; ("validate_base_url",
       [ Alcotest.test_case "rejects http by default" `Quick rejects_http_by_default
       ; Alcotest.test_case "rejects empty" `Quick rejects_empty
       ; Alcotest.test_case "allows http with insecure" `Quick allows_http_with_insecure
       ; Alcotest.test_case "accepts https" `Quick accepts_https
       ; Alcotest.test_case "rejects invalid scheme" `Quick rejects_invalid_scheme
       ; Alcotest.test_case "rejects metadata ip" `Quick rejects_metadata_ip
       ; Alcotest.test_case "rejects metadata over http insecure" `Quick rejects_metadata_over_http_insecure
       ; Alcotest.test_case "rejects private ip" `Quick rejects_private_ip
       ; Alcotest.test_case "rejects loopback https" `Quick rejects_loopback_https
       ; Alcotest.test_case "rejects unspecified ip" `Quick rejects_unspecified_ip
       ; Alcotest.test_case "allows loopback with insecure http" `Quick allows_loopback_with_insecure_http ])
    ; ("validate_listen_addr",
       [ Alcotest.test_case "loopback ok" `Quick listen_loopback_ok
       ; Alcotest.test_case "external refused" `Quick listen_external_refused
       ; Alcotest.test_case "external allowed" `Quick listen_external_allowed ])
    ]