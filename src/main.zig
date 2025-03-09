//! Simple MPI hello world

const std = @import("std");
const mpi = @import("mpi");

pub fn main() !void {
    std.debug.print("All your {s} are belong to us.\n", .{"MPI"});

    _ = mpi.MPI_Init(null, null);
    var rank: c_int = undefined;
    var world_size: c_int = undefined;
    _ = mpi.MPI_Comm_rank(mpi.MPI_COMM_WORLD(), &rank);
    _ = mpi.MPI_Comm_size(mpi.MPI_COMM_WORLD(), &world_size);
    std.debug.print("Rank {d} of {d}\n", .{ rank + 1, world_size });

    const next = @mod((rank + 1), world_size);
    const prev: c_int = @mod((rank - 1), world_size);
    var msg = rank * 10;
    _ = mpi.MPI_Sendrecv(&msg, 1, mpi.MPI_INT(), next, 1, &msg, 1, mpi.MPI_INT(), prev, 1, mpi.MPI_COMM_WORLD(), mpi.MPI_STATUS_IGNORE);
    std.debug.print("Msg to {d} from {d} is {d}\n", .{ rank + 1, prev + 1, msg });

    _ = mpi.MPI_Finalize();
}
