// Package grpcsvc implements the AuctionService gRPC service.
//
// STEP 4 — Part I uses an in-memory dummy store to prove that the .proto
// compiles and that two processes can talk over gRPC. In Part II this type
// will apply operations to the state machine, and in Part III it will submit
// them to the replicated log.


//gRPC NotFound          → HTTP 404
// gRPC InvalidArgument   → HTTP 400
// gRPC FailedPrecondition → HTTP 412
// gRPC Aborted           → HTTP 409

package grpcsvc

import (
	"context"
	"fmt"
	"sync"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	auctionv1 "github.com/your-team/auction/gen/auction/v1"
)

// Server implements auctionv1.AuctionServiceServer.
//
// Embedding UnimplementedAuctionServiceServer makes every RPC not written yet return
// codes.Unimplemented (HTTP 501 after translation): when you add RPCs for your
// own service, the project keeps compiling while you work through them.
type Server struct {
	auctionv1.UnimplementedAuctionServiceServer

	NodeID string // shown in dummy values, so you can see WHICH server answered
}

func New(nodeID string) *Server { return &Server{NodeID: nodeID} }

var dummyMu sync.RWMutex

// dummyAuctions is the pretend content of the service. The ID "missing" never
// exists, so you can test the 404 path end to end.
var dummyAuctions = []struct {
	id      string
	item    string
	bid     int64
	bidder  string
	status  auctionv1.AuctionStatus
	version int64
}{
	{id: "auction-1", item: "Mac Pro M5 Laptop", bid: 1200, bidder: "Steve Jobs", status: auctionv1.AuctionStatus_AUCTION_STATUS_OPEN, version: dummyVersion},
	{id: "auction-2", item: "Blackwell AI Chip", bid: 4000, bidder: "Jensen Huang", status: auctionv1.AuctionStatus_AUCTION_STATUS_CLOSED, version: dummyVersion},
	{id: "auction-3", item: "Starlink mini", bid: 2100, bidder: "Elon Musk", status: auctionv1.AuctionStatus_AUCTION_STATUS_OPEN, version: dummyVersion},
	{id: "auction-4", item: "Mac Pro M5 Laptop_N2", bid: 1200, bidder: "Steve Jobs", status: auctionv1.AuctionStatus_AUCTION_STATUS_OPEN, version: dummyVersion},
	{id: "auction-5", item: "Blackwell AI Chip_N2", bid: 4000, bidder: "Jensen Huang", status: auctionv1.AuctionStatus_AUCTION_STATUS_CLOSED, version: dummyVersion},
	{id: "auction-6", item: "Starlink mini_N2", bid: 2100, bidder: "Elon Musk", status: auctionv1.AuctionStatus_AUCTION_STATUS_OPEN, version: dummyVersion},

}

// New dummy auctions start at this version.
const dummyVersion = 1

// ---------------------------------------------------------------------------
// Online Acutions service.
// ---------------------------------------------------------------------------

// Read is server streaming: one ReadResponse per auction.
func (s *Server) Read(req *auctionv1.ReadRequest, stream auctionv1.AuctionService_ReadServer) error {
	dummyMu.RLock()
	defer dummyMu.RUnlock()

	switch sel := req.GetSelect().(type) { //one auction ID
	case *auctionv1.ReadRequest_AuctionId:
		var found *struct {
			id      string
			item    string
			bid     int64
			bidder  string
			status  auctionv1.AuctionStatus
			version int64
		}

		for i := range dummyAuctions {
			if dummyAuctions[i].id == sel.AuctionId {
				found = &dummyAuctions[i]
				break
			}
		}

		if found == nil {
			return status.Errorf(codes.NotFound, "auction %q not found", sel.AuctionId)
		}

		a := &auctionv1.Auction{
			AuctionId:  found.id,
			Item:       fmt.Sprintf("%s (dummy from %s)", found.item, s.NodeID),
			CurrentBid: found.bid,
			Status:     found.status,
			Version:    found.version,
		}

		if found.bidder != "" {
			bidder := found.bidder
			a.HighestBidder = &bidder
		}

		if err := stream.Send(&auctionv1.ReadResponse{Auction: a}); err != nil {
			return err
		}

		return nil

	case *auctionv1.ReadRequest_StatusFilter: // list auctions, optionally filtered by status
		for _, d := range dummyAuctions {
			if sel.StatusFilter != auctionv1.AuctionStatus_AUCTION_STATUS_UNSPECIFIED && d.status != sel.StatusFilter {
				continue
			}
			a := &auctionv1.Auction{
				AuctionId:  d.id,
				Item:       fmt.Sprintf("%s (dummy from %s, %s read)", d.item, s.NodeID, req.GetConsistency()),
				CurrentBid: d.bid,
				Status:     d.status,
				Version:    d.version,
			}
			if d.bidder != "" {
				b := d.bidder
				a.HighestBidder = &b
			}
			if err := stream.Send(&auctionv1.ReadResponse{Auction: a}); err != nil {
				return err
			}
		}
		return nil

	default: // no selector: return all dummy auctions
		for _, d := range dummyAuctions {
			a := &auctionv1.Auction{
				AuctionId:  d.id,
				Item:       fmt.Sprintf("%s (dummy from %s, %s read)", d.item, s.NodeID, req.GetConsistency()),
				CurrentBid: d.bid,
				Status:     d.status,
				Version:    d.version,
			}
			if d.bidder != "" {
				b := d.bidder
				a.HighestBidder = &b
			}
			if err := stream.Send(&auctionv1.ReadResponse{Auction: a}); err != nil {
				return err
			}
		}
		return nil
	}
}

// CreateAuction creates a dummy auction in OPEN state with version 1.
func (s *Server) CreateAuction(ctx context.Context, req *auctionv1.CreateAuctionRequest) (*auctionv1.CreateAuctionResponse, error) {
	if req.GetAuctionId() == "" || req.GetItem() == "" || req.GetStartingPrice() < 0 {
		return nil, status.Error(codes.InvalidArgument, "auction_id, item, and non-negative starting_price are required")
	}
	dummyMu.RLock()
	defer dummyMu.RUnlock()
	for _, d := range dummyAuctions {
		if req.GetAuctionId() == d.id {
			return nil, status.Errorf(
				codes.AlreadyExists,
				"auction %q already exists",
				req.GetAuctionId(),
			)
		}
	}

	return &auctionv1.CreateAuctionResponse{
		Auction: &auctionv1.Auction{
			AuctionId:  req.GetAuctionId(),
			Item:       fmt.Sprintf("%s (created on %s)", req.GetItem(), s.NodeID),
			CurrentBid: req.GetStartingPrice(),
			Status:     auctionv1.AuctionStatus_AUCTION_STATUS_OPEN,
			Version:    dummyVersion,
		},
	}, nil
}

// PlaceBid places a dummy bid on an OPEN auction (RMW).
func (s *Server) PlaceBid(ctx context.Context, req *auctionv1.PlaceBidRequest) (*auctionv1.PlaceBidResponse, error) {
	dummyMu.Lock()
	defer dummyMu.Unlock()

	var auction *struct {
		id      string
		item    string
		bid     int64
		bidder  string
		status  auctionv1.AuctionStatus
		version int64
	}
	for i := range dummyAuctions {
		if dummyAuctions[i].id == req.GetAuctionId() {
			auction = &dummyAuctions[i]
			break
		}
	}
	if auction == nil {
		return nil, status.Errorf(codes.NotFound, "auction %q not found", req.GetAuctionId())
	}
	if auction.status != auctionv1.AuctionStatus_AUCTION_STATUS_OPEN {
		return nil, status.Errorf(codes.Aborted, "auction %q is already closed", auction.id)
	}
	if req.IfVersion != nil && req.GetIfVersion() != auction.version {
		return nil, status.Errorf(codes.FailedPrecondition,
			"auction %q is at version %d, not %d", auction.id, auction.version, req.GetIfVersion())
	}
	if req.GetBidder() == "" {
		return nil, status.Error(codes.InvalidArgument, "bidder is required")
	}
	if req.GetAmount() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "bid amount must be positive")
	}
	if (auction.bidder == "" && req.GetAmount() < auction.bid) ||
		(auction.bidder != "" && req.GetAmount() <= auction.bid) {
		return nil, status.Errorf(codes.Aborted,
			"bid amount %d is not high enough for auction %q", req.GetAmount(), auction.id)
	}

	bidder := req.GetBidder()
	auction.bid = req.GetAmount()
	auction.bidder = bidder
	auction.version++
	return &auctionv1.PlaceBidResponse{
		Auction: &auctionv1.Auction{
			AuctionId:     auction.id,
			Item:          fmt.Sprintf("%s (bid processed on %s)", auction.item, s.NodeID),
			CurrentBid:    auction.bid,
			HighestBidder: &bidder,
			Status:        auction.status,
			Version:       auction.version,
		},
	}, nil
}

// CloseAuction closes a dummy auction so no further bids are accepted.
func (s *Server) CloseAuction(ctx context.Context, req *auctionv1.CloseAuctionRequest) (*auctionv1.CloseAuctionResponse, error) {
	dummyMu.Lock()
	defer dummyMu.Unlock()

	var auction *struct {
		id      string
		item    string
		bid     int64
		bidder  string
		status  auctionv1.AuctionStatus
		version int64
	}
	for i := range dummyAuctions {
		if dummyAuctions[i].id == req.GetAuctionId() {
			auction = &dummyAuctions[i]
			break
		}
	}
	if auction == nil {
		return nil, status.Errorf(codes.NotFound, "auction %q not found", req.GetAuctionId())
	}
	if auction.status == auctionv1.AuctionStatus_AUCTION_STATUS_CLOSED {
		return nil, status.Errorf(codes.Aborted, "auction %q is already closed", auction.id)
	}
	if req.IfVersion != nil && req.GetIfVersion() != auction.version {
		return nil, status.Errorf(codes.FailedPrecondition,
			"auction %q is at version %d, not %d", auction.id, auction.version, req.GetIfVersion())
	}

	auction.status = auctionv1.AuctionStatus_AUCTION_STATUS_CLOSED
	auction.version++
	var winner *string
	if auction.bidder != "" {
		bidder := auction.bidder
		winner = &bidder
	}
	return &auctionv1.CloseAuctionResponse{
		Auction: &auctionv1.Auction{
			AuctionId:     auction.id,
			Item:          fmt.Sprintf("%s (closed on %s)", auction.item, s.NodeID),
			CurrentBid:    auction.bid,
			HighestBidder: winner,
			Status:        auction.status,
			Version:       auction.version,
		},
	}, nil
}
