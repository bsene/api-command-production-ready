# P11 — production Lambda rejects a wrong x-api-key (M2).
#
# The Function URL grants lambda:InvokeFunction to "*" (Oct-2025 AWS
# requirement; Pulumi v6 lacks invokedViaFunctionUrl), so the handler-level
# x-api-key check is the only defense in depth. This scenario complements
# P3 by ensuring the gate rejects an explicitly wrong key, not only a
# missing header.
#
# Given the deployed Lambda Function URL is configured with an API key
# When  a request is sent with an incorrect x-api-key header
# Then  the response is HTTP 401 and the handler does not leak whether the
#       path exists or process any business logic.
POST {{base_url}}
Content-Type: application/json
x-api-key: definitely-not-the-real-key
{
  "ref": 1,
  "description": "balle de tennis",
  "stock": 3,
  "price": 1.5
}
HTTP 401
[Asserts]
jsonpath "$.error" == "unauthorized"
