# Online Auction Service

This project implements a REST and gRPC online-auction service. The REST API
is described in [api/openapi.yaml](api/openapi.yaml), and the internal gRPC
API is described in [proto/auction/v1/auction.proto](proto/auction/v1/auction.proto).

The HTTP handlers translate REST requests into gRPC calls. The service uses an
in-memory auction store for the current project stage. Auction versions are
returned as `ETag` headers and can be supplied through `If-Match` for
optimistic concurrency checks.

## Requirements

- Go 1.26 or newer
- `protoc` 3.15 or newer
- `curl`
- `grpcurl` (optional, for direct gRPC checks)

The project is intended to run in Linux or WSL.

## First-time setup

From the project root:

```sh
make setup
```

This records and installs the pinned Go code generators. `protoc` must be
installed separately.

## Build

Generate all REST and gRPC code, tidy dependencies, run `go vet`, and build the
server:

```sh
make build
```

The generated files are placed under `gen/`. Do not edit generated files by
hand. Regenerate them after changing either the OpenAPI or protobuf
definition:

```sh
make gen
```

## Run one server

Start node n1:

```sh
make run
```

It provides:

- REST API: `http://localhost:8080`
- gRPC API: `localhost:50051`
- Swagger UI: `http://localhost:8080/docs`
- Swagger Editor: `http://localhost:8080/editor`

## Run two nodes

Keep node n1 running, then start node n2 in another terminal:

```sh
make run2
```

Node n2 provides REST on `http://localhost:8081` and forwards its gRPC calls
to node n1.

## REST API

```
GET    /v1/auctions
POST   /v1/auctions/{auctionId}
GET    /v1/auctions/{auctionId}
PATCH  /v1/auctions/{auctionId}
DELETE /v1/auctions/{auctionId}
```

Examples:

```sh
# List all auctions
curl -i http://localhost:8080/v1/auctions

# List only open auctions
curl -i "http://localhost:8080/v1/auctions?status=OPEN"

# Read one auction
curl -i http://localhost:8080/v1/auctions/auction-1

# Create an auction
curl -i -X POST http://localhost:8080/v1/auctions/new-auction \
  -H 'Content-Type: application/json' \
  -d '{"item":"Laptop","startingPrice":100}'

# Place a bid
curl -i -X PATCH http://localhost:8080/v1/auctions/auction-1 \
  -H 'Content-Type: application/json' \
  -d '{"bidder":"Alice","amount":1500}'

# Close an auction
curl -i -X DELETE http://localhost:8080/v1/auctions/auction-1
```

Expected error mappings include:

| Condition | HTTP status |
|---|---:|
| Invalid request data | 400 |
| Auction not found | 404 |
| Auction already closed or bid too low | 409 |
| Incorrect `If-Match` version | 412 |

## Demonstration tests

With both nodes running, execute:

```sh
./etc/demo.sh
```

The script tests every REST operation against both nodes:

- list auctions and status filters;
- read each dummy auction and a missing auction;
- create new and duplicate auctions;
- place valid and invalid bids;
- test correct and incorrect `If-Match` versions;
- close auctions with and without `If-Match`.

The console shows each returned and expected status code. A detailed report is
written to `demo-results.txt`.

To specify different node URLs:

```sh
./etc/demo.sh http://localhost:8080 http://localhost:8081
```

## Complete automated check

```sh
make check
```

This command:

1. installs/checks the generators;
2. regenerates the REST and gRPC code;
3. runs `go vet` and builds the server;
4. starts two temporary nodes on ports `18080` and `18081`;
5. runs the complete test suite against both nodes;
6. writes the detailed report to `check-results.txt`.

Successful execution ends with:

```text
ALL TESTS PASSED
```

## Direct gRPC check

With `make run` running:

```sh
grpcurl -plaintext localhost:50051 list
grpcurl -plaintext localhost:50051 list auction.v1.AuctionService
grpcurl -plaintext localhost:50051 describe auction.v1.AuctionService
```

The service exposes `Read`, `CreateAuction`, `PlaceBid`, and `CloseAuction`.

## Project structure

```text
api/openapi.yaml                 REST API contract
api/oapi-codegen.yaml            REST generator configuration
proto/auction/v1/auction.proto   gRPC API contract
internal/httpapi/                REST-to-gRPC handlers
internal/grpcsvc/                gRPC service and in-memory state
cmd/server/                      server startup and node forwarding
etc/demo.sh                      REST demonstration tests
etc/check.sh                     build and two-node test entry point
gen/                             generated code
repo.url                         public repository link
students.json                    student information
```
