package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"regexp"

	"github.com/envoyproxy/go-control-plane/envoy/api/v2/core"
	pb "github.com/envoyproxy/go-control-plane/envoy/service/auth/v2"
	envoytype "github.com/envoyproxy/go-control-plane/envoy/type"
	googlerpc "github.com/gogo/googleapis/google/rpc"
	"github.com/gogo/protobuf/types"
	"google.golang.org/grpc"
	"google.golang.org/grpc/reflection"
)

const (
	port = ":8000"
)

type server struct {
	users    map[string]int
	accounts map[int]map[string]string
}

func (s *server) Check(ctx context.Context, req *pb.CheckRequest) (*pb.CheckResponse, error) {
	http := req.GetAttributes().GetRequest().GetHttp()

	headers := http.GetHeaders()
	path := http.GetPath()

	log.Println(headers)
	log.Println(path)

	re := regexp.MustCompile("/service/(.*)")

	service := re.FindStringSubmatch(path)[1]

	var user string
	var ok bool
	if user, ok = headers["user"]; !ok {
		log.Println("Denied: No User Specified")
		return &pb.CheckResponse{
			Status: &googlerpc.Status{Code: int32(googlerpc.PERMISSION_DENIED)},
			HttpResponse: &pb.CheckResponse_DeniedResponse{
				DeniedResponse: &pb.DeniedHttpResponse{
					Status: &envoytype.HttpStatus{Code: envoytype.StatusCode_Forbidden},
					Body:   `{"msg": "no user specified"}`,
				},
			},
		}, nil
	}

	account_id := s.users[user]
	plan := s.accounts[account_id][service]

	respHeaders := []*core.HeaderValueOption{
		{
			Append: &types.BoolValue{Value: false},
			Header: &core.HeaderValue{
				Key:   "x-account-id",
				Value: fmt.Sprint(account_id),
			},
		},
		{
			Append: &types.BoolValue{Value: false},
			Header: &core.HeaderValue{
				Key:   "x-plan",
				Value: plan,
			},
		}, {
			Append: &types.BoolValue{Value: false},
			Header: &core.HeaderValue{
				Key:   "x-service",
				Value: service,
			},
		},
	}

	if plan != "NONE" {
		log.Println("Approved")
		return &pb.CheckResponse{
			Status: &googlerpc.Status{Code: int32(googlerpc.OK)},
			HttpResponse: &pb.CheckResponse_OkResponse{
				OkResponse: &pb.OkHttpResponse{
					Headers: respHeaders,
				},
			},
		}, nil
	}

	log.Println("Denied")
	return &pb.CheckResponse{
		Status: &googlerpc.Status{Code: int32(googlerpc.PERMISSION_DENIED)},
		HttpResponse: &pb.CheckResponse_DeniedResponse{
			DeniedResponse: &pb.DeniedHttpResponse{
				Status:  &envoytype.HttpStatus{Code: envoytype.StatusCode_Forbidden},
				Headers: respHeaders,
				Body:    `{"msg": "denied"}`,
			},
		},
	}, nil
}

func main() {
	lis, err := net.Listen("tcp", port)
	if err != nil {
		log.Fatalf("failed to listen: %v", err)
	}
	s := grpc.NewServer()

	pb.RegisterAuthorizationServer(s, &server{
		users: map[string]int{
			"Scott":    1,
			"Yuval":    1,
			"Jonathan": 2,
			"Yuliia":   2,
			"Bill":     3,
		},
		accounts: map[int]map[string]string{
			1: {
				"service1": "BASIC", "service2": "NONE",
			},
			2: {
				"service1": "PLUS", "service2": "BASIC",
			},
			3: {
				"service1": "NONE", "service2": "PLUS",
			},
		},
	})

	// Helps Gloo detect this is a gRPC service
	reflection.Register(s)

	if err := s.Serve(lis); err != nil {
		log.Fatalf("failed to serve: %v", err)
	}
}
