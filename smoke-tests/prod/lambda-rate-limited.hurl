# P14 — production Lambda throttles failed-authentication traffic past the
#       global rate limit (A05).
#
# Given the deployed Lambda Function URL with the handler-level global
#       fixed-window rate limiter (120 req/60s, in-memory per execution
#       environment, counting only missing or wrong x-api-key traffic)
# When  a client issues more than 120 unauthenticated requests in 60s
# Then  the request past the cap is rejected with HTTP 429 and a Retry-After
#        header, validating the DoS backstop promoted in the A05 Dantotsu
#        report.
#
# Design notes:
# - The 120 leading requests carry no status assertion: the warm instance's
#   counter may already be non-zero from earlier unauthenticated scenarios in
#   the same minute, so some of them may legitimately return 429. We only assert
#   on the final request, which is always the >=121st unauthenticated call and
#   is therefore always denied regardless of the counter's starting value.
# - The limiter is global, not per-IP: key-less requests from any source share
#   one bucket.
# - The limiter is per execution environment: sequential requests reuse one
#   warm Lambda instance, so the counter accumulates and the cap is hit.
# - Reserved concurrency (5) does not interfere because these requests are
#   sequential, not concurrent.
GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products

GET {{base_url}}/products
HTTP 429
[Asserts]
header "Retry-After" exists
jsonpath "$.error" == "too many requests"
