# S4 — catalog data supports cart validation
#
# Given the products API is running
# When  the client requests GET /products
# Then  prices are present so a cart total can be computed
#        (2x vélo électrique @1400 + 3x balle de tennis @1.5 = 2804.5).
GET {{base_url}}/products
x-api-key: {{api_key}}
HTTP 200
[Asserts]
jsonpath "$[0].prix" == 1400
jsonpath "$[1].prix" == 1.5
