# P12 — production Lambda decodes a base64-encoded binary body (L3).
#
# API Gateway v2 / Lambda Function URLs base64-encode binary request bodies and
# set isBase64Encoded=true. The handler must decode the body before parsing it.
# Sending JSON as application/octet-stream forces the binary path and exercises
# the decode branch that was missing in the original implementation.
#
# Given the deployed Lambda Function URL
# When  a valid JSON body is sent as a binary/octet-stream payload
# Then  the handler base64-decodes it, parses the JSON, and returns HTTP 200.
POST {{base_url}}
Content-Type: application/octet-stream
x-api-key: {{api_key}}
{"ref":42,"description":"base64 smoke","stock":5,"price":10}
HTTP 200
[Asserts]
jsonpath "$.ok" == true
jsonpath "$.ref" == 42
jsonpath "$.message" contains "base64 smoke"
jsonpath "$.message" contains "available=true"
