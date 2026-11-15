#!/usr/bin/env sh
# Auction REST tests.
# Start node n1 with `make run` and node n2 with `make run2` first.
# Usage: ./etc/demo.sh [n1-url] [n2-url]
# Results are written to demo-results.txt, or to $RESULTS_FILE if set.
#
# The state-changing tests assume freshly started servers. Node n2 forwards
# to n1, so the script uses different open dummy auctions for their close tests.

set -u

N1=${1:-http://localhost:8080}
N2=${2:-http://localhost:8081}
RESULTS_FILE=${RESULTS_FILE:-demo-results.txt}
TMP="${TMPDIR:-/tmp}/auction-demo-$$"
J='Content-Type: application/json'
FAILURES=0
TEST_NUMBER=0

cleanup() {
	rm -f "$TMP.headers" "$TMP.body" "$TMP.state_headers" "$TMP.state_body"
}
trap cleanup EXIT

: > "$RESULTS_FILE"

json_field() {
	sed -n "s/.*\"$1\":\([-0-9]*\).*/\1/p" "$TMP.state_body" | head -1
}

state_for() {
	curl -sS -D "$TMP.state_headers" -o "$TMP.state_body" \
		"$1/v1/auctions/$2" >/dev/null
	STATE_VERSION=$(sed -n 's/^[Ee][Tt][Aa][Gg]:[[:space:]]*"\([^"]*\)".*/\1/p' "$TMP.state_headers" | head -1)
	STATE_BID=$(json_field currentBid)
}

run_test() {
	TEST_NUMBER=$((TEST_NUMBER + 1))
	name=$1
	check=$2
	expected=$3
	method=$4
	url=$5
	body=$6
	header=$7
	set -- -sS -D "$TMP.headers" -o "$TMP.body" -w '%{http_code}' \
		-X "$method" "$url"
	[ -n "$header" ] && set -- "$@" -H "$header"
	[ -n "$body" ] && set -- "$@" -d "$body"
	status=$(curl "$@")
	reply=$(cat "$TMP.body")
	[ -n "$reply" ] || reply="(empty body)"

	if [ "$status" = "$expected" ]; then
		result=PASS
	else
		result=FAIL
		FAILURES=$((FAILURES + 1))
	fi

	{
		printf 'Test %s: %s\n' "$TEST_NUMBER" "$name"
		printf 'what we check\n%s\n' "$check"
		printf 'what we sent\n%s %s\n' "$method" "$url"
		[ -n "$header" ] && printf 'Header: %s\n' "$header"
		[ -n "$body" ] && printf 'Body: %s\n' "$body"
		printf 'what was the reply\nHTTP %s\n%s\n' "$status" "$reply"
		printf 'what was the expected result\nHTTP %s\n' "$expected"
		printf '%s\n\n' "$result"
	} >> "$RESULTS_FILE"
	printf '%-4s %s (HTTP %s, expected %s)\n' "$result" "$name" "$status" "$expected"
}

run_for_node() {
	B=$1
	NODE_NAME=$2
	if [ "$NODE_NAME" = n1 ]; then
		ID1=auction-1
		ID2=auction-2
		ID3=auction-3
	else
		ID1=auction-4
		ID2=auction-5
		ID3=auction-6
	fi
	MAIN_ID=$ID1
	OTHER_ID=$ID3
	CREATE_ID="demo-${NODE_NAME}-$$"

	printf '\n%s (%s)\n' "$NODE_NAME" "$B"
	# 1.1 Invalid enum in a list request must be rejected with HTTP 400.
	run_test "$NODE_NAME 1.1 invalid list request" \
		"Invalid status selector is rejected." 400 GET \
		"$B/v1/auctions?status=INVALID" "" ""

	# 1.2 Filtering by OPEN returns HTTP 200 and only matching auctions.
	run_test "$NODE_NAME 1.2 list OPEN auctions" \
		"List request with status=OPEN succeeds." 200 GET \
		"$B/v1/auctions?status=OPEN" "" ""

	# 1.2 Filtering by CLOSED returns HTTP 200.
	run_test "$NODE_NAME 1.2 list CLOSED auctions" \
		"List request with status=CLOSED succeeds." 200 GET \
		"$B/v1/auctions?status=CLOSED" "" ""

	# 1.3 Omitting the selector returns all auctions.
	run_test "$NODE_NAME 1.3 list all auctions" \
		"List request without a selector succeeds." 200 GET \
		"$B/v1/auctions" "" ""

	# 2.1 Each predefined dummy auction can be read by ID.
	for id in "$ID1" "$ID2" "$ID3"; do
		run_test "$NODE_NAME 2.1 get $id" \
			"Existing dummy auction $id is returned." 200 GET \
			"$B/v1/auctions/$id" "" ""
	done

	# 2.2 A missing auction returns HTTP 404.
	run_test "$NODE_NAME 2.2 get missing auction" \
		"Unknown auction ID is reported as not found." 404 GET \
		"$B/v1/auctions/does-not-exist" "" ""

	# 3.1 A valid new auction is created with HTTP 201.
	run_test "$NODE_NAME 3.1 create new auction" \
		"Valid create request returns Created." 201 POST \
		"$B/v1/auctions/$CREATE_ID" \
		'{"item":"Demo item","startingPrice":100}' "$J"

	# 3.2 IDs from the dummy list are rejected as duplicates.
	for id in "$ID1" "$ID2" "$ID3"; do
		run_test "$NODE_NAME 3.2 duplicate $id" \
			"Creating an existing dummy ID returns Already Exists." 409 POST \
			"$B/v1/auctions/$id" \
			'{"item":"Duplicate","startingPrice":100}' "$J"
	done

	# 3.3 Missing required fields and invalid starting price return HTTP 400.
	run_test "$NODE_NAME 3.3 missing create fields" \
		"Missing item and startingPrice are invalid." 400 POST \
		"$B/v1/auctions/$CREATE_ID-missing" \
		'{}' "$J"
	run_test "$NODE_NAME 3.3 negative starting price" \
		"Negative startingPrice is invalid." 400 POST \
		"$B/v1/auctions/$CREATE_ID-negative" \
		'{"item":"Bad","startingPrice":-1}' "$J"

	# 4.1 Open auctions accept higher bids; the closed dummy auction returns 409.
	for id in "$ID1" "$ID2" "$ID3"; do
		state_for "$B" "$id"
		if [ "$id" = "$ID2" ]; then
			expected=409
			amount=999999
		else
			expected=200
			amount=$((STATE_BID + 100))
		fi
		run_test "$NODE_NAME 4.1 bid on $id" \
			"Bid uses the real auction status and current bid." "$expected" PATCH \
			"$B/v1/auctions/$id" \
			"{\"bidder\":\"${NODE_NAME}-bidder\",\"amount\":$amount}" "$J"
	done

	# 4.2 An unknown auction cannot receive a bid.
	run_test "$NODE_NAME 4.2 bid on missing auction" \
		"Unknown auction ID returns Not Found." 404 PATCH \
		"$B/v1/auctions/does-not-exist" \
		'{"bidder":"Alice","amount":100}' "$J"

	# 4.3 A stale If-Match version returns HTTP 412.
	state_for "$B" "$MAIN_ID"
	stale=$((STATE_VERSION + 100))
	run_test "$NODE_NAME 4.3 incorrect If-Match" \
		"Stale optimistic-concurrency version is rejected." 412 PATCH \
		"$B/v1/auctions/$MAIN_ID" \
		"{\"bidder\":\"Alice\",\"amount\":$((STATE_BID + 100))}" "If-Match: \"$stale\""

	# 4.4 The current If-Match version allows the bid.
	state_for "$B" "$MAIN_ID"
	run_test "$NODE_NAME 4.4 correct If-Match" \
		"Current optimistic-concurrency version allows the bid." 200 PATCH \
		"$B/v1/auctions/$MAIN_ID" \
		"{\"bidder\":\"Alice\",\"amount\":$((STATE_BID + 100))}" "If-Match: \"$STATE_VERSION\""

	# 4.5 A bid that is not greater than the current bid returns HTTP 409.
	state_for "$B" "$MAIN_ID"
	run_test "$NODE_NAME 4.5 bid too low" \
		"Bid equal to the current bid is rejected." 409 PATCH \
		"$B/v1/auctions/$MAIN_ID" \
		"{\"bidder\":\"Bob\",\"amount\":$STATE_BID}" ""

	# 4.6 Negative bid amount returns HTTP 400.
	run_test "$NODE_NAME 4.6 negative bid" \
		"Negative bid amount is invalid." 400 PATCH \
		"$B/v1/auctions/$MAIN_ID" \
		'{"bidder":"Bob","amount":-1}' "$J"

	# 4.7 Missing bidder returns HTTP 400.
	run_test "$NODE_NAME 4.7 missing bidder" \
		"Bidder is required." 400 PATCH \
		"$B/v1/auctions/$MAIN_ID" \
		"{\"amount\":$((STATE_BID + 100))}" "$J"

	# 5.1 Deleting an unknown auction returns HTTP 404.
	run_test "$NODE_NAME 5.1 delete missing auction" \
		"Unknown auction ID returns Not Found." 404 DELETE \
		"$B/v1/auctions/does-not-exist" "" ""

	# 5.2 A stale If-Match version returns HTTP 412.
	state_for "$B" "$MAIN_ID"
	stale=$((STATE_VERSION + 100))
	run_test "$NODE_NAME 5.2 delete with incorrect If-Match" \
		"Stale version cannot close the auction." 412 DELETE \
		"$B/v1/auctions/$MAIN_ID" "" "If-Match: \"$stale\""

	# 5.3 The predefined closed auction cannot be closed again.
	run_test "$NODE_NAME 5.3 delete already closed auction" \
		"Closing $ID2 returns Conflict." 409 DELETE \
		"$B/v1/auctions/$ID2" "" ""

	# 5.5 Closing an open auction without If-Match is allowed.
	run_test "$NODE_NAME 5.5 delete open auction without match" \
		"An open auction can be closed without a version header." 200 DELETE \
		"$B/v1/auctions/$OTHER_ID" "" ""

	# 5.4 The remaining open auction can be closed with its current version.
	state_for "$B" "$MAIN_ID"
	run_test "$NODE_NAME 5.4 delete with correct If-Match" \
		"Current version allows closing the open auction." 200 DELETE \
		"$B/v1/auctions/$MAIN_ID" "" "If-Match: \"$STATE_VERSION\""
}

run_for_node "$N1" n1
run_for_node "$N2" n2

printf '\nResults written to %s\n' "$RESULTS_FILE"
if [ "$FAILURES" -eq 0 ]; then
	printf 'ALL TESTS PASSED\n'
else
	printf '%s TEST(S) FAILED\n' "$FAILURES"
	exit 1
fi
