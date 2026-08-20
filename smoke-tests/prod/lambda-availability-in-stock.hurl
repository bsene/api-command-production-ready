# P1 — production Lambda reports in-stock products as available.
#
# Given the deployed Lambda Function URL
# When  a valid request with positive stock is sent with the API key
# Then  the response is HTTP 200 with ok=true and an availability message.
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
jsonpath "$.message" exists
jsonpath "$.message" contains "available=true"
