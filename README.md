Basic template for using MPI with zig. Only tested with OpenMPI 5.0.5-2 for now, but
likely works with other (recent) versions.
Might expand to other implementations in future.

All steps for creating an `mpi` zig module are in
[`build_mpi.zig`](build_mpi.zig), which:
- Finds the system MPI header
- Makes a temporary copy in the zig cache with the `OMPI_PREDEFINED_GLOBAL`
  macro definition and usage patched to be friendly
  to `translate-c`
- Sets up the `translate-c` build step
- Provides a helper function for linking MPI

Relies on being able to call `mpicc --showme:arg` to query include directories,
library directories, and the MPI library name for linkage.
Also checks link flags to extract rpath if possible, although this may not work
if the base compiler is not `gcc`, and all other flags are currently ignored.
