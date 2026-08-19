package adminbffservice

// AdminBffServiceRepo defines the data-access port for this usecase.
// Implement it in internal/repository/adminbffservice/.
type AdminBffServiceRepo interface {
	// TODO: declare repository methods needed by the usecase
}

// UseCase orchestrates business logic for AdminBffService.
// It depends on interfaces (ports), not concrete implementations.
type UseCase struct {
	repo AdminBffServiceRepo
}

// New creates a UseCase wired to the given repository.
func New(repo AdminBffServiceRepo) *UseCase {
	return &UseCase{repo: repo}
}

// Add HTTP methods to the IDL proto, then rerun `make update`.
// Implement handler methods here as:
//   func (uc *UseCase) Ping(ctx context.Context, req *pb.PingReq) (*pb.PingResp, error) {
//       // Placeholder code 10010 shares its value with frameworkerror.CodeRPCUnavailable;
//       // replace with a domain-specific error code when implementing.
//       return nil, goerror.In("adminbffservice.usecase").Code(10010).Public("not_implemented").Errorf("Ping: not implemented")
//   }