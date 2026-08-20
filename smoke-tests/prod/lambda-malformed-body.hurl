# P4 — production Lambda rejects malformed bodies with a clear 400.
#
# Given the deployed Lambda Function URL
# When  a request is sent with invalid JSON and a valid API key
# Then  the response is HTTP 400 with an explicit error message.
POST {{base_url}}
Content-Type: application/json
x-api-key: {{api_key}}

```
not-json
```
HTTP 400
[Asserts]
jsonpath "$.error" == "invalid request body"
