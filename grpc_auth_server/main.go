package main

import (
	"context"
	"log"
	"net"
	"strings"

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

type server struct{}

func (s *server) Check(ctx context.Context, req *pb.CheckRequest) (*pb.CheckResponse, error) {
	http := req.GetAttributes().GetRequest().GetHttp()

	log.Println(http.GetHeaders())
	log.Println(http.GetPath())

	respHeaders := []*core.HeaderValueOption{
		{
			Append: &types.BoolValue{Value: false},
			Header: &core.HeaderValue{
				Key:   "x-auth-a",
				Value: http.GetHeaders()["x-req-a"],
			},
		},
		{
			Append: &types.BoolValue{Value: false},
			Header: &core.HeaderValue{
				Key:   "x-auth-b",
				Value: "B custom auth header",
			},
		}, {
			Append: &types.BoolValue{Value: false},
			Header: &core.HeaderValue{
				Key:   "x-auth-c",
				Value: "C custom auth header",
			},
		}, {
			Append: &types.BoolValue{Value: false},
			Header: &core.HeaderValue{
				Key:   "x-auth-d",
				Value: "D custom auth header",
			},
		}, {
			Append: &types.BoolValue{Value: false},
			Header: &core.HeaderValue{
				Key:   "x-auth-e",
				Value: "E custom auth header",
			},
		},
	}

	if strings.HasPrefix(http.GetPath(), "/api/pets/1") {
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
	pb.RegisterAuthorizationServer(s, &server{})
	reflection.Register(s)
	if err := s.Serve(lis); err != nil {
		log.Fatalf("failed to serve: %v", err)
	}
}
