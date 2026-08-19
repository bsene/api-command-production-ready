# S3 — catalog data supports keyword search
#
# Given the products API is running
# When  the client requests GET /products
# Then  both tennis products are present with their availability and price
#        (balle de tennis in stock at 1.5, raquette de tennis out of stock at 80).
GET {{base_url}}/products
x-api-key: {{api_key}}
HTTP 200
[Asserts]
jsonpath "$[1].description" == "balle de tennis"
jsonpath "$[1].stock" > 0
jsonpath "$[1].prix" == 1.5
jsonpath "$[2].description" == "raquette de tennis"
jsonpath "$[2].stock" == 0
jsonpath "$[2].prix" == 80
