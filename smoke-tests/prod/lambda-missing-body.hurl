# P5 — production Lambda rejects empty bodies with a clear 400.
#
# Given the deployed Lambda Function URL
# When  a POST request with a valid API key has no body
# Then  the response is HTTP 400 with an explicit error message.
POST {{base_url}}
Content-Type: application/json
x-api-key: {{api_key}}
HTTP 400
[Asserts]
jsonpath "$.error" == "missing request body"
