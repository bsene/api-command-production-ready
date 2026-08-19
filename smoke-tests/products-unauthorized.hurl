# S6 — anonymous access is rejected (A01 broken access control)
#
# Given the products API is running with authentication enabled
# When  a client requests GET /products without an x-api-key header
# Then  the server answers HTTP 401 (not 200).
GET {{base_url}}/products
HTTP 401
