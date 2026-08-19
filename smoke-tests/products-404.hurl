# S5 — unknown paths are rejected
#
# Given the products API is running
# When  a client requests an unknown path
# Then  the server answers HTTP 404 (not a silent 200).
GET {{base_url}}/does-not-exist
x-api-key: {{api_key}}
HTTP 404
