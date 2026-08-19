# S1 — catalog contract
#
# Given the products API is running
# When  the client requests GET /products
# Then  the response is HTTP 200 with the full reference catalog
#        (4 products, each with ref / description / stock / prix).
GET {{base_url}}/products
x-api-key: {{api_key}}
HTTP 200
[Asserts]
jsonpath "$" isList
jsonpath "$" count == 4
jsonpath "$[0].ref" == 1
jsonpath "$[0].description" == "vélo électrique"
jsonpath "$[0].stock" == 10
jsonpath "$[0].prix" == 1400
jsonpath "$[3].ref" == 4
jsonpath "$[3].description" == "ballon de football"
jsonpath "$[3].stock" == 5
jsonpath "$[3].prix" == 25
