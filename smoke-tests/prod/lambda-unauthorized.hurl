# P3 — production Lambda rejects anonymous requests (A01).
#
# Given the deployed Lambda Function URL is configured with an API key
# When  a request is sent without the x-api-key header
# Then  the response is HTTP 401.
POST {{base_url}}
Content-Type: application/json
{
  "ref": 1,
  "description": "balle de tennis",
  "stock": 3,
  "price": 1.5
}
HTTP 401
[Asserts]
jsonpath "$.error" == "unauthorized"
