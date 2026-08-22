# P14 — production Lambda throttles a single caller past the per-IP rate limit (A05).
#
# Given the deployed Lambda Function URL with the handler-level per-IP
#       fixed-window rate limiter (120 req/60s/IP, in-memory per execution
#       environment)
# When  a single client issues more than 120 requests in 60s
# Then  the request past the cap is rejected with HTTP 429 and a Retry-After
#        header, validating the DoS backstop promoted in the A05 Dantotsu
#        report.
#
# Design notes:
# - The 120 leading requests carry no status assertion: the warm instance's
#   counter may already be non-zero from earlier scenarios in the same minute,
#   so some of them may legitimately return 429. We only assert on the final
#   request, which is always the >=121st call and is therefore always denied
#   regardless of the counter's starting value.
# - The limiter is per execution environment: sequential requests reuse one
#   warm Lambda instance, so the counter accumulates and the cap is hit.
# - Reserved concurrency (5) does not interfere because these requests are
#   sequential, not concurrent.
GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}

GET {{base_url}}/products
x-api-key: {{api_key}}
HTTP 429
[Asserts]
header "Retry-After" exists
jsonpath "$.error" == "too many requests"
