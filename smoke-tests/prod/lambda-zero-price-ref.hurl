# P9 — production Lambda accepts zero price and ref (L2 input validation).
#
# Given the deployed Lambda Function URL
# When  a valid request with zero price and ref is sent with the API key
# Then  the response is HTTP 200 with ok=true (zero is allowed, only negatives rejected).
POST {{base_url}}
Content-Type: application/json
x-api-key: {{api_key}}

{"ref":0,"description":"freebie","stock":5,"price":0}
HTTP 200
[Asserts]
jsonpath "$.ok" == true
jsonpath "$.ref" == 0
jsonpath "$.message" contains "available=true"
