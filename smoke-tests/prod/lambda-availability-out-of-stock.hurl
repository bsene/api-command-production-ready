# P2 — production Lambda reports out-of-stock products as unavailable.
#
# Given the deployed Lambda Function URL
# When  a valid request with zero stock is sent with the API key
# Then  the response is HTTP 200 with ok=false and an availability message.
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
jsonpath "$.message" exists
jsonpath "$.message" contains "available=false"
