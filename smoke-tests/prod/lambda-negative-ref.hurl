# P8 — production Lambda rejects negative refs (L2 input validation).
#
# Given the deployed Lambda Function URL
# When  a valid request with a negative ref is sent with the API key
# Then  the response is HTTP 400 with an explicit error message.
POST {{base_url}}
Content-Type: application/json
x-api-key: {{api_key}}

{"ref":-1,"stock":5,"price":100}
HTTP 400
[Asserts]
jsonpath "$.error" == "ref must be >= 0"
