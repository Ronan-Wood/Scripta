# Go statements

A "go" statement starts the execution of a function call as an independent concurrent thread
of control, or goroutine, within the same address space. The function value and parameters are
evaluated as usual in the calling goroutine, but unlike with a regular call, program execution
does not wait for the invoked function to complete. Instead, the function begins executing
independently in a new goroutine. When the function terminates, its goroutine also terminates.
If the function has any return values, they are discarded when the function completes.
