# Production smoke scenario — chained end-to-end check of the deployed Lambda.
#
# This scenario exercises the production Function URL in a single Hurl file:
#   1. anonymous request is rejected (A01)
#   2. in-stock product is reported available
#   3. out-of-stock product is reported unavailable
#   4. malformed body returns a clear 400

# 1. Anonymous access is rejected.
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

# 2. In-stock product is available.
POST {{base_url}}
Content-Type: application/json
x-api-key: {{api_key}}
{
  "ref": 1,
  "description": "balle de tennis",
  "stock": 3,
  "price": 1.5
}
HTTP 200
[Asserts]
jsonpath "$.ok" == true
jsonpath "$.ref" == 1
jsonpath "$.message" contains "available=true"

# 3. Out-of-stock product is unavailable.
POST {{base_url}}
Content-Type: application/json
x-api-key: {{api_key}}
{
  "ref": 2,
  "description": "raquette de tennis",
  "stock": 0,
  "price": 80
}
HTTP 200
[Asserts]
jsonpath "$.ok" == false
jsonpath "$.ref" == 2
jsonpath "$.message" contains "available=false"

# 4. Malformed body returns 400.
POST {{base_url}}
Content-Type: application/json
x-api-key: {{api_key}}
not-json
HTTP 400
[Asserts]
jsonpath "$.error" == "invalid request body"
