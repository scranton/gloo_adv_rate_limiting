# Solo Gloo Enterprise Gateway Advanced Envoy Rate Limiting Example

## Overview

This example shows a number of Gloo Enterprise Gateway capabilities

* Use of a custom authentication server
* Use and transformation of custom authentication server headers by upstream services and Rate Limiting
* Gloo request transformations to extract request headers and body content
* Use of advanced Envoy Rate Limiting configuration

## Prerequisites

This example assumes you have the following tools installed
* `kubectl`
* helm
* skaffold (to build and deploy echo-server and auth-server)
* jq (optional; to pretty print JSON responses in tests)
* golang (optional; used to download `kind`)
* HTTPie (alternative to curl for REST; https://httpie.org/)

## Running

This example installs an `echo-server` that responds to requests by capturing all request headers and body within a JSON
response. This example also installs a custom authentication server `auth-server` that does two things: 1) adds a
number of custom headers to its response and 2) only authorizes requests with a query path prefix of `/api/pets/1`.

```shell
./run_gloo_adv_rate_limit.sh
```
