# S2 — stock data supports availability checks
#
# Given the products API is running
# When  the client requests GET /products
# Then  in-stock products report stock > 0
#  And  the out-of-stock product (raquette de tennis) reports stock 0.
GET {{base_url}}/products
x-api-key: {{api_key}}
HTTP 200
[Asserts]
jsonpath "$[0].stock" > 0
jsonpath "$[1].stock" > 0
jsonpath "$[2].stock" == 0
jsonpath "$[3].stock" > 0
