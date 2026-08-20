# P10 — production Lambda serves the product catalog on GET /products.
#
# Given the deployed Lambda Function URL
# When  a GET /products request is sent with the API key
# Then  the response is HTTP 200 with the full reference catalog
#        (16 products, each with ref / description / stock / prix).
GET {{base_url}}/products
x-api-key: {{api_key}}
HTTP 200
[Asserts]
jsonpath "$" isList
jsonpath "$" count == 16
jsonpath "$[0].ref" == 1
jsonpath "$[0].description" == "vélo électrique"
jsonpath "$[0].stock" == 10
jsonpath "$[0].prix" == 1400
jsonpath "$[15].ref" == 16
jsonpath "$[15].description" == "sac de sport"
jsonpath "$[15].stock" == 40
jsonpath "$[15].prix" == 34.9
