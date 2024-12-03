#ifndef GALLATIN_TIMER
#define GALLATIN_TIMER
// Gallatin, the general-purpose GPU allocator, made by Hunter McCoy
// (hunter@cs.utah.edu)

// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the
// rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
// sell copies of the Software, and to permit persons to whom the Software is
// furnished to do so,
// subject to the following conditions:

// The above copyright notice and this permission notice shall be included in
// all copies or substantial
// portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR
// IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

// Timer is a tool for timing the runtime of a kernel, provides an upper bound on time taken.

// inlcudes
#include <cuda.h>
#include <cuda_runtime_api.h>

#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <iostream>
using namespace std::chrono;

namespace gallatin {

namespace utils {

struct timer {

  high_resolution_clock::time_point start;

  high_resolution_clock::time_point end;

  // flush device and start timer
  timer() {
    cudaDeviceSynchronize();
    start_timer();
  }

  __host__ inline double elapsed() {
    return (duration_cast<duration<double> >(end - start)).count();
  }

  __host__ inline void start_timer() { start = high_resolution_clock::now(); }

  __host__ inline void end_timer() { end = high_resolution_clock::now(); }

  // synchronize with device, end the timer, and report duration
  __host__ inline double sync_end() {
    GPUErrorCheck(cudaDeviceSynchronize());

    end_timer();

    return elapsed();
  }

  __host__ inline void print_throughput(std::string operation, uint64_t nitems) {
    std::cout << operation << " " << nitems << " in " << elapsed()
              << " seconds, throughput " << std::fixed
              << 1.0 * nitems / elapsed() << std::endl;
  }
};

}  // namespace utils

}  // namespace gallatin

#endif  // End of guard